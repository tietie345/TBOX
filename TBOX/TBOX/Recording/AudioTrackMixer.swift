import AVFoundation

/// 把麦克风轨与系统声音轨混合为单声道 48 kHz 录音，作为转写与说话人分离的输入。
///
/// 麦克风轨由 `AVAudioRecorder` 以 48 kHz 单声道 Linear PCM 录制，系统声音轨由
/// `SystemAudioRecorder` 以 48 kHz 双声道 AAC 录制（只含系统/其他 App 播放的声音，
/// 即线上会议里对方的声音）。两轨都归一到 48 kHz 单声道浮点后逐样本相加。
///
/// 对齐约定：输出时间轴等于麦克风的「有效录音时间轴」。录音过程中暂停只中断麦克风轨，
/// 不中断系统声音轨，因此暂停区间对应的系统声音会被跳过——用户按下暂停即表示
/// 这段不要，与其预期一致。
enum AudioTrackMixer {
    struct PauseGap {
        /// 暂停发生在麦克风有效录音时间轴上的位置（秒）。
        let activeTime: TimeInterval
        /// 暂停时长（秒），即需要跳过的系统声音长度。
        let duration: TimeInterval
    }

    static let sampleRate: Double = 48_000

    /// 单轨混合增益。两轨满幅相加会削顶，各留一定余量后硬限幅。
    private static let microphoneGain: Float = 0.85
    private static let systemGain: Float = 0.85
    /// 每次处理的帧数，控制内存占用（16384 帧 ≈ 0.34 秒）。
    private static let chunkFrames = 16_384

    enum MixError: LocalizedError {
        case unreadableTrack
        case emptyMicrophone
        case noOutput

        var errorDescription: String? {
            switch self {
            case .unreadableTrack: return "无法读取待混音的音轨"
            case .emptyMicrophone: return "麦克风轨没有有效音频"
            case .noOutput: return "混音没有产生有效音频"
            }
        }
    }

    /// 混合两轨并写出到 `outputURL`。任何失败都返回 nil，调用方应保留麦克风原文件。
    static func mix(
        microphoneURL: URL,
        systemAudioURL: URL,
        pauseGaps: [PauseGap],
        outputURL: URL
    ) -> URL? {
        do {
            return try performMix(
                microphoneURL: microphoneURL,
                systemAudioURL: systemAudioURL,
                pauseGaps: pauseGaps,
                outputURL: outputURL
            )
        } catch {
            AppLog.recordingError("双轨混音失败，改用麦克风单轨: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    private static func performMix(
        microphoneURL: URL,
        systemAudioURL: URL,
        pauseGaps: [PauseGap],
        outputURL: URL
    ) throws -> URL {
        guard let microphone = TrackReader(url: microphoneURL),
            let system = TrackReader(url: systemAudioURL) else {
            throw MixError.unreadableTrack
        }
        guard microphone.duration > 0.1 else { throw MixError.emptyMicrophone }

        let output = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])

        let totalFrames = Int((microphone.duration * sampleRate).rounded())
        var consumedFrames = 0

        for gap in pauseGaps.sorted(by: { $0.activeTime < $1.activeTime }) {
            let boundary = min(max(0, Int((gap.activeTime * sampleRate).rounded())), totalFrames)
            let span = boundary - consumedFrames
            if span > 0 {
                try mixSpan(frames: span, microphone: microphone, system: system, output: output)
                consumedFrames = boundary
            }
            let skip = max(0, Int((gap.duration * sampleRate).rounded()))
            if skip > 0 { _ = system.read(maxFrames: skip) }
        }

        let remaining = totalFrames - consumedFrames
        if remaining > 0 {
            try mixSpan(frames: remaining, microphone: microphone, system: system, output: output)
        }

        guard output.length > 0 else { throw MixError.noOutput }
        return outputURL
    }

    /// 顺序混合 `frames` 帧：麦克风主轨 + 系统声音叠加。
    private static func mixSpan(
        frames: Int,
        microphone: TrackReader,
        system: TrackReader,
        output: AVAudioFile
    ) throws {
        var remaining = frames
        while remaining > 0 {
            let chunk = min(remaining, chunkFrames)
            let micSamples = microphone.read(maxFrames: chunk)
            let systemSamples = system.read(maxFrames: chunk)
            if micSamples.isEmpty && systemSamples.isEmpty { break }

            let count = max(micSamples.count, systemSamples.count)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: output.processingFormat,
                frameCapacity: AVAudioFrameCount(count)
            ) else { throw MixError.noOutput }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channel = buffer.floatChannelData?[0] {
                for index in 0..<count {
                    let mic = index < micSamples.count ? micSamples[index] : 0
                    let system = index < systemSamples.count ? systemSamples[index] : 0
                    channel[index] = max(-1, min(1, mic * microphoneGain + system * systemGain))
                }
            }
            try output.write(from: buffer)
            remaining -= count
        }
    }

    /// 把任意格式音轨按需读成 48 kHz 单声道浮点样本，兼顾采样率与声道数差异。
    private final class TrackReader {
        private let file: AVAudioFile
        private let converter: AVAudioConverter
        private let outputFormat: AVAudioFormat
        private let inputBuffer: AVAudioPCMBuffer
        private var reachedEnd = false

        /// 音轨时长（秒），按源文件自身的采样率计算。
        let duration: TimeInterval

        init?(url: URL) {
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            let inputFormat = file.processingFormat
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: AudioTrackMixer.sampleRate,
                    channels: 1,
                    interleaved: false
                ),
                let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
                let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8_192) else {
                return nil
            }
            self.file = file
            self.converter = converter
            self.outputFormat = outputFormat
            self.inputBuffer = inputBuffer
            self.duration = Double(file.length) / inputFormat.sampleRate
        }

        /// 读取最多 `maxFrames` 个样本；到达文件末尾时返回剩余样本（可能为空）。
        func read(maxFrames: Int) -> [Float] {
            guard maxFrames > 0, !reachedEnd,
                let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(maxFrames)
                ) else { return [] }

            var error: NSError?
            let inputBuffer = self.inputBuffer
            let file = self.file
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if self.reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inputBuffer.frameLength = 0
                do {
                    try file.read(into: inputBuffer)
                } catch {
                    self.reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard inputBuffer.frameLength > 0 else {
                    self.reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if status == .error {
                reachedEnd = true
                return []
            }
            guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
    }
}
