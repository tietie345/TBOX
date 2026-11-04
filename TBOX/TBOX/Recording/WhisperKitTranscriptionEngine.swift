import Foundation

#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

/// 固定并集中管理本地语音模型，避免界面、业务代码和构建脚本各自维护一套名称。
enum TBOXTranscriptionModel {
    static let engineVersion = "WhisperKit 1.1.0"
    static let modelName = "large-v3-v20240930_626MB"
    static let approximateDownloadSize = "约 626 MB"

    static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TBOX", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static var isInstalled: Bool {
        installedModelFolder != nil
    }

    /// 已安装模型变体的本地目录；未安装返回 nil。
    /// 加载时直接用这个路径做纯本地加载，避免为了“核对快照”而去联网。
    static var installedModelFolder: URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: storageDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.lastPathComponent.contains(modelName), hasRequiredModels(in: url) {
                return url
            }
        }
        return nil
    }

    private static func hasRequiredModels(in directory: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { extensionName in
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("\(name).\(extensionName)").path
                )
            }
        }
    }
}

enum HighQualityTranscriptionEngineError: LocalizedError {
    case unavailable
    case emptyResult(averageLevelDB: Double?)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "当前构建未包含本地高精度转写引擎"
        case .emptyResult(let level):
            var message = "录音中没有识别出清晰人声（本地模型工作正常）"
            if let level {
                if level < -40 {
                    message += String(
                        format: "。录音全程平均电平约 %.0f dB，明显偏低：请距离麦克风更近或提高声源音量后重新录制", level
                    )
                } else {
                    message += "。环境噪声较大或声源距离过远，建议在安静环境中近距离清晰说话重新录制"
                }
            } else {
                message += "。请确认录制内容包含清晰人声"
            }
            return message
        }
    }
}

struct HighQualityTranscriptionOutput: Sendable {
    /// 清洗后的完整识别文本（聚合和说话人标注在管线后段完成）。
    let text: String
    /// 词级片段，带时间戳；说话人标注在管线后段按时间重叠合并。
    let wordSegments: [RecordingTranscriptionSegment]
    /// 词级时间对齐是否足以支撑句段聚合；不足时由调用方回退到句级时间。
    let hasUsableAlignment: Bool
    let language: String
}

/// 对上层隐藏第三方 SDK 类型。即使精简测试没有链接 WhisperKit，Apple Speech
/// 兼容路径仍可独立编译和验证。
enum HighQualityTranscriptionEngine {
    static var isAvailable: Bool {
        #if canImport(WhisperKit)
        true
        #else
        false
        #endif
    }

    static func transcribe(
        audioURL: URL,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (RecordingTranscriptionProgress) -> Void
    ) async throws -> HighQualityTranscriptionOutput {
        #if canImport(WhisperKit)
        return try await WhisperKitPipeline.shared.transcribe(
            audioURL: audioURL,
            duration: duration,
            onProgress: onProgress
        )
        #else
        throw HighQualityTranscriptionEngineError.unavailable
        #endif
    }
}

#if canImport(WhisperKit)
private actor WhisperKitPipeline {
    static let shared = WhisperKitPipeline()

    private var pipeline: WhisperKit?

    private final class DownloadProgressRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPercentage = -1

        func report(_ progress: Progress, to callback: @escaping @Sendable (RecordingTranscriptionProgress) -> Void) {
            let percentage = Int((progress.fractionCompleted * 100).rounded())
            lock.lock()
            let changed = percentage != lastPercentage
            if changed { lastPercentage = percentage }
            lock.unlock()
            guard changed else { return }
            callback(
                RecordingTranscriptionProgress(
                    completedChunks: Int(progress.completedUnitCount),
                    totalChunks: Int(progress.totalUnitCount),
                    statusMessage: "正在准备高精度模型 · \(percentage)%"
                )
            )
        }
    }

    func transcribe(
        audioURL: URL,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (RecordingTranscriptionProgress) -> Void
    ) async throws -> HighQualityTranscriptionOutput {
        let pipeline = try await loadPipeline(onProgress: onProgress)
        // 音频只解码一次：语言探测与电平诊断共用，避免大文件重复读取。
        let samples = try? AudioProcessor.loadAudioAsFloatArray(
            fromPath: audioURL.path,
            channelMode: .sumChannels(nil),
            startTime: 0,
            endTime: min(duration, 600)
        )
        let detectedLanguage = await detectSpeechLanguage(
            pipeline: pipeline,
            samples: samples,
            duration: duration,
            onProgress: onProgress
        )
        onProgress(
            RecordingTranscriptionProgress(
                completedChunks: 0,
                totalChunks: 0,
                statusMessage: detectedLanguage.map { "已识别语言 \($0) · 正在本地转写…" }
                    ?? "正在使用本地高精度模型识别…"
            )
        )

        var options = DecodingOptions(
            // Keep per-window language detection enabled. Forcing the VAD probe's
            // language into WhisperKit 1.1.0 can produce empty Chinese results on
            // long recordings; the probe is used for stable result metadata.
            language: nil,
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: true,
            // WhisperKit 1.1.0 can remove ordinary Chinese word timings when
            // `skipSpecialTokens` is combined with word timestamps. Preserve
            // the timings here and strip control markers in `cleanedModelText`.
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
        // 固定使用转写任务，避免模型根据语言自动翻译成英文。
        options.task = .transcribe

        let inputOptions = AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: .incremental
        )
        let results = try await pipeline.transcribe(
            audioPath: audioURL.path,
            audioInputOptions: inputOptions,
            decodeOptions: options
        )

        let wordSegments = results.flatMap { result in
            result.segments.flatMap { segment -> [RecordingTranscriptionSegment] in
                let words = segment.words ?? []
                if !words.isEmpty {
                    return words.compactMap { word in
                        let cleaned = Self.cleanedModelText(word.word)
                        let start = max(0, min(duration, TimeInterval(word.start)))
                        let end = max(start, min(duration, TimeInterval(word.end)))
                        // Chinese alignment probabilities are not calibrated like
                        // English token probabilities. Do not discard valid Han
                        // characters using a universal per-word threshold.
                        guard !cleaned.isEmpty, end > start else { return nil }
                        return RecordingTranscriptionSegment(
                            start: start,
                            end: end,
                            text: cleaned,
                            speakerName: "我"
                        )
                    }
                }

                let cleaned = Self.cleanedModelText(segment.text)
                let start = max(0, min(duration, TimeInterval(segment.start)))
                let end = max(start, min(duration, TimeInterval(segment.end)))
                guard !cleaned.isEmpty, end > start else { return [] }
                return [
                    RecordingTranscriptionSegment(
                        start: start,
                        end: end,
                        text: cleaned,
                        speakerName: "我"
                    )
                ]
            }
        }
        let rawText = results
            .map(\.text)
            .map(Self.cleanedModelText)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let alignedCharacterCount = wordSegments.reduce(0) { $0 + $1.text.count }
        let hasUsableAlignment = rawText.isEmpty
            || alignedCharacterCount >= max(1, rawText.count / 2)
        if !hasUsableAlignment {
            AppLog.recordingError(
                "词级时间对齐覆盖不足，保留完整原文并降级为句级时间: alignedChars=\(alignedCharacterCount), rawChars=\(rawText.count)"
            )
        }
        guard !rawText.isEmpty else {
            throw HighQualityTranscriptionEngineError.emptyResult(
                averageLevelDB: Self.averageLevelDB(samples)
            )
        }

        let language = detectedLanguage ?? Self.dominantLanguage(in: results)
        return HighQualityTranscriptionOutput(
            text: rawText,
            wordSegments: wordSegments,
            hasUsableAlignment: hasUsableAlignment,
            language: language
        )
    }

    /// Language detection on the file's first 30 seconds is unreliable when a
    /// recording starts with silence. Probe up to five minutes, keep only VAD
    /// speech frames, and detect once for stable result metadata. Individual
    /// decoding windows still use automatic detection for WhisperKit stability.
    private func detectSpeechLanguage(
        pipeline: WhisperKit,
        samples: [Float]?,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (RecordingTranscriptionProgress) -> Void
    ) async -> String? {
        onProgress(
            RecordingTranscriptionProgress(
                completedChunks: 0,
                totalChunks: 0,
                statusMessage: "正在分析录音语言…"
            )
        )
        do {
            // 复用调用方已解码的音频，最多取前 5 分钟用于语言探测。
            guard let loaded = samples, !loaded.isEmpty else { return nil }
            let probeCap = WhisperKit.sampleRate * 300
            let samples = loaded.count > probeCap ? Array(loaded.prefix(probeCap)) : loaded
            let vad = EnergyVAD(frameLength: 0.1, frameOverlap: 0.02, energyThreshold: 0.01)
            let activeChunks = vad.calculateActiveChunks(in: samples)
            let maximumSamples = WhisperKit.sampleRate * 30
            let padding = WhisperKit.sampleRate / 5
            var probe: [Float] = []
            probe.reserveCapacity(maximumSamples)

            for chunk in activeChunks {
                let start = max(0, chunk.startIndex - padding)
                let end = min(samples.count, chunk.endIndex + padding)
                guard end > start else { continue }
                let remaining = maximumSamples - probe.count
                guard remaining > 0 else { break }
                probe.append(contentsOf: samples[start..<min(end, start + remaining)])
            }

            // Very short/noisy probes are safer with WhisperKit's per-window
            // automatic detection than with a forced low-confidence language.
            guard probe.count >= WhisperKit.sampleRate else { return nil }
            let detection = try await pipeline.detectLangauge(audioArray: probe)
            let confidence = detection.langProbs[detection.language] ?? 0
            AppLog.recording(
                "语言检测完成: language=\(detection.language), confidence=\(String(format: "%.3f", confidence)), speechProbe=\(String(format: "%.1f", Double(probe.count) / Double(WhisperKit.sampleRate)))s"
            )
            return confidence >= 0.35 ? detection.language : nil
        } catch {
            AppLog.recordingError("语言检测失败，将由解码器自动判断: \(error.localizedDescription)")
            return nil
        }
    }

    /// 以 RMS 估算整段音频的平均电平（dBFS），用于空结果时判断是否因录音过轻。
    private static func averageLevelDB(_ samples: [Float]?) -> Double? {
        guard let samples, !samples.isEmpty else { return nil }
        var sumSquares: Double = 0
        for sample in samples {
            let v = Double(sample)
            sumSquares += v * v
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -Double.infinity }
        return 20.0 * (log10(rms))
    }

    private static func cleanedModelText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<\\|[^>]+\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dominantLanguage(in results: [TranscriptionResult]) -> String {
        let weights = results.reduce(into: [String: Int]()) { output, result in
            output[result.language, default: 0] += max(1, cleanedModelText(result.text).count)
        }
        return weights.max(by: { $0.value < $1.value })?.key ?? "und"
    }

    private func loadPipeline(
        onProgress: @escaping @Sendable (RecordingTranscriptionProgress) -> Void
    ) async throws -> WhisperKit {
        if let pipeline { return pipeline }

        let modelDirectory = TBOXTranscriptionModel.storageDirectory
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let modelFolder: URL
        if let installedFolder = TBOXTranscriptionModel.installedModelFolder {
            // 模型已安装：严格本地加载，不发起任何网络请求。
            // 此前这里无条件调用 WhisperKit.download()，即使模型已就绪也要联网核对
            // HuggingFace 快照；网络不可达（例如国内直连 huggingface.co）时会超时，
            // 表现为“模型加载失败”。本地 tokenizer 已缓存于
            // `<downloadBase>/models/openai/whisper-large-v3/`，无需联网。
            onProgress(
                RecordingTranscriptionProgress(
                    completedChunks: 0,
                    totalChunks: 0,
                    statusMessage: "正在加载本地高精度模型…"
                )
            )
            modelFolder = installedFolder
        } else {
            onProgress(
                RecordingTranscriptionProgress(
                    completedChunks: 0,
                    totalChunks: 0,
                    statusMessage: "首次使用：正在下载高精度模型（\(TBOXTranscriptionModel.approximateDownloadSize)）…"
                )
            )
            let progressRelay = DownloadProgressRelay()
            modelFolder = try await WhisperKit.download(
                variant: TBOXTranscriptionModel.modelName,
                downloadBase: modelDirectory,
                useBackgroundSession: false
            ) { progress in
                progressRelay.report(progress, to: onProgress)
            }
        }

        onProgress(
            RecordingTranscriptionProgress(
                completedChunks: 0,
                totalChunks: 0,
                statusMessage: "正在加载并预热本地模型…"
            )
        )
        // `modelFolder` makes this a strictly local load. Keep tokenizer assets in
        // the shared model cache root instead of writing them into the immutable
        // Core ML model directory returned by WhisperKit.download().
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: modelDirectory,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        let loaded = try await WhisperKit(config)
        pipeline = loaded
        return loaded
    }
}
#endif
