import AVFoundation
import Cocoa
import CoreMedia
import ScreenCaptureKit

enum ScreenRecorderError: LocalizedError {
    case displayNotFound
    case cannotAddOutput(String)
    case writerSetup(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到要录制的显示器"
        case .cannotAddOutput(let message): return "无法接收录屏数据：\(message)"
        case .writerSetup(let message): return "无法创建视频文件：\(message)"
        case .noFrames: return "没有录到画面，请检查屏幕录制权限"
        }
    }
}

/// ScreenCaptureKit + AVAssetWriter 录屏管线。视频为 H.264，系统声音为 AAC。
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    enum State { case idle, starting, recording, paused, stopping }

    private static let targetFrameRate: Int32 = 60

    private(set) var state: State = .idle
    private(set) var outputURL: URL?
    var onStateChange: ((State) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.tbox.recording.samples")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var sessionStartTime: CMTime?
    private var appendedVideoFrame = false
    private var receivedVideoFrameCount: UInt64 = 0
    private var receivedAudioFrameCount: UInt64 = 0
    private var recordingBeganAt: Date?
    private var mediaTimeOffset = CMTime.zero
    private var lastVideoSourceTime: CMTime?
    private var isResuming = false
    private var reportedWriterFailure = false
    private var finishCompletion: ((Result<URL, Error>) -> Void)?

    func start(displayID: CGDirectDisplayID, sourceRect: CGRect, completion: @escaping (Result<Void, Error>) -> Void) {
        guard state == .idle else { return }
        state = .starting
        publishState()

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error { self.failStart(error, completion: completion); return }
            guard let content,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                self.failStart(ScreenRecorderError.displayNotFound, completion: completion)
                return
            }

            do {
                let config = SCStreamConfiguration()
                let rect = sourceRect.standardized.intersection(CGRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height))
                let captureRect = rect.isNull || rect.isEmpty
                    ? CGRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height)
                    : rect
                let scaleX = CGFloat(display.width) / max(display.frame.width, 1)
                let scaleY = CGFloat(display.height) / max(display.frame.height, 1)
                let width = Self.evenPixelCount(captureRect.width * scaleX)
                let height = Self.evenPixelCount(captureRect.height * scaleY)

                config.sourceRect = captureRect
                config.width = width
                config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: Self.targetFrameRate)
                config.queueDepth = 8
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.scalesToFit = false
                config.preservesAspectRatio = true
                config.captureResolution = .best
                config.showsCursor = true
                if #available(macOS 15.0, *) { config.showMouseClicks = true }
                config.capturesAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                config.excludesCurrentProcessAudio = true

                let bitRate = Self.videoBitRate(width: width, height: height)
                try self.prepareWriter(width: width, height: height, bitRate: bitRate)
                let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
                self.stream = stream
                stream.startCapture { error in
                    DispatchQueue.main.async {
                        if let error {
                            self.failStart(error, completion: completion)
                        } else {
                            self.state = .recording
                            self.recordingBeganAt = Date()
                            self.publishState()
                            AppLog.recording(
                                "录屏开始: \(width)x\(height) @ \(Self.targetFrameRate)fps, " +
                                "H.264 \(bitRate / 1_000_000)Mbps, 系统声音开启"
                            )
                            completion(.success(()))
                        }
                    }
                }
            } catch {
                self.failStart(error, completion: completion)
            }
        }
    }

    func togglePause() {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .recording: self.state = .paused
            case .paused:
                self.isResuming = true
                self.state = .recording
            default: return
            }
            self.publishState()
        }
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard state == .recording || state == .paused else { return }
        state = .stopping
        publishState()
        finishCompletion = completion
        guard let stream else { finishWriting(); return }
        stream.stopCapture { [weak self] error in
            guard let self else { return }
            self.sampleQueue.async {
                if let error { AppLog.recordingError("停止捕获异常: \(error.localizedDescription)") }
                self.finishWriting()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLog.recordingError("录屏流停止: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard state == .recording, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // SCStream 会持续推送 .idle（画面无变化）/ .blank / .started 等占位帧，
        // 这些帧没有完整像素数据。一旦喂给 AVAssetWriter，writer 会立刻进入
        // failed 状态，之后所有真实帧全部被拒（表现为“收到帧但一帧都写不进”）。
        // 官方示例同样只接受 .complete 帧，这里必须过滤。
        if outputType == .screen, !Self.isCompleteFrame(sampleBuffer) { return }

        if isResuming {
            // 以恢复后的第一帧视频为基准移除暂停间隔，音视频时间轴不会留下静止空洞。
            guard outputType == .screen else { return }
            if let lastVideoSourceTime {
                let expectedFrame = CMTime(value: 1, timescale: Self.targetFrameRate)
                let gap = CMTimeSubtract(CMTimeSubtract(timestamp, lastVideoSourceTime), expectedFrame)
                if CMTimeCompare(gap, .zero) > 0 { mediaTimeOffset = CMTimeAdd(mediaTimeOffset, gap) }
            }
            isResuming = false
        }

        if !sessionStarted {
            guard outputType == .screen, let writer else { return }
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
            sessionStartTime = timestamp
            sessionStarted = true
        }

        switch outputType {
        case .screen:
            receivedVideoFrameCount += 1
            // 编码器要求 PTS 严格递增；SCStream 偶发的重复/乱序时间戳帧直接丢弃，
            // 否则同样会让 writer 进入 failed 状态并拒绝后续所有帧。
            if let lastVideoSourceTime, CMTimeCompare(timestamp, lastVideoSourceTime) <= 0 { return }
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            lastVideoSourceTime = timestamp
            guard let adjusted = retimedSampleBuffer(sampleBuffer) else { return }
            if videoInput.append(adjusted) {
                appendedVideoFrame = true
            } else if !reportedWriterFailure {
                // 首次写入被拒时记录 writer 状态与错误，为后续诊断留下第一手信息。
                reportedWriterFailure = true
                AppLog.recordingError(
                    "视频帧写入被拒绝: writerStatus=\(writer?.status.rawValue ?? -1), " +
                    "error=\(writer?.error.map { "\($0)" } ?? "无")"
                )
            }
        case .audio:
            receivedAudioFrameCount += 1
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            // 会话起点由第一帧有效视频决定；早于起点的音频块无法写入，直接丢弃。
            if let sessionStartTime, CMTimeCompare(timestamp, sessionStartTime) < 0 { return }
            guard let adjusted = retimedSampleBuffer(sampleBuffer) else { return }
            audioInput.append(adjusted)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let statusRawValue = attachments.first?[SCStreamFrameInfo.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue) else { return false }
        return status == .complete
    }

    private func prepareWriter(width: Int, height: Int, bitRate: Int) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TBOX-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // 屏幕文字和细线比普通视频更怕压缩失真。按原生像素数动态分配码率：
                // 1080p≈16Mbps、Retina 3.5K≈62Mbps、4K≈66Mbps，最高 100Mbps。
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.targetFrameRate),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.targetFrameRate * 2),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw ScreenRecorderError.writerSetup("H.264 编码器不可用") }
        writer.add(videoInput)

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) { writer.add(audioInput) }

        self.outputURL = url
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    private func finishWriting() {
        guard let writer, let outputURL else {
            diagnoseNoFrames(reason: "writer 未创建")
            completeStop(.failure(ScreenRecorderError.noFrames))
            return
        }
        guard sessionStarted, appendedVideoFrame else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            diagnoseNoFrames(reason: sessionStarted ? "收到帧但编码器拒绝写入" : "未收到任何屏幕帧")
            completeStop(.failure(ScreenRecorderError.noFrames))
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            if writer.status == .completed {
                self.completeStop(.success(outputURL))
            } else {
                self.completeStop(.failure(writer.error ?? ScreenRecorderError.writerSetup("视频写入失败")))
            }
        }
    }

    /// 无帧时记录关键诊断：SCStream 启动成功却不产帧，99% 是当前进程的屏幕录制
    /// 权限状态与系统 TCC 不一致（运行期间授权/签名变更后未重启）。
    private func diagnoseNoFrames(reason: String) {
        let duration = recordingBeganAt.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
        let preflight = CGPreflightScreenCaptureAccess()
        let writerState = writer.map {
            "status=\($0.status.rawValue), error=\($0.error.map { "\($0)" } ?? "无")"
        } ?? "writer未创建"
        AppLog.recordingError(
            "录屏无帧（\(reason)）：时长\(duration)s, 收到视频帧=\(receivedVideoFrameCount), " +
            "音频帧=\(receivedAudioFrameCount), 实时权限预检=\(preflight ? "允许" : "拒绝"), " +
            "writer[\(writerState)]。" +
            "若预检允许但帧数为0，请完全退出 TBOX（Cmd+Q）后重新打开再录。"
        )
    }

    private func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard CMTimeCompare(mediaTimeOffset, .zero) > 0 else { return sampleBuffer }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        let status = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        guard status == noErr else { return nil }
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, mediaTimeOffset)
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, mediaTimeOffset)
            }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        ) == noErr else { return nil }
        return copy
    }

    private func completeStop(_ result: Result<URL, Error>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stream = nil
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.sessionStarted = false
            self.sessionStartTime = nil
            self.appendedVideoFrame = false
            self.receivedVideoFrameCount = 0
            self.receivedAudioFrameCount = 0
            self.recordingBeganAt = nil
            self.mediaTimeOffset = .zero
            self.lastVideoSourceTime = nil
            self.isResuming = false
            self.reportedWriterFailure = false
            self.state = .idle
            self.publishState()
            let completion = self.finishCompletion
            self.finishCompletion = nil
            completion?(result)
        }
    }

    private func failStart(_ error: Error, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.stream = nil
            self?.writer?.cancelWriting()
            if let outputURL = self?.outputURL { try? FileManager.default.removeItem(at: outputURL) }
            self?.writer = nil
            self?.videoInput = nil
            self?.audioInput = nil
            self?.sessionStarted = false
            self?.sessionStartTime = nil
            self?.appendedVideoFrame = false
            self?.reportedWriterFailure = false
            self?.state = .idle
            self?.publishState()
            let nsError = error as NSError
            AppLog.recordingError(
                "录屏启动失败: domain=\(nsError.domain) code=\(nsError.code) " +
                "desc=\(nsError.localizedDescription) preflight=\(CGPreflightScreenCaptureAccess())"
            )
            completion(.failure(error))
        }
    }

    private func publishState() {
        let value = state
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(value) }
    }

    private static func evenPixelCount(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded(.down)) & ~1)
    }

    private static func videoBitRate(width: Int, height: Int) -> Int {
        let nativePixelRate = width * height * 8
        return max(16_000_000, min(100_000_000, nativePixelRate))
    }
}
