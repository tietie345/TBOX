import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// 系统声音采集器：用 ScreenCaptureKit 只抓「系统/其他 App 播放的声音」，
/// 写成 48 kHz 单声道 AAC 的 `.m4a`，供与麦克风轨混音。
///
/// 线上会议里对方的声音只存在于系统输出，麦克风轨抓不到；这一路专门补齐。
/// 需要“屏幕录制”权限（与截图/录屏同一权限）。任何失败都只记日志并降级为
/// 仅有麦克风轨，绝不阻断录音主流程。
///
/// 采集的是系统输出，不涉及麦克风回环；`excludesCurrentProcessAudio` 保证
/// 不会把 TBOX 自己播放的声音混进去。
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    enum State { case idle, starting, recording, stopping }

    /// 系统声音文件地址（录制成功后可用）。
    private(set) var outputURL: URL?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var state: State = .idle
    private let sampleQueue = DispatchQueue(label: "com.tbox.systemAudio.samples")
    private var failureReason: String?

    var isRecording: Bool { state == .recording }

    /// 开始采集。失败时通过 completion 返回错误，调用方据此降级为仅麦克风。
    func start(completion: @escaping (Error?) -> Void) {
        guard state == .idle else { return }
        state = .starting

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
            [weak self] content, error in
            guard let self else { return }
            if let error {
                self.failStart(error, completion: completion)
                return
            }
            guard let content, let display = content.displays.first else {
                self.failStart(SystemAudioRecorderError.displayNotFound, completion: completion)
                return
            }

            do {
                let config = SCStreamConfiguration()
                // 只要音频：把画面压到最小、帧率压到最低，几乎不产生额外开销。
                // 尺寸取 32×32 而非 2×2，避免个别系统版本对过小尺寸报错。
                config.width = 32
                config.height = 32
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 6
                config.capturesAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                config.excludesCurrentProcessAudio = true

                try self.prepareWriter()
                let ownApps = content.applications.filter {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: ownApps,
                    exceptingWindows: []
                )
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
                self.stream = stream
                stream.startCapture { error in
                    DispatchQueue.main.async {
                        if let error {
                            self.failStart(error, completion: completion)
                        } else {
                            self.state = .recording
                            AppLog.recording("系统声音采集已启动: url=\(self.outputURL?.path ?? "nil")")
                            completion(nil)
                        }
                    }
                }
            } catch {
                self.failStart(error, completion: completion)
            }
        }
    }

    /// 停止采集并完成写盘。无有效音频时 completion 返回 nil。
    func stop(completion: @escaping (URL?) -> Void) {
        guard state == .recording || state == .starting else {
            completion(nil)
            return
        }
        state = .stopping
        let stream = self.stream
        stream?.stopCapture { [weak self] _ in
            guard let self else { return }
            self.sampleQueue.async {
                self.finishWriting(completion: completion)
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
            state == .recording || state == .starting,
            sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer?.startWriting()
            writer?.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failureReason = error.localizedDescription
        AppLog.recordingError("系统声音采集中断: \(error.localizedDescription)")
    }

    // MARK: - 内部

    private func prepareWriter() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TBOX-SystemAudio-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw SystemAudioRecorderError.writerSetup }
        writer.add(input)
        self.writer = writer
        self.audioInput = input
        self.outputURL = url
    }

    private func finishWriting(completion: @escaping (URL?) -> Void) {
        guard let writer, let url = outputURL, sessionStarted else {
            cleanup()
            completion(nil)
            return
        }
        audioInput?.markAsFinished()
        let box = WriterBox(writer)
        box.writer.finishWriting {
            DispatchQueue.main.async {
                let ok = box.writer.status == .completed
                if !ok {
                    AppLog.recordingError(
                        "系统声音写盘失败: status=\(box.writer.status.rawValue), error=\(box.writer.error.map { "\($0)" } ?? "无")"
                    )
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                self.cleanup()
                completion(ok && size > 0 ? url : nil)
            }
        }
    }

    private func cleanup() {
        stream = nil
        writer = nil
        audioInput = nil
        sessionStarted = false
        state = .idle
    }

    private func failStart(_ error: Error, completion: @escaping (Error?) -> Void) {
        AppLog.recordingError("系统声音采集不可用，将仅录制麦克风: \(error.localizedDescription)")
        writer?.cancelWriting()
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        cleanup()
        completion(error)
    }

    /// AVAssetWriter 的完成回调在系统队列执行，用受控包装满足 Sendable 检查。
    private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter
        init(_ writer: AVAssetWriter) { self.writer = writer }
    }
}

enum SystemAudioRecorderError: LocalizedError {
    case displayNotFound
    case writerSetup

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到可用于音频采集的显示器"
        case .writerSetup: return "无法创建系统声音写入器"
        }
    }
}

extension RecordingTranscriptionPreferences {
    /// 是否在录音转写时同时采集系统声音（会议对方声音）。
    static let captureSystemAudioKey = "captureSystemAudio"
}

extension SystemAudioRecorder {
    /// 是否启用系统声音采集；缺省视为开启（线上会议对方声音是核心场景）。
    /// 权限不足或采集失败时自动降级为仅麦克风，不会阻断录音。
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: RecordingTranscriptionPreferences.captureSystemAudioKey) != nil else {
            return true
        }
        return defaults.bool(forKey: RecordingTranscriptionPreferences.captureSystemAudioKey)
    }
}
