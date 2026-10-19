import Cocoa

#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif
#if canImport(SpeakerKit)
@preconcurrency import SpeakerKit
#endif

/// 应用启动时检查语音模型是否就绪；未就绪则后台预下载，完成后录音转写即可离线使用。
/// 下载期间截图、录屏、标注、OCR、翻译等功能不受影响。
final class ModelPreloader: NSObject {
    static let shared = ModelPreloader()

    private var progressWindow: NSWindow?
    private var statusLabel: NSTextField?
    private var progressIndicator: NSProgressIndicator?
    private var downloadTask: Task<Void, Never>?
    private var isFinished = false

    private var speakerModelDirectory: URL {
        TBOXTranscriptionModel.storageDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("speakerkit-coreml", isDirectory: true)
    }

    /// WhisperKit 模型是否已就绪（复用 TBOXTranscriptionModel 的检测）。
    private var whisperModelInstalled: Bool {
        TBOXTranscriptionModel.isInstalled
    }

    /// SpeakerKit 三个模型组件是否齐全。
    private var speakerModelInstalled: Bool {
        let root = speakerModelDirectory
        let required: [(dir: String, file: String)] = [
            ("speaker_segmenter/pyannote-v3/W8A16", "SpeakerSegmenter.mlmodelc"),
            ("speaker_embedder/pyannote-v3/W8A16", "SpeakerEmbedder.mlmodelc"),
            ("speaker_embedder/pyannote-v3/W8A16", "SpeakerEmbedderPreprocessor.mlmodelc"),
            ("speaker_clusterer/pyannote-v4/W32A32", "PldaProjector.mlmodelc"),
        ]
        for item in required {
            let path = root.appendingPathComponent(item.dir).appendingPathComponent(item.file)
            guard FileManager.default.fileExists(atPath: path.path) else { return false }
        }
        return true
    }

    private var allModelsInstalled: Bool {
        whisperModelInstalled && speakerModelInstalled
    }

    /// 在应用启动后异步调用。模型已就绪时静默跳过；否则弹出进度窗口并后台下载。
    func startIfNeeded() {
        guard !allModelsInstalled else {
            AppLog.recording("语音模型已就绪，无需预下载")
            return
        }
        showProgressWindow()
        downloadTask = Task { [weak self] in
            await self?.downloadModels()
        }
    }

    // MARK: - 下载

    private func downloadModels() async {
        let modelDirectory = TBOXTranscriptionModel.storageDirectory
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        // 1. WhisperKit 模型
        if !whisperModelInstalled {
            await MainActor.run {
                self.updateStatus("正在下载语音识别模型（约 626 MB）…")
            }
            do {
                _ = try await WhisperKit.download(
                    variant: TBOXTranscriptionModel.modelName,
                    downloadBase: modelDirectory,
                    useBackgroundSession: false
                ) { [weak self] progress in
                    let pct = Int((progress.fractionCompleted * 100).rounded())
                    Task { @MainActor in
                        self?.updateProgress(Double(progress.fractionCompleted))
                        self?.updateStatus("正在下载语音识别模型… \(pct)%")
                    }
                }
                AppLog.recording("WhisperKit 模型预下载完成")
            } catch {
                AppLog.recordingError("WhisperKit 模型预下载失败: \(error.localizedDescription)")
                await MainActor.run {
                    self.updateStatus("语音识别模型下载失败，录音转写功能将在首次使用时重试")
                    self.markFinished(success: false)
                }
                return
            }
        }

        // 2. SpeakerKit 模型
        if !speakerModelInstalled {
            await MainActor.run {
                self.updateProgress(0)
                self.updateStatus("正在下载说话人识别模型（约 11 MB）…")
            }
            #if canImport(SpeakerKit)
            do {
                let config = PyannoteConfig(
                    downloadBase: modelDirectory.path,
                    download: true,
                    load: false,
                    verbose: false
                )
                _ = try await SpeakerKit(config)
                AppLog.recording("SpeakerKit 模型预下载完成")
            } catch {
                AppLog.recordingError("SpeakerKit 模型预下载失败: \(error.localizedDescription)")
                // 说话人模型失败不阻断——转写仍可正常工作，只是不区分说话人
            }
            #endif
        }

        // 3. tokenizer（WhisperKit 依赖）
        await MainActor.run {
            self.updateStatus("正在准备分词器…")
        }
        do {
            let tokenizerDir = modelDirectory.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("openai", isDirectory: true)
                .appendingPathComponent("whisper-large-v3", isDirectory: true)
            try? FileManager.default.createDirectory(at: tokenizerDir, withIntermediateDirectories: true)
            // WhisperKit 在加载时会自动处理 tokenizer 下载；这里只确保目录存在
        }

        await MainActor.run {
            self.updateProgress(1.0)
            self.updateStatus("语音模型准备完成，录音转写功能已就绪")
            self.markFinished(success: true)
        }
    }

    // MARK: - 进度窗口

    private func showProgressWindow() {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 140)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "TBOX · 模型准备"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        let container = NSView(frame: frame)
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "正在准备语音模型…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = 0
        indicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(indicator)

        let hint = NSTextField(labelWithString: "下载完成后录音转写功能即可离线使用，其他功能不受影响")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)

        window.contentView = container

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            indicator.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),
            indicator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            indicator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            indicator.heightAnchor.constraint(equalToConstant: 22),

            hint.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        statusLabel = label
        progressIndicator = indicator
        progressWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func updateStatus(_ text: String) {
        guard !isFinished else { return }
        statusLabel?.stringValue = text
    }

    @MainActor
    private func updateProgress(_ fraction: Double) {
        guard !isFinished else { return }
        progressIndicator?.doubleValue = min(1, max(0, fraction))
    }

    @MainActor
    private func markFinished(success: Bool) {
        isFinished = true
        if success {
            // 2 秒后自动关闭
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.progressWindow?.orderOut(nil)
                self?.progressWindow = nil
            }
        }
        // 失败时保留窗口，让用户看到错误提示
    }
}
