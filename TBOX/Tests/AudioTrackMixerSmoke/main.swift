import AVFoundation
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("失败：\(message)\n", stderr)
        exit(1)
    }
}

private let sampleRate: Double = 48_000

private func writeTone(
    url: URL,
    channels: AVAudioChannelCount,
    frequency: Double,
    amplitude: Float,
    seconds: Double,
    aac: Bool = false
) throws {
    let settings: [String: Any]
    if aac {
        // 与 SystemAudioRecorder 一致：48 kHz AAC。
        settings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ]
    } else {
        settings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    ) else { throw NSError(domain: "tone", code: 1) }

    let total = AVAudioFrameCount(seconds * sampleRate)
    let chunk: AVAudioFrameCount = 4_096
    var written: AVAudioFrameCount = 0
    while written < total {
        let count = min(chunk, total - written)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw NSError(domain: "tone", code: 2)
        }
        buffer.frameLength = count
        for channel in 0..<Int(channels) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for index in 0..<Int(count) {
                let position = Double(written + AVAudioFrameCount(index))
                samples[index] = amplitude * Float(sin(2 * Double.pi * frequency * position / sampleRate))
            }
        }
        try file.write(from: buffer)
        written += count
    }
}

/// 读取整段音频为 48 kHz 单声道浮点样本。
private func readMono(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ), let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
        throw NSError(domain: "read", code: 1)
    }
    let total = AVAudioFrameCount(Double(file.length) / file.processingFormat.sampleRate * sampleRate)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total + 4_096)!
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)!
    var reachedEnd = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if reachedEnd { status.pointee = .endOfStream; return nil }
        input.frameLength = 0
        try? file.read(into: input)
        guard input.frameLength > 0 else {
            reachedEnd = true
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return input
    }
    guard let channel = output.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
}

/// 用正交相关估计某个频率上的幅度（Goertzel 思想的直接实现）。
private func toneAmplitude(_ samples: [Float], frequency: Double) -> Float {
    guard !samples.isEmpty else { return 0 }
    var real: Double = 0
    var imaginary: Double = 0
    for (index, value) in samples.enumerated() {
        let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
        real += Double(value) * cos(phase)
        imaginary += Double(value) * sin(phase)
    }
    return Float(2 * (real * real + imaginary * imaginary).squareRoot() / Double(samples.count))
}

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("TBOX-Mixer-Smoke-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

let microphoneURL = directory.appendingPathComponent("mic.caf")
let systemURL = directory.appendingPathComponent("system.m4a")
try writeTone(url: microphoneURL, channels: 1, frequency: 440, amplitude: 0.5, seconds: 1.0)
try writeTone(url: systemURL, channels: 2, frequency: 880, amplitude: 0.5, seconds: 1.0, aac: true)

// MARK: - 基本混音：两轨同长、无暂停

let mixedURL = directory.appendingPathComponent("mixed.caf")
let mixed = AudioTrackMixer.mix(
    microphoneURL: microphoneURL,
    systemAudioURL: systemURL,
    pauseGaps: [],
    outputURL: mixedURL
)
require(mixed != nil, "混音应成功")

let samples = try readMono(mixedURL)
let mixedDuration = Double(samples.count) / sampleRate
require(abs(mixedDuration - 1.0) < 0.05, "混音时长应约为 1.0s，实际 \(mixedDuration)")

let micLevel = toneAmplitude(samples, frequency: 440)
let systemLevel = toneAmplitude(samples, frequency: 880)
require(micLevel > 0.2, "混音应保留麦克风 440Hz 成分，实际幅度 \(micLevel)")
require(systemLevel > 0.2, "混音应保留系统声音 880Hz 成分，实际幅度 \(systemLevel)")

// MARK: - 暂停区间：输出仍是麦克风时间轴长度，系统声音被跳过

let pauseMixedURL = directory.appendingPathComponent("mixed-pause.caf")
let pauseMixed = AudioTrackMixer.mix(
    microphoneURL: microphoneURL,
    systemAudioURL: systemURL,
    pauseGaps: [AudioTrackMixer.PauseGap(activeTime: 0.4, duration: 0.3)],
    outputURL: pauseMixedURL
)
require(pauseMixed != nil, "带暂停区间的混音应成功")
let pauseSamples = try readMono(pauseMixedURL)
let pauseDuration = Double(pauseSamples.count) / sampleRate
require(abs(pauseDuration - 1.0) < 0.05, "暂停不应加长输出，应仍约为 1.0s，实际 \(pauseDuration)")
require(abs(pauseDuration - mixedDuration) < 0.05, "暂停前后输出长度应一致")

// MARK: - 降级：系统声音文件不可读时返回 nil，调用方保留麦克风原文件

let missingURL = directory.appendingPathComponent("not-exist.caf")
let failed = AudioTrackMixer.mix(
    microphoneURL: microphoneURL,
    systemAudioURL: missingURL,
    pauseGaps: [],
    outputURL: directory.appendingPathComponent("should-not-exist.caf")
)
require(failed == nil, "系统声音不可读时应返回 nil")
require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist.caf").path),
        "混音失败时应清理半成品文件")

print("AudioTrackMixer 冒烟测试通过")
