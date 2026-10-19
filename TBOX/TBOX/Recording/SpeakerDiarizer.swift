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
enum SpeakerDiarizationEngine {
    static var isAvailable: Bool {
        #if canImport(SpeakerKit)
        true
        #else
        false
        #endif
    }

    #if canImport(SpeakerKit)
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

        // AudioProcessor 统一重采样到 16 kHz 单声道浮点，与 SpeakerKit 要求一致。
        let samples = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: audioURL.path,
            channelMode: .sumChannels(nil)
        )
        guard !samples.isEmpty else { return [] }

        let result = try await kit.diarize(
            audioArray: samples,
            options: PyannoteDiarizationOptions()
        )
        let turns = result.segments
            .compactMap { segment -> SpeakerTurn? in
                guard let speakerID = segment.speaker.speakerId else { return nil }
                let start = max(0, min(duration, TimeInterval(segment.startTime)))
                let end = max(start, min(duration, TimeInterval(segment.endTime)))
                guard end > start else { return nil }
                return SpeakerTurn(start: start, end: end, speakerID: speakerID)
            }
            .sorted { $0.start < $1.start }
        AppLog.recording(
            "说话人识别完成: speakers=\(result.speakerCount), turns=\(turns.count), duration=\(String(format: "%.1f", duration))s"
        )
        return turns
    }
    #endif
}
