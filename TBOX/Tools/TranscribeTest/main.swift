// 独立转写诊断工具：用与 TBOX 完全相同的模型和参数转写指定音频，
// 打印每一步的真实输出，用于定位“没有识别出文字”的根因。
import Foundation
import WhisperKit

let audioPaths = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst())
    : ["/tmp/tbox_rec.wav"]

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let modelDirectory = appSupport
    .appendingPathComponent("TBOX", isDirectory: true)
    .appendingPathComponent("Models", isDirectory: true)
let modelFolder = modelDirectory
    .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB")

print("模型目录: \(modelFolder.path)")
print("音频文件: \(audioPaths.joined(separator: ", "))")
for path in audioPaths where !FileManager.default.fileExists(atPath: path) {
    print("❌ 音频不存在: \(path)"); exit(1)
}
guard FileManager.default.fileExists(atPath: modelFolder.path) else {
    print("❌ 模型不存在"); exit(1)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: modelDirectory,
            verbose: true,
            prewarm: true,
            load: true,
            download: false
        )
        let loadStart = Date()
        let pipeline = try await WhisperKit(config)
        print("✅ 模型加载成功，耗时 \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s")

        // 第一轮：TBOX 当前线上同款参数（VAD 分块）
        var options = DecodingOptions(
            language: nil,
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: false,
            wordTimestamps: true,
            suppressBlank: false,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )
        options.task = .transcribe
        let inputOptions = AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: .incremental
        )

        for (fileIndex, path) in audioPaths.enumerated() {
            print("\n########## 文件 \(fileIndex + 1)/\(audioPaths.count): \(path) ##########")

            print("—— 第一轮：TBOX 同款参数（VAD 分块）——")
            let t1 = Date()
            let results = try await pipeline.transcribe(
                audioPath: path,
                audioInputOptions: inputOptions,
                decodeOptions: options
            )
            print("耗时 \(String(format: "%.1f", Date().timeIntervalSince(t1)))s, 分块数 \(results.count)")
            for (index, result) in results.enumerated() {
                print("RESULT chunk=\(index) lang=\(result.language) text=\(result.text)")
            }

            print("—— 第二轮：默认参数（无分块）——")
            var simple = DecodingOptions()
            simple.task = .transcribe
            simple.wordTimestamps = true
            let t2 = Date()
            let results2 = try await pipeline.transcribe(audioPath: path, decodeOptions: simple)
            print("耗时 \(String(format: "%.1f", Date().timeIntervalSince(t2)))s, 分块数 \(results2.count)")
            for (index, result) in results2.enumerated() {
                print("RESULT chunk=\(index) lang=\(result.language) text=\(result.text)")
            }
        }
    } catch {
        print("❌ 失败: \(error)")
    }
    semaphore.signal()
}
semaphore.wait()
