import Foundation

#if canImport(SpeakerKit)
@preconcurrency import SpeakerKit
@preconcurrency import WhisperKit
#endif

/// 说话人分离引擎（Layer 2）的封装。
///
/// SpeakerKit（pyannote CoreML）与 WhisperKit 同属 argmax-oss-swift，完全本地运行。
/// 模型与 Whisper 模型共用 `~/Library/Application Support/TBOX/Models` 目录，
/// 首次使用自动下载（约 11 MB）。任何失败都只记日志并降级为无说话人标注，
/// 不阻断转写主流程。
///
/// 内存策略：SpeakerKit 只提供「整段浮点数组」入口，直接喂数小时录音会把
/// 整段音频（16 kHz Float32，约 230 MB/小时）一次性驻留内存。这里改为按
///固定时长的窗口分段加载、逐窗分离，再用 pyannote 输出的说话人质心
/// （`speakerCentroidEmbeddings`）把各窗的局部说话人编号对齐到全局编号，
/// 从而在保持说话人身份跨窗一致的前提下，把峰值内存限制在单窗规模。
enum SpeakerDiarizationEngine {
    static var isAvailable: Bool {
        #if canImport(SpeakerKit)
        true
        #else
        false
        #endif
    }

    #if canImport(SpeakerKit)
    /// 单窗时长。限制单次进入内存的样本量（300s × 16 kHz × 4 B ≈ 19 MB），
    /// 同时保持在 pyannote 原生处理尺度内（其内部仍按约 10s 子窗推理）。
    private static let windowDuration: TimeInterval = 300

    /// 跨窗「同一说话人」判定的余弦距离阈值。SpeakerKit 不提供通用阈值，
    /// 需按模型与音频调参：过大会把不同人合并，过小会把同一人拆成多个。
    /// 0.5 是 pyannote/WeSpeaker 类嵌入的经验起点。
    private static let sameSpeakerDistanceThreshold: Float = 0.5

    /// 全局说话人上限，防止长音频因误差累积出过多编号。
    private static let maximumGlobalSpeakers = 20

    /// 质心滑动更新权重：命中已有说话人时用 EMA 吸收新观测，降噪并跟踪
    /// 随时间变化的音色。
    private static let centroidUpdateWeight: Float = 0.5

    /// SpeakerKit 实例的懒加载缓存。SpeakerKit 自身线程安全
    /// （`@unchecked Sendable`，模型由 ModelManager 串行加载）；
    /// actor 只负责避免每次转写重复初始化。并发重入时两个调用可能各自
    /// 构建一次实例，下载幂等、后写覆盖，行为安全。
    private actor SharedBox {
        private var instance: SpeakerKit?

        func get() async throws -> SpeakerKit {
            if let instance { return instance }

            let modelRoot = TBOXTranscriptionModel.storageDirectory
            try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
            let config = PyannoteConfig(
                downloadBase: modelRoot.path,
                download: true,
                load: false,
                verbose: false
            )
            let kit = try await SpeakerKit(config)
            instance = kit
            return kit
        }
    }

    private static let sharedBox = SharedBox()

    static func diarize(
        audioURL: URL,
        duration: TimeInterval
    ) async throws -> [SpeakerTurn] {
        guard duration > 1 else { return [] }
        let kit = try await sharedBox.get()

        var turns: [SpeakerTurn] = []
        // 全局说话人质心表，下标即全局说话人编号。
        var globalCentroids: [[Float]] = []
        var windowStart: TimeInterval = 0

        while windowStart < duration {
            let windowEnd = min(duration, windowStart + windowDuration)
            // 按窗口切片加载，避免整段音频常驻内存。
            let samples = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: audioURL.path,
                channelMode: .sumChannels(nil),
                startTime: windowStart,
                endTime: windowEnd
            )
            if samples.isEmpty {
                windowStart = windowEnd
                continue
            }

            let result = try await kit.diarize(
                audioArray: samples,
                options: PyannoteDiarizationOptions()
            )
            let localToGlobal = mapSpeakers(
                result: result,
                globalCentroids: &globalCentroids
            )

            for segment in result.segments {
                guard let localID = segment.speaker.speakerId,
                    let globalID = localToGlobal[localID] else { continue }
                let start = max(0, min(duration, windowStart + TimeInterval(segment.startTime)))
                let end = max(start, min(duration, windowStart + TimeInterval(segment.endTime)))
                guard end > start else { continue }
                turns.append(SpeakerTurn(start: start, end: end, speakerID: globalID))
            }

            windowStart = windowEnd
        }

        turns.sort { $0.start < $1.start }
        AppLog.recording(
            "说话人识别完成: speakers=\(globalCentroids.count), turns=\(turns.count), duration=\(String(format: "%.1f", duration))s, windows=\(Int(ceil(duration / windowDuration)))"
        )
        return turns
    }

    /// 把单窗分离结果里的局部说话人编号对齐到全局编号：
    /// 用局部质心在全局质心表里找最近的同一说话人（距离小于阈值即视为同一人），
    /// 找不到就登记为新说话人并更新/追加质心表。
    private static func mapSpeakers(
        result: DiarizationResult,
        globalCentroids: inout [[Float]]
    ) -> [Int: Int] {
        let localIDs = Set(result.segments.compactMap { $0.speaker.speakerId })
        var mapping: [Int: Int] = [:]

        for localID in localIDs.sorted() {
            // pyannote 默认 centroidSource = .finalAssignment，正常每个说话人都有质心；
            // 缺失时退化为按下标复用，保持编号有界（该情形会记录日志）。
            guard let centroid = result.speakerCentroidEmbeddings[localID], !centroid.isEmpty else {
                AppLog.recording("说话人 \(localID) 缺少质心，按编号复用（跨窗身份可能不一致）")
                mapping[localID] = min(localID, maximumGlobalSpeakers - 1)
                continue
            }

            var bestIndex: Int?
            var bestDistance: Float = .greatestFiniteMagnitude
            for (index, global) in globalCentroids.enumerated() where global.count == centroid.count {
                let distance = cosineDistance(centroid, global)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }

            if let index = bestIndex, bestDistance <= sameSpeakerDistanceThreshold {
                mapping[localID] = index
                globalCentroids[index] = blend(globalCentroids[index], centroid, weight: centroidUpdateWeight)
            } else if globalCentroids.count < maximumGlobalSpeakers {
                mapping[localID] = globalCentroids.count
                globalCentroids.append(centroid)
            } else {
                // 已达上限：并入当前最接近的说话人，避免编号无限增长。
                if let index = bestIndex {
                    mapping[localID] = index
                    globalCentroids[index] = blend(globalCentroids[index], centroid, weight: centroidUpdateWeight)
                } else {
                    mapping[localID] = 0
                }
            }
        }

        return mapping
    }

    /// 余弦距离 `1 - cosθ`，与 SpeakerKit 内部 `MathOps.cosineDistance` 约定一致。
    private static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1 }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in 0..<lhs.count {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denominator = lhsNorm.squareRoot() * rhsNorm.squareRoot()
        guard denominator > 0 else { return 1 }
        return 1 - dot / denominator
    }

    private static func blend(_ existing: [Float], _ incoming: [Float], weight: Float) -> [Float] {
        guard existing.count == incoming.count else { return incoming }
        return zip(existing, incoming).map { $0 * (1 - weight) + $1 * weight }
    }
    #endif
}
