@preconcurrency import AVFoundation
import Cocoa
import Speech

enum RecordingTranscriptionError: LocalizedError {
    case microphonePermissionDenied
    case speechPermissionDenied
    case recorderUnavailable
    case recorderSetup(String)
    case noAudio
    case noRecognizableSpeech
    case transcriptionUnavailable
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "没有麦克风权限，请在系统设置中允许 TBOX 使用麦克风。"
        case .speechPermissionDenied:
            return "没有语音识别权限，录音已保留但暂时无法转写。"
        case .recorderUnavailable:
            return "找不到可用的麦克风。"
        case .recorderSetup(let message):
            return "无法开始录音：\(message)"
        case .noAudio:
            return "录音中没有检测到可用音频。"
        case .noRecognizableSpeech:
            return "录音文件有效，但转写引擎没有识别出文字。请确认录制内容包含清晰人声。"
        case .transcriptionUnavailable:
            return "当前系统没有可用的语音识别服务。"
        case .transcriptionFailed(let message):
            return "录音转写失败：\(message)"
        }
    }
}

enum RecordingTranscriptionEngine: String, Codable {
    case whisperKit
    case appleSpeech

    var displayName: String {
        switch self {
        case .whisperKit: return "本地高精度"
        case .appleSpeech: return "系统兼容"
        }
    }
}

enum RecordingTranscriptionPreferences {
    static let allowSystemSpeechFallbackKey = "allowSystemSpeechFallback"
    /// 转写完成后是否把未压缩录音归档为 AAC；缺省视为开启。
    static let archiveRecordingsKey = "archiveRecordingsAfterTranscription"
    /// 首次转写时是否自动下载语音模型（经体积确认后）；缺省视为开启。
    static let autoDownloadModelsKey = "autoDownloadModelsOnFirstUse"
}

struct RecordingTranscriptionResult: Codable {
    let audioURL: URL
    let duration: TimeInterval
    let text: String
    let segments: [RecordingTranscriptionSegment]
    let engine: RecordingTranscriptionEngine

    init(
        audioURL: URL,
        duration: TimeInterval,
        text: String,
        segments: [RecordingTranscriptionSegment],
        // 默认按本地高精度引擎记录：绝大多数结果出自 WhisperKit，
        // 只应在系统兼容路径上显式传入 .appleSpeech，避免漏传时被错误标注来源。
        engine: RecordingTranscriptionEngine = .whisperKit
    ) {
        self.audioURL = audioURL
        self.duration = duration
        self.text = text
        self.segments = segments
        self.engine = engine
    }
}

struct RecordingTranscriptionSegment: Codable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speakerName: String
    /// 说话人分离引擎给出的说话人编号；nil 表示未标注（独白或分离不可用）。
    var speakerID: Int?
    /// 时间戳是否为估算值。词级对齐可用时为 false（真实时间）；当管线回退到
    /// 按字符比例均摊时间时置为 true，供界面与导出明确区分，
    /// 避免把估算时间当作真实时间使用。
    let isEstimated: Bool

    init(
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerName: String,
        speakerID: Int? = nil,
        isEstimated: Bool = false
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.speakerName = speakerName
        self.speakerID = speakerID
        self.isEstimated = isEstimated
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, text, speakerName, speakerID, isEstimated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        speakerName = try container.decode(String.self, forKey: .speakerName)
        // 旧版快照没有 speakerID / isEstimated 字段；缺失时按未标注、
        // 非估算处理，保证旧缓存可读。
        speakerID = try container.decodeIfPresent(Int.self, forKey: .speakerID)
        isEstimated = try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(text, forKey: .text)
        try container.encode(speakerName, forKey: .speakerName)
        try container.encodeIfPresent(speakerID, forKey: .speakerID)
        try container.encode(isEstimated, forKey: .isEstimated)
    }
}

/// 与音频相邻保存，原子写入；音频被替换或修改后不复用旧结果。
enum RecordingTranscriptStore {
    struct Snapshot: Codable {
        let version: Int
        let fileSize: Int
        let modifiedAt: Date
        let completedChunks: Int
        let isComplete: Bool
        let result: RecordingTranscriptionResult
    }

    static func url(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("transcript.json")
    }

    static func load(for audioURL: URL) -> Snapshot? {
        guard let values = try? audioURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let data = try? Data(contentsOf: url(for: audioURL)),
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
              saved.version == 2, saved.fileSize == values.fileSize,
              datesMatch(saved.modifiedAt, values.contentModificationDate),
              saved.completedChunks >= 0, saved.result.duration.isFinite,
              saved.result.duration > 0 else { return nil }
        return Snapshot(
            version: saved.version, fileSize: saved.fileSize, modifiedAt: saved.modifiedAt,
            completedChunks: saved.completedChunks, isComplete: saved.isComplete,
            result: RecordingTranscriptionResult(
                audioURL: audioURL, duration: saved.result.duration,
                text: saved.result.text, segments: saved.result.segments,
                engine: saved.result.engine
            )
        )
    }

    private static func datesMatch(_ saved: Date, _ current: Date?) -> Bool {
        guard let current else { return false }
        return abs(saved.timeIntervalSince(current)) < 1
    }

    static func save(_ result: RecordingTranscriptionResult, completedChunks: Int, isComplete: Bool) throws {
        let values = try result.audioURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let modifiedAt = values.contentModificationDate else {
            throw RecordingTranscriptionError.transcriptionFailed("无法读取录音文件信息，转写进度尚未保存")
        }
        let snapshot = Snapshot(
            version: 2, fileSize: size, modifiedAt: modifiedAt,
            completedChunks: completedChunks, isComplete: isComplete, result: result
        )
        try JSONEncoder().encode(snapshot).write(to: url(for: result.audioURL), options: .atomic)
    }
}

struct RecordingTranscriptionProgress {
    let completedChunks: Int
    let totalChunks: Int
    let statusMessage: String?

    init(completedChunks: Int, totalChunks: Int, statusMessage: String? = nil) {
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.statusMessage = statusMessage
    }

    var fraction: Double? {
        totalChunks > 0 ? Double(completedChunks) / Double(totalChunks) : nil
    }

    var message: String {
        if let statusMessage { return statusMessage }
        return totalChunks > 0
            ? "正在转写 · 已完成 \(completedChunks)/\(totalChunks) 段（\(Int((fraction ?? 0) * 100))%）"
            : "正在准备录音…"
    }
}

/// Speech Framework 返回的是词元级片段，直接逐条展示会变成“一两个字一行”。
/// 这里将词元按句末标点、停顿、时长和字数聚合成适合阅读的句段。
enum RecordingTranscriptionSegmenter {
    private static let pauseThreshold: TimeInterval = 0.85
    private static let maximumDuration: TimeInterval = 15
    private static let maximumCharacters = 80
    private static let sentenceEndings = CharacterSet(charactersIn: "。！？!?；;\n")
    private static let closingPunctuation = CharacterSet(charactersIn: "，。！？；：、,.!?;:%)]}》〉】」』”’")

    static func group(
        _ source: [RecordingTranscriptionSegment],
        fallbackText: String,
        duration: TimeInterval
    ) -> [RecordingTranscriptionSegment] {
        let ordered = source
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }

        guard !ordered.isEmpty else {
            return fallbackSegments(text: fallbackText, duration: duration)
        }

        var output: [RecordingTranscriptionSegment] = []
        var current: RecordingTranscriptionSegment?

        for item in ordered {
            let token = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if let existing = current {
                // 说话人变化时强制断句：不同说话人的发言不能合并进同一个句段。
                let speakerChanged = item.speakerID != nil
                    && existing.speakerID != nil
                    && item.speakerID != existing.speakerID
                let pause = max(0, item.start - existing.end)
                if speakerChanged || (pause >= pauseThreshold && existing.text.count >= 4) {
                    flushCurrent(&current, into: &output)
                }
            }

            if let existing = current {
                current = RecordingTranscriptionSegment(
                    start: existing.start,
                    end: max(existing.end, item.end),
                    text: joined(existing.text, token),
                    speakerName: existing.speakerName,
                    speakerID: existing.speakerID,
                    isEstimated: existing.isEstimated || item.isEstimated
                )
            } else {
                current = RecordingTranscriptionSegment(
                    start: item.start,
                    end: item.end,
                    text: token,
                    speakerName: item.speakerName,
                    speakerID: item.speakerID,
                    isEstimated: item.isEstimated
                )
            }

            if let existing = current,
                endsSentence(existing.text)
                || existing.end - existing.start >= maximumDuration
                || existing.text.count >= maximumCharacters {
                flushCurrent(&current, into: &output)
            }
        }
        flushCurrent(&current, into: &output)
        return output.isEmpty ? fallbackSegments(text: fallbackText, duration: duration) : output
    }

    /// Keep this outside `group` instead of using a local closure. Swift 6.1.2's
    /// release optimizer can miscompile a closure that borrows and clears the
    /// captured optional segment (SIL ownership verification failure).
    private static func flushCurrent(
        _ current: inout RecordingTranscriptionSegment?,
        into output: inout [RecordingTranscriptionSegment]
    ) {
        guard let segment = current else { return }
        let cleaned = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            output.append(
                RecordingTranscriptionSegment(
                    start: segment.start,
                    end: segment.end,
                    text: cleaned,
                    speakerName: segment.speakerName,
                    speakerID: segment.speakerID,
                    isEstimated: segment.isEstimated
                )
            )
        }
        current = nil
    }

    private static func fallbackSegments(text: String, duration: TimeInterval) -> [RecordingTranscriptionSegment] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var sentences: [String] = []
        var buffer = ""
        for character in cleaned {
            buffer.append(character)
            if character.unicodeScalars.contains(where: sentenceEndings.contains) {
                sentences.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                buffer = ""
            }
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !sentences.isEmpty else { return [] }

        let totalCharacters = max(1, sentences.reduce(0) { $0 + $1.count })
        var consumedCharacters = 0
        return sentences.map { sentence in
            let start = duration * Double(consumedCharacters) / Double(totalCharacters)
            consumedCharacters += sentence.count
            let end = duration * Double(consumedCharacters) / Double(totalCharacters)
            return RecordingTranscriptionSegment(
                start: start,
                end: end,
                text: sentence,
                speakerName: "我",
                // 无词级时间可用时按字符比例均摊，属于估算时间，必须显式标记。
                isEstimated: true
            )
        }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.unicodeScalars.contains(where: sentenceEndings.contains)
    }

    private static func joined(_ left: String, _ right: String) -> String {
        guard let leftCharacter = left.last, let rightCharacter = right.first else {
            return left + right
        }
        if rightCharacter.unicodeScalars.contains(where: closingPunctuation.contains)
            || leftCharacter.isWhitespace
            || rightCharacter.isWhitespace
            || isCJK(leftCharacter)
            || isCJK(rightCharacter) {
            return left + right
        }
        return left + " " + right
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}

/// 录音文件的统一本地存储位置。录音器和“记录”页面都从这里读取，
/// 避免文件已经保存但客户端列表不可见。
enum RecordingStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TBOX", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }
}

extension Notification.Name {
    static let tboxRecordingSaved = Notification.Name("tboxRecordingSaved")
    static let tboxViewRecordingTranscript = Notification.Name("tboxViewRecordingTranscript")
}

/// 录音转写会话：本地保存麦克风音频，默认由 WhisperKit/Core ML 在本机转写。
/// Apple Speech 仅在用户明确开启兼容模式后作为失败降级；普通录屏由 ScreenRecorder 独立负责。
final class RecordingTranscriptionManager: NSObject, @unchecked Sendable {
    enum State { case idle, preparing, recording, paused, transcribing }

    struct RecognitionChunk {
        let url: URL
        let start: TimeInterval
        let duration: TimeInterval
        let isTemporary: Bool
    }

    /// AVAssetExportSession 的完成回调在系统队列执行。导出器只在该回调中读取
    /// 最终状态，不会跨线程修改；用受控包装满足 Swift 6 的 Sendable 检查。
    private final class ExportSessionBox: @unchecked Sendable {
        let value: AVAssetExportSession
        init(_ value: AVAssetExportSession) { self.value = value }
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var audioURL: URL?

    var onStateChange: ((State) -> Void)?
    var onElapsedChange: ((TimeInterval) -> Void)?
    var onMeterChange: ((Float) -> Void)?
    var onPartialResult: ((RecordingTranscriptionResult) -> Void)?
    var onProgress: ((RecordingTranscriptionProgress) -> Void)?
    var onResult: ((Result<RecordingTranscriptionResult, Error>) -> Void)?
    private(set) var latestPartialResult: RecordingTranscriptionResult?
    private(set) var progress = RecordingTranscriptionProgress(completedChunks: 0, totalChunks: 0)

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var pausedAt: Date?
    /// 系统声音采集器；仅在启用且权限可用时存在，失败即置空降级为仅麦克风。
    private var systemAudioRecorder: SystemAudioRecorder?
    /// 录音过程中每个暂停区间在麦克风有效录音时间轴上的位置与时长，
    /// 混音时据此跳过暂停期间的系统声音。
    private var pauseGaps: [AudioTrackMixer.PauseGap] = []
    /// 当前暂停开始时在麦克风有效录音时间轴上的位置（未恢复前有效）。
    private var activePauseStartedAt: TimeInterval?
    private var speechRecognizer: SFSpeechRecognizer?
    private var speechTask: SFSpeechRecognitionTask?
    private var highQualityTask: Task<Void, Never>?
    private var recognitionGeneration = 0
    private var latestRecognitionText = ""
    private var latestRecognitionSegments: [RecordingTranscriptionSegment] = []
    private var recognitionChunks: [RecognitionChunk] = []
    private var recognitionChunkIndex = 0
    private var accumulatedRecognitionTexts: [String] = []
    private var accumulatedRecognitionSegments: [RecordingTranscriptionSegment] = []
    private var recognitionSourceURL: URL?
    private var recognitionSourceDuration: TimeInterval = 0
    private var recognitionTemporaryDirectory: URL?
    private var lastMeterLogDate = Date.distantPast

    var isActive: Bool { state != .idle }

    /// 已完成时直接读取本地结果，未完成时从已保存的分段继续。
    func transcribeSavedRecording(at url: URL) {
        guard state == .idle else { return }
        audioURL = url
        if let saved = RecordingTranscriptStore.load(for: url), saved.isComplete {
            elapsed = saved.result.duration
            finish(.success(saved.result))
            return
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            let sampleRate = audioFile.processingFormat.sampleRate
            guard audioFile.length > 0, sampleRate > 0 else {
                finish(.failure(RecordingTranscriptionError.noAudio))
                return
            }

            let duration = Double(audioFile.length) / sampleRate
            audioURL = url
            elapsed = duration
            state = .transcribing
            publishState()
            AppLog.recording("读取已保存录音并继续转写: path=\(url.path), duration=\(String(format: "%.2f", duration))s, \(Self.audioFileSummary(url))")
            transcribe(url: url, duration: duration)
        } catch {
            AppLog.recordingError("无法读取待转写的录音: path=\(url.path), error=\(error.localizedDescription)")
            finish(.failure(RecordingTranscriptionError.noAudio))
        }
    }

    func start() {
        guard state == .idle else { return }
        state = .preparing
        publishState()
        AppLog.recording("请求麦克风权限")

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            AppLog.recording("麦克风权限结果: \(granted ? "已授权" : "已拒绝")")
            guard granted else {
                self.failStart(RecordingTranscriptionError.microphonePermissionDenied)
                return
            }
            DispatchQueue.main.async {
                self.prepareAndRecord()
            }
        }
    }

    func togglePause() {
        guard let recorder else { return }
        switch state {
        case .recording:
            recorder.pause()
            pausedAt = Date()
            let activeElapsed = Date().timeIntervalSince(startedAt ?? Date()) - pausedDuration
            activePauseStartedAt = max(0, activeElapsed)
            state = .paused
            publishState()
        case .paused:
            if let pausedAt {
                let pauseDuration = Date().timeIntervalSince(pausedAt)
                if let activeStart = activePauseStartedAt {
                    pauseGaps.append(
                        AudioTrackMixer.PauseGap(activeTime: activeStart, duration: pauseDuration)
                    )
                }
                pausedDuration += pauseDuration
            }
            self.pausedAt = nil
            activePauseStartedAt = nil
            recorder.record()
            state = .recording
            publishState()
        default:
            break
        }
    }

    func stop() {
        guard state == .recording || state == .paused else { return }
        if let pausedAt {
            pausedDuration += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
        activePauseStartedAt = nil
        recorder?.stop()
        stopTimers()

        guard let recorder, let url = audioURL else {
            teardownSystemAudio()
            finish(.failure(RecordingTranscriptionError.noAudio))
            return
        }

        let finalDuration = max(0, Date().timeIntervalSince(startedAt ?? Date()) - pausedDuration)
        elapsed = finalDuration
        recorder.deleteRecordingIfEmpty()
        self.recorder = nil
        state = .transcribing
        publishState()

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        AppLog.recording("录音文件已关闭: path=\(url.path), size=\(fileSize) bytes, duration=\(String(format: "%.2f", finalDuration))s, \(Self.audioFileSummary(url))")
        guard FileManager.default.fileExists(atPath: url.path), fileSize > 0 else {
            teardownSystemAudio()
            finish(.failure(RecordingTranscriptionError.noAudio))
            return
        }

        let gaps = pauseGaps
        pauseGaps = []

        // AVAudioRecorder may still be finalising the m4a container immediately
        // after stop().  Give the file system one run-loop turn before handing
        // it to Speech; starting too early can produce a valid-looking file but
        // an empty recognition result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let frameCount = (try? AVAudioFile(forReading: url).length) ?? 0
            guard frameCount > 0 else {
                AppLog.recordingError("录音文件没有有效音频帧: path=\(url.path), size=\(fileSize)")
                self.teardownSystemAudio()
                self.finish(.failure(RecordingTranscriptionError.noAudio))
                return
            }
            self.finalizeInput(microphoneURL: url, pauseGaps: gaps, duration: finalDuration)
        }
    }

    /// 收尾系统声音采集并把麦克风与系统声音混为最终转写源，再开始转写。
    /// 系统声音不可用或混音失败时直接使用麦克风原文件，不阻断主流程。
    private func finalizeInput(
        microphoneURL: URL,
        pauseGaps: [AudioTrackMixer.PauseGap],
        duration: TimeInterval
    ) {
        stopSystemAudio { [weak self] systemURL in
            guard let self else { return }
            var finalURL = microphoneURL
            if let systemURL {
                let outputURL = Self.mixedAudioURL(basedOn: microphoneURL)
                if let mixed = AudioTrackMixer.mix(
                    microphoneURL: microphoneURL,
                    systemAudioURL: systemURL,
                    pauseGaps: pauseGaps,
                    outputURL: outputURL
                ) {
                    finalURL = mixed
                    try? FileManager.default.removeItem(at: microphoneURL)
                }
                try? FileManager.default.removeItem(at: systemURL)
            }
            self.audioURL = finalURL
            NotificationCenter.default.post(name: .tboxRecordingSaved, object: finalURL)
            self.transcribe(url: finalURL, duration: duration)
        }
    }

    /// 停止系统声音采集并交出临时文件地址；未启用时立即回调 nil。
    private func stopSystemAudio(_ completion: @escaping (URL?) -> Void) {
        guard let recorder = systemAudioRecorder else {
            completion(nil)
            return
        }
        systemAudioRecorder = nil
        recorder.stop { url in
            DispatchQueue.main.async { completion(url) }
        }
    }

    /// 放弃系统声音采集（启动失败或空录音清理），并删除其临时文件。
    private func teardownSystemAudio() {
        guard let recorder = systemAudioRecorder else { return }
        systemAudioRecorder = nil
        recorder.stop { url in
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func mixedAudioURL(basedOn microphoneURL: URL) -> URL {
        let directory = microphoneURL.deletingLastPathComponent()
        let base = microphoneURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(base)_双轨.caf")
    }

    private func prepareAndRecord() {
        let directory = RecordingStorage.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory
                .appendingPathComponent("录音转写_\(Self.timestamp()).caf")
            // 48 kHz 是 macOS 麦克风原生采样率；Linear PCM 无损录制为
            // WhisperKit 转写和 SpeakerKit 说话人分离提供最高质量的源头信号
            // （两者内部统一重采样到 16 kHz）。体积约 5.5 MB/分钟。
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            let prepared = recorder.prepareToRecord()
            let started = prepared && recorder.record()
            AppLog.recording("初始化录音器: prepared=\(prepared), record=\(started), url=\(url.path)")
            guard prepared, started else {
                failStart(RecordingTranscriptionError.recorderSetup("麦克风无法开始写入"))
                return
            }
            self.recorder = recorder
            self.audioURL = url
            self.startedAt = Date()
            self.pausedDuration = 0
            self.pausedAt = nil
            self.activePauseStartedAt = nil
            self.pauseGaps = []
            self.elapsed = 0
            self.lastMeterLogDate = .distantPast
            state = .recording
            publishState()
            startTimers()
            startSystemAudioCaptureIfNeeded()
        } catch {
            failStart(RecordingTranscriptionError.recorderSetup(error.localizedDescription))
        }
    }

    /// 在麦克风轨已启动的前提下并行启动系统声音采集；任何失败都降级为仅麦克风。
    private func startSystemAudioCaptureIfNeeded() {
        guard SystemAudioRecorder.isEnabled else {
            AppLog.recording("系统声音采集已关闭（设置中未启用），本次仅录制麦克风")
            return
        }
        let recorder = SystemAudioRecorder()
        systemAudioRecorder = recorder
        recorder.start { [weak self] error in
            guard let self else { return }
            if let error {
                AppLog.recordingError("系统声音采集未启动，本次仅录制麦克风: \(error.localizedDescription)")
                self.systemAudioRecorder = nil
            } else {
                AppLog.recording("系统声音采集已启动（会议对方声音将一并记录并转写）")
            }
        }
    }

    private func transcribe(url: URL, duration: TimeInterval) {
        guard HighQualityTranscriptionEngine.isAvailable else {
            transcribeWithSystemSpeech(url: url, duration: duration)
            return
        }

        progress = RecordingTranscriptionProgress(
            completedChunks: 0,
            totalChunks: 0,
            statusMessage: "正在准备本地高精度转写…"
        )
        onProgress?(progress)
        AppLog.recording("启动本地高精度转写: model=\(TBOXTranscriptionModel.modelName), speakerDiarization=\(SpeakerDiarizationEngine.isAvailable)")
        highQualityTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 转写与说话人识别并行执行，总耗时约为两者中的较慢者。
                async let recognizedTask = HighQualityTranscriptionEngine.transcribe(
                    audioURL: url,
                    duration: duration
                ) { [weak self] progress in
                    DispatchQueue.main.async {
                        guard let self, self.state == .transcribing else { return }
                        self.progress = progress
                        self.onProgress?(progress)
                    }
                }
                async let speakerTurnsTask = Self.diarizeSpeakers(url: url, duration: duration)

                let recognized = try await recognizedTask
                let speakerTurns = await speakerTurnsTask

                let output = Self.assembleTranscript(
                    recognized: recognized,
                    speakerTurns: speakerTurns,
                    url: url,
                    duration: duration
                )
                // 转写完成后归档未压缩录音（.caf → .m4a）；失败则保持原文件，不影响结果交付。
                let archived = await RecordingAudioArchiver.archiveIfNeeded(output)

                await MainActor.run {
                    guard self.state == .transcribing else { return }
                    do {
                        try RecordingTranscriptStore.save(archived, completedChunks: 1, isComplete: true)
                        self.audioURL = archived.audioURL
                        self.latestPartialResult = archived
                        self.progress = RecordingTranscriptionProgress(
                            completedChunks: 1,
                            totalChunks: 1,
                            statusMessage: "本地高精度转写完成"
                        )
                        self.onProgress?(self.progress)
                        AppLog.recording(
                            "本地高精度转写完成: language=\(recognized.language), chars=\(archived.text.count), segments=\(archived.segments.count), speakers=\(Self.distinctSpeakerCount(archived.segments))"
                        )
                        self.finish(.success(archived))
                    } catch {
                        self.finish(.failure(RecordingTranscriptionError.transcriptionFailed(
                            "保存高精度转写结果失败：\(error.localizedDescription)"
                        )))
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.state == .transcribing else { return }
                    guard UserDefaults.standard.bool(
                        forKey: RecordingTranscriptionPreferences.allowSystemSpeechFallbackKey
                    ) else {
                        AppLog.recordingError(
                            "本地高精度转写失败，隐私设置禁止系统兼容路径: \(error.localizedDescription)"
                        )
                        self.finish(.failure(RecordingTranscriptionError.transcriptionFailed(
                            "本地高精度模型暂不可用：\(error.localizedDescription)。录音未上传；请检查网络后重试模型下载。"
                        )))
                        return
                    }
                    AppLog.recordingError(
                        "本地高精度转写不可用，切换系统兼容识别: \(error.localizedDescription)"
                    )
                    self.progress = RecordingTranscriptionProgress(
                        completedChunks: 0,
                        totalChunks: 0,
                        statusMessage: "本地模型暂不可用，正在切换系统兼容识别…"
                    )
                    self.onProgress?(self.progress)
                    self.highQualityTask = nil
                    self.transcribeWithSystemSpeech(url: url, duration: duration)
                }
            }
        }
    }

    /// 运行说话人分离；任何失败都降级为空结果（无标注），不阻断转写。
    static func diarizeSpeakers(url: URL, duration: TimeInterval) async -> [SpeakerTurn] {
        #if canImport(SpeakerKit)
        guard SpeakerDiarizationEngine.isAvailable else { return [] }
        do {
            return try await SpeakerDiarizationEngine.diarize(audioURL: url, duration: duration)
        } catch {
            AppLog.recordingError(
                "说话人识别不可用，本次转写不区分说话人: \(error.localizedDescription)"
            )
            return []
        }
        #else
        return []
        #endif
    }

    /// 将词级转写输出与说话人标注合并、聚合、整理为最终文字稿。
    static func assembleTranscript(
        recognized: HighQualityTranscriptionOutput,
        speakerTurns: [SpeakerTurn],
        url: URL,
        duration: TimeInterval
    ) -> RecordingTranscriptionResult {
        let annotated = TranscriptionAligner.assignSpeakers(
            to: recognized.wordSegments,
            turns: speakerTurns
        )
        var segments = RecordingTranscriptionSegmenter.group(
            recognized.hasUsableAlignment ? annotated : [],
            fallbackText: recognized.text,
            duration: duration
        )
        segments = TranscriptPolisher.polish(segments)
        segments = Self.applySpeakerLabels(to: segments)

        let text = segments
            .map(\.text)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RecordingTranscriptionResult(
            audioURL: url,
            duration: duration,
            text: text,
            segments: segments,
            engine: .whisperKit
        )
    }

    /// 把 speakerID 转换为显示标签：仅 2 个及以上有效说话人时显示“说话人 N”，
    /// 否则统一为“我”，避免独白录音出现无意义的噪音标签。
    private static func applySpeakerLabels(
        to segments: [RecordingTranscriptionSegment]
    ) -> [RecordingTranscriptionSegment] {
        let speakerCount = distinctSpeakerCount(segments)
        return segments.map { segment in
            let label: String
            if speakerCount >= 2, let speakerID = segment.speakerID {
                label = "说话人 \(speakerID + 1)"
            } else {
                label = "我"
            }
            guard label != segment.speakerName else { return segment }
            return RecordingTranscriptionSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speakerName: label,
                speakerID: speakerCount >= 2 ? segment.speakerID : nil,
                isEstimated: segment.isEstimated
            )
        }
    }

    private static func distinctSpeakerCount(_ segments: [RecordingTranscriptionSegment]) -> Int {
        Set(segments.compactMap(\.speakerID)).count
    }

    private func transcribeWithSystemSpeech(url: URL, duration: TimeInterval) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            AppLog.recording("语音识别权限结果: \(String(describing: status))")
            guard status == .authorized else {
                self.finish(.failure(RecordingTranscriptionError.speechPermissionDenied))
                return
            }
            DispatchQueue.main.async {
                self.prepareRecognitionChunks(url: url, duration: duration)
            }
        }
    }

    private func prepareRecognitionChunks(url: URL, duration: TimeInterval) {
        recognitionSourceURL = url
        recognitionSourceDuration = duration
        recognitionChunkIndex = 0
        accumulatedRecognitionTexts = []
        accumulatedRecognitionSegments = []
        latestPartialResult = nil
        progress = RecordingTranscriptionProgress(completedChunks: 0, totalChunks: 0)
        onProgress?(progress)

        let maximumChunkDuration: TimeInterval = 45
        guard duration > maximumChunkDuration else {
            beginRecognition(
                chunks: [RecognitionChunk(url: url, start: 0, duration: duration, isTemporary: false)],
                temporaryDirectory: nil
            )
            return
        }

        AppLog.recording("长录音将分段转写: duration=\(String(format: "%.2f", duration))s, chunk=\(Int(maximumChunkDuration))s")
        Task { [weak self] in
            do {
                let prepared = try await Self.exportRecognitionChunks(
                    sourceURL: url,
                    duration: duration,
                    maximumChunkDuration: maximumChunkDuration
                )
                guard let self else { return }
                await MainActor.run {
                    self.beginRecognition(chunks: prepared.chunks, temporaryDirectory: prepared.directory)
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    AppLog.recordingError("无法切分长录音: \(error.localizedDescription)")
                    self.finish(.failure(RecordingTranscriptionError.transcriptionFailed("无法准备长录音分段：\(error.localizedDescription)")))
                }
            }
        }
    }

    static func exportRecognitionChunks(
        sourceURL: URL,
        duration: TimeInterval,
        maximumChunkDuration: TimeInterval
    ) async throws -> (chunks: [RecognitionChunk], directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TBOX-Transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: sourceURL)
        var chunks: [RecognitionChunk] = []
        var start: TimeInterval = 0
        var index = 0

        do {
            while start < duration {
                let chunkDuration = min(maximumChunkDuration, duration - start)
                let outputURL = directory.appendingPathComponent(String(format: "chunk_%03d.m4a", index))
                guard let exporter = AVAssetExportSession(
                    asset: asset,
                    presetName: AVAssetExportPresetPassthrough
                ) else {
                    throw RecordingTranscriptionError.transcriptionFailed("系统无法创建音频分段导出器")
                }
                exporter.outputURL = outputURL
                exporter.outputFileType = .m4a
                exporter.timeRange = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: chunkDuration, preferredTimescale: 600)
                )
                let exporterBox = ExportSessionBox(exporter)

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    exporter.exportAsynchronously {
                        switch exporterBox.value.status {
                        case .completed:
                            continuation.resume()
                        case .failed, .cancelled:
                            continuation.resume(
                                throwing: exporterBox.value.error
                                    ?? RecordingTranscriptionError.transcriptionFailed("音频分段导出失败")
                            )
                        default:
                            continuation.resume(
                                throwing: RecordingTranscriptionError.transcriptionFailed("音频分段导出未完成")
                            )
                        }
                    }
                }

                chunks.append(
                    RecognitionChunk(
                        url: outputURL,
                        start: start,
                        duration: chunkDuration,
                        isTemporary: true
                    )
                )
                start += chunkDuration
                index += 1
            }
            return (chunks, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func beginRecognition(chunks: [RecognitionChunk], temporaryDirectory: URL?) {
        guard !chunks.isEmpty else {
            finish(.failure(RecordingTranscriptionError.noAudio))
            return
        }
        recognitionChunks = chunks
        recognitionTemporaryDirectory = temporaryDirectory
        recognitionChunkIndex = 0
        if let sourceURL = recognitionSourceURL,
           let saved = RecordingTranscriptStore.load(for: sourceURL), !saved.isComplete,
           saved.completedChunks <= chunks.count {
            recognitionChunkIndex = saved.completedChunks
            accumulatedRecognitionTexts = saved.result.text.isEmpty ? [] : [saved.result.text]
            accumulatedRecognitionSegments = saved.result.segments
            latestPartialResult = saved.result
            onPartialResult?(saved.result)
        }
        publishProgress()
        AppLog.recording("开始分段识别: chunks=\(chunks.count)")
        startSpeechRecognition(attempt: 0)
    }

    private func startSpeechRecognition(attempt: Int = 0) {
        guard recognitionChunks.indices.contains(recognitionChunkIndex),
              let sourceURL = recognitionSourceURL else {
            finishAccumulatedRecognition()
            return
        }
        let chunk = recognitionChunks[recognitionChunkIndex]
        let localeCandidates = [
            Locale.current,
            Locale(identifier: "zh-CN"),
            Locale(identifier: "en-US")
        ]
        let recognizer = localeCandidates
            .compactMap { SFSpeechRecognizer(locale: $0) }
            .first(where: { $0.isAvailable })
        guard let recognizer else {
            AppLog.recordingError("没有可用的语音识别器，候选语言: \(localeCandidates.map(\.identifier).joined(separator: ", "))")
            finish(.failure(RecordingTranscriptionError.transcriptionUnavailable))
            return
        }
        speechRecognizer = recognizer
        AppLog.recording("开始语音识别: chunk=\(recognitionChunkIndex + 1)/\(recognitionChunks.count), start=\(String(format: "%.1f", chunk.start))s, locale=\(recognizer.locale.identifier), attempt=\(attempt), audio=\(Self.audioFileSummary(chunk.url))")
        let request = SFSpeechURLRecognitionRequest(url: chunk.url)
        // 线上识别作为首选，避免中文环境下强制离线模型却返回空结果。
        // 第一次失败后再尝试本机模型，兼顾无网络场景。
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if attempt > 0, #available(macOS 13.0, *), recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        recognitionGeneration += 1
        let generation = recognitionGeneration
        latestRecognitionText = ""
        latestRecognitionSegments = []
        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Speech 回调不保证在主线程；统一切回主线程更新会话状态和 UI。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recognitionGeneration == generation else { return }

                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let textChanged = text != self.latestRecognitionText
                        if textChanged {
                            AppLog.recording("收到语音识别文本: chars=\(text.count), final=\(result.isFinal)")
                        }
                        self.latestRecognitionText = text
                        let speechSegments = result.bestTranscription.segments
                        let formatted = result.bestTranscription.formattedString as NSString
                        self.latestRecognitionSegments = speechSegments.enumerated().map { index, segment in
                            // substring 通常只有单个词；使用相邻 substringRange 之间的
                            // 文本可一并保留系统自动补出的空格和标点。
                            let start = min(max(0, segment.substringRange.location), formatted.length)
                            let nextStart: Int
                            if index + 1 < speechSegments.count {
                                nextStart = min(
                                    max(start, speechSegments[index + 1].substringRange.location),
                                    formatted.length
                                )
                            } else {
                                nextStart = formatted.length
                            }
                            let range = NSRange(location: start, length: max(0, nextStart - start))
                            let displayText = range.length > 0
                                ? formatted.substring(with: range)
                                : segment.substring
                            return RecordingTranscriptionSegment(
                                start: chunk.start + segment.timestamp,
                                end: chunk.start + segment.timestamp + segment.duration,
                                text: displayText,
                                speakerName: "我"
                            )
                        }
                        if textChanged {
                            let combinedText = (self.accumulatedRecognitionTexts + [text])
                                .joined(separator: " ")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let readableSegments = RecordingTranscriptionSegmenter.group(
                                self.accumulatedRecognitionSegments + self.latestRecognitionSegments,
                                fallbackText: combinedText,
                                duration: self.recognitionSourceDuration
                            )
                            let partial = RecordingTranscriptionResult(
                                    audioURL: sourceURL,
                                    duration: self.recognitionSourceDuration,
                                    text: combinedText,
                                    segments: readableSegments
                                )
                            self.latestPartialResult = partial
                            self.onPartialResult?(partial)
                        }
                    }
                }

                if let error {
                    AppLog.recordingError("语音识别回调错误: chunk=\(self.recognitionChunkIndex + 1)/\(self.recognitionChunks.count), attempt=\(attempt), textChars=\(self.latestRecognitionText.count), error=\(error.localizedDescription)")
                    // 网络错误时不能把临时文字当作整段完成，否则缓存会永久缺字。
                    if attempt == 0 {
                        self.speechTask?.cancel()
                        self.startSpeechRecognition(attempt: 1)
                    } else {
                        let recovery = self.recognitionChunkIndex > 0
                            ? "已完成的分段已保留，再次点击“查看转写”可继续。"
                            : "再次点击“查看转写”可重试。"
                        self.finish(.failure(RecordingTranscriptionError.transcriptionFailed(
                            "\(error.localizedDescription)。\(recovery)"
                        )))
                    }
                    return
                }

                guard result?.isFinal == true else { return }
                guard !self.latestRecognitionText.isEmpty else {
                    AppLog.recordingError("语音识别完成但没有文本: chunk=\(self.recognitionChunkIndex + 1), attempt=\(attempt), audio=\(Self.audioFileSummary(chunk.url))")
                    if attempt == 0 {
                        self.speechTask?.cancel()
                        self.startSpeechRecognition(attempt: 1)
                    } else {
                        self.commitCurrentChunkAndContinue()
                    }
                    return
                }

                self.commitCurrentChunkAndContinue()
            }
        }
    }

    private func commitCurrentChunkAndContinue() {
        recognitionGeneration += 1
        speechTask?.cancel()
        speechTask = nil

        if !latestRecognitionText.isEmpty {
            accumulatedRecognitionTexts.append(latestRecognitionText)
            accumulatedRecognitionSegments.append(contentsOf: latestRecognitionSegments)
            AppLog.recording("片段识别完成: chunk=\(recognitionChunkIndex + 1), chars=\(latestRecognitionText.count)")
        }

        latestRecognitionText = ""
        latestRecognitionSegments = []
        recognitionChunkIndex += 1
        guard let sourceURL = recognitionSourceURL else {
            finish(.failure(RecordingTranscriptionError.noAudio))
            return
        }
        let checkpoint = RecordingTranscriptionResult(
            audioURL: sourceURL, duration: recognitionSourceDuration,
            text: accumulatedRecognitionTexts.joined(separator: " "),
            segments: accumulatedRecognitionSegments
        )
        do {
            try RecordingTranscriptStore.save(checkpoint, completedChunks: recognitionChunkIndex, isComplete: false)
        } catch {
            finish(.failure(RecordingTranscriptionError.transcriptionFailed("保存转写进度失败：\(error.localizedDescription)")))
            return
        }
        publishProgress()
        if recognitionChunkIndex < recognitionChunks.count {
            startSpeechRecognition(attempt: 0)
            return
        }
        finishAccumulatedRecognition()
    }

    private func publishProgress() {
        progress = RecordingTranscriptionProgress(
            completedChunks: recognitionChunkIndex, totalChunks: recognitionChunks.count
        )
        onProgress?(progress)
    }

    private func finishAccumulatedRecognition() {
        guard let sourceURL = recognitionSourceURL else {
            finish(.failure(RecordingTranscriptionError.noAudio))
            return
        }
        let fullText = accumulatedRecognitionTexts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            finish(.failure(RecordingTranscriptionError.noRecognizableSpeech))
            return
        }
        let segments = RecordingTranscriptionSegmenter.group(
            accumulatedRecognitionSegments,
            fallbackText: fullText,
            duration: recognitionSourceDuration
        )
        let output = RecordingTranscriptionResult(
            audioURL: sourceURL,
            duration: recognitionSourceDuration,
            text: fullText,
            segments: segments,
            engine: .appleSpeech
        )
        do {
            try RecordingTranscriptStore.save(output, completedChunks: recognitionChunks.count, isComplete: true)
        } catch {
            finish(.failure(RecordingTranscriptionError.transcriptionFailed("保存转写结果失败：\(error.localizedDescription)")))
            return
        }
        AppLog.recording("语音识别完成: chunks=\(recognitionChunks.count), chars=\(fullText.count), segments=\(segments.count)")

        // 归档未压缩录音后再交付结果；失败保持原文件。归档期间若会话已被取消则放弃交付。
        let generation = recognitionGeneration
        Task { [weak self] in
            guard let self else { return }
            let archived = await RecordingAudioArchiver.archiveIfNeeded(output)
            await MainActor.run {
                guard self.recognitionGeneration == generation else { return }
                self.audioURL = archived.audioURL
                self.finish(.success(archived))
            }
        }
    }

    private func startTimers() {
        meterTimer?.invalidate()
        elapsedTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            let normalized = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
            self.onMeterChange?(normalized)
            if Date().timeIntervalSince(self.lastMeterLogDate) >= 5 {
                self.lastMeterLogDate = Date()
                AppLog.recording("录音输入电平: averagePower=\(String(format: "%.1f", recorder.averagePower(forChannel: 0)))dB, normalized=\(String(format: "%.2f", normalized))")
            }
        }
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let startedAt = self.startedAt else { return }
            let pauseNow = self.pausedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.elapsed = max(0, Date().timeIntervalSince(startedAt) - self.pausedDuration - pauseNow)
            self.onElapsedChange?(self.elapsed)
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
        RunLoop.main.add(elapsedTimer!, forMode: .common)
    }

    private func stopTimers() {
        meterTimer?.invalidate()
        elapsedTimer?.invalidate()
        meterTimer = nil
        elapsedTimer = nil
        onMeterChange?(0)
    }

    private func failStart(_ error: Error) {
        stopTimers()
        teardownSystemAudio()
        pauseGaps = []
        activePauseStartedAt = nil
        recorder?.stop()
        recorder = nil
        state = .idle
        publishState()
        DispatchQueue.main.async { [weak self] in
            self?.onResult?(.failure(error))
        }
    }

    private func finish(_ result: Result<RecordingTranscriptionResult, Error>) {
        recognitionGeneration += 1
        highQualityTask?.cancel()
        highQualityTask = nil
        speechTask?.cancel()
        speechTask = nil
        speechRecognizer = nil
        cleanupRecognitionTemporaryFiles()
        teardownSystemAudio()
        pauseGaps = []
        activePauseStartedAt = nil
        state = .idle
        publishState()
        DispatchQueue.main.async { [weak self] in
            self?.onResult?(result)
        }
    }

    private func cleanupRecognitionTemporaryFiles() {
        if let directory = recognitionTemporaryDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        recognitionTemporaryDirectory = nil
        recognitionChunks = []
        recognitionChunkIndex = 0
        recognitionSourceURL = nil
        recognitionSourceDuration = 0
        accumulatedRecognitionTexts = []
        accumulatedRecognitionSegments = []
        latestRecognitionText = ""
        latestRecognitionSegments = []
    }

    private func publishState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange?(self.state)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func audioFileSummary(_ url: URL) -> String {
        guard let file = try? AVAudioFile(forReading: url) else { return "audio=unreadable" }
        let format = file.processingFormat
        return "frames=\(file.length), sampleRate=\(Int(format.sampleRate)), channels=\(format.channelCount)"
    }
}

private extension AVAudioRecorder {
    /// AVAudioRecorder normally leaves a valid file even for a very short recording.
    /// Keep this helper intentionally conservative; invalid files are rejected by the manager.
    func deleteRecordingIfEmpty() {
        let url = url
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue == 0 else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
