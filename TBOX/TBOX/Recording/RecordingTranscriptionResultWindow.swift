import Cocoa

/// 转写完成后的可编辑逐字稿窗口。
final class RecordingTranscriptionResultWindow: NSWindow {
    private let durationLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let exportButton = NSButton()
    private let progressIndicator = NSProgressIndicator()
    private let modeControl = NSSegmentedControl(
        labels: ["逐句记录", "纯文本"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var currentText = ""
    private var currentSegments: [RecordingTranscriptionSegment] = []
    private var editedModeTexts: [Int: String] = [:]
    private var lastSelectedMode = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "录音转写"
        minSize = NSSize(width: 620, height: 430)
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setupContentView()
    }

    func present(result: RecordingTranscriptionResult) {
        title = "录音转写"
        representedURL = result.audioURL
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        textView.isEditable = true
        durationLabel.stringValue = "时长 \(Self.formatDuration(result.duration))"
        statusLabel.stringValue = result.text.isEmpty
            ? "未识别到文字内容"
            : Self.summary(for: result)
        currentText = result.text
        currentSegments = result.segments
        editedModeTexts.removeAll()
        lastSelectedMode = 0
        modeControl.selectedSegment = 0
        if result.text.isEmpty {
            textView.string = "未识别到文字内容"
            textView.textColor = NSColor.secondaryLabelColor
            textView.insertionPointColor = .clear
        } else {
            textView.insertionPointColor = NSColor.controlTextColor
            renderSelectedMode()
        }
        copyButton.isEnabled = !result.text.isEmpty
        copyButton.title = "复制文本"
        exportButton.isEnabled = !result.segments.isEmpty
        textView.scrollToBeginningOfDocument(nil)
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func presentTranscribing(audioURL: URL, duration: TimeInterval) {
        title = "录音转写"
        textView.isEditable = false
        updateProgress(RecordingTranscriptionProgress(completedChunks: 0, totalChunks: 0))
        durationLabel.stringValue = "时长 \(Self.formatDuration(duration))"
        statusLabel.stringValue = "正在识别并整理句段…"
        currentText = ""
        currentSegments = []
        editedModeTexts.removeAll()
        lastSelectedMode = 0
        modeControl.selectedSegment = 0
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: "正在转写，请稍候…",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        )
        textView.insertionPointColor = .clear
        copyButton.isEnabled = false
        copyButton.title = "复制文本"
        exportButton.isEnabled = false
        representedURL = audioURL
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func updatePartial(result: RecordingTranscriptionResult) {
        currentText = result.text
        currentSegments = result.segments
        editedModeTexts.removeAll()
        lastSelectedMode = modeControl.selectedSegment
        durationLabel.stringValue = "时长 \(Self.formatDuration(result.duration))"
        statusLabel.stringValue = "正在转写 · 已整理 \(result.segments.count) 个句段"
        textView.insertionPointColor = NSColor.controlTextColor
        copyButton.isEnabled = !result.text.isEmpty
        exportButton.isEnabled = !result.segments.isEmpty
        renderSelectedMode()
        textView.scrollToEndOfDocument(nil)
    }

    func updateProgress(_ progress: RecordingTranscriptionProgress) {
        progressIndicator.isHidden = false
        progressIndicator.isIndeterminate = progress.fraction == nil
        if let fraction = progress.fraction {
            progressIndicator.stopAnimation(nil)
            progressIndicator.doubleValue = fraction
        } else {
            progressIndicator.startAnimation(nil)
        }
        statusLabel.stringValue = progress.message
    }

    func present(error: Error, audioURL: URL?) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        textView.isEditable = true
        title = "录音转写未完成"
        durationLabel.stringValue = "录音已保存"
        statusLabel.stringValue = error.localizedDescription
        let audioPath = audioURL?.path ?? "未知"
        currentText = "未能生成文字记录。\n\n原因：\(error.localizedDescription)\n\n录音文件已安全保存：\n\(audioPath)\n\n请确认录音中包含清晰人声后重试；较长录音会自动分段识别。"
        currentSegments = []
        editedModeTexts.removeAll()
        lastSelectedMode = 1
        modeControl.selectedSegment = 1
        textView.string = currentText
        textView.textColor = NSColor.textColor
        textView.insertionPointColor = NSColor.controlTextColor
        copyButton.isEnabled = true
        copyButton.title = "复制诊断"
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func setupContentView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        root.autoresizingMask = [.width, .height]
        contentView = root

        let titleLabel = NSTextField(labelWithString: "新录音")
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.frame = NSRect(x: 28, y: 548, width: 500, height: 30)
        titleLabel.autoresizingMask = [.minYMargin, .maxXMargin]
        root.addSubview(titleLabel)

        durationLabel.font = NSFont.systemFont(ofSize: 13)
        durationLabel.textColor = NSColor.secondaryLabelColor
        durationLabel.frame = NSRect(x: 28, y: 522, width: 240, height: 20)
        durationLabel.autoresizingMask = [.minYMargin, .maxXMargin]
        root.addSubview(durationLabel)

        modeControl.frame = NSRect(x: 28, y: 480, width: 220, height: 28)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.autoresizingMask = [.minYMargin, .maxXMargin]
        root.addSubview(modeControl)

        let scroll = NSScrollView(frame: NSRect(x: 28, y: 74, width: 764, height: 390))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor
        // NSTextView() 的初始 frame 是 0×0。只设置为 documentView 不会自动
        // 获得可绘制尺寸，这正是“复制有文本但窗口空白”的原因。
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = true
        textView.allowsUndo = true
        scroll.documentView = textView
        root.addSubview(scroll)

        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.frame = NSRect(x: 28, y: 58, width: 764, height: 8)
        progressIndicator.autoresizingMask = [.width, .maxYMargin]
        progressIndicator.isHidden = true
        root.addSubview(progressIndicator)

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // Keep the status message in the space between the action buttons.
        // Width is flexible so the layout remains usable when the window is
        // resized down to its minimum size.
        statusLabel.frame = NSRect(x: 168, y: 31, width: 360, height: 20)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(statusLabel)

        let closeButton = NSButton()
        closeButton.bezelStyle = .rounded
        closeButton.title = "× 关闭窗口"
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.frame = NSRect(x: 28, y: 24, width: 122, height: 30)
        closeButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        root.addSubview(closeButton)

        exportButton.bezelStyle = .rounded
        exportButton.title = "导出文稿"
        exportButton.target = self
        exportButton.action = #selector(exportTranscript)
        exportButton.frame = NSRect(x: 540, y: 24, width: 122, height: 30)
        exportButton.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(exportButton)

        copyButton.bezelStyle = .rounded
        copyButton.title = "复制文本"
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.frame = NSRect(x: 670, y: 24, width: 122, height: 30)
        copyButton.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(copyButton)
    }

    /// 导出当前句段为 txt / srt / md。导出内容始终来自句段数据（含说话人和
    /// 时间戳），与当前视图模式无关；无句段时按钮不可用。
    @objc private func exportTranscript() {
        guard !currentSegments.isEmpty, let audioURL = representedURL else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (audioURL.deletingPathExtension().lastPathComponent as NSString).appending(".txt")

        let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        for format in TranscriptFormatter.Format.allCases {
            formatPopup.addItem(withTitle: format.displayName)
        }
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let formatLabel = NSTextField(labelWithString: "格式：")
        formatLabel.frame = NSRect(x: 0, y: 5, width: 44, height: 20)
        formatPopup.frame = NSRect(x: 46, y: 2, width: 190, height: 26)
        accessory.addSubview(formatLabel)
        accessory.addSubview(formatPopup)
        panel.accessoryView = accessory

        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let self else { return }
            let format = TranscriptFormatter.Format.allCases[formatPopup.indexOfSelectedItem]
            let content = TranscriptFormatter.format(self.currentSegments, as: format)
            guard let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                self.statusLabel.stringValue = "已导出：\(url.lastPathComponent)"
            } catch {
                self.statusLabel.stringValue = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string.isEmpty ? currentText : textView.string, forType: .string)
        statusLabel.stringValue = "已复制到剪贴板"
    }

    @objc private func modeChanged() {
        guard !currentText.isEmpty else { return }
        editedModeTexts[lastSelectedMode] = textView.string
        lastSelectedMode = modeControl.selectedSegment
        if let editedText = editedModeTexts[lastSelectedMode] {
            renderPlainText(editedText)
        } else {
            renderSelectedMode()
        }
        textView.scrollToBeginningOfDocument(nil)
    }

    @objc private func closeWindow() {
        orderOut(nil)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        if seconds >= 3600 { return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// 汇总状态行；句段出现估算时间时明确提示，避免用户把估算时间当作真实时间。
    private static func summary(for result: RecordingTranscriptionResult) -> String {
        let estimated = result.segments.contains(where: \.isEstimated)
        let base = "\(result.engine.displayName)识别 · 已整理为 \(result.segments.count) 个句段，可直接编辑"
        return estimated ? base + "（部分时间戳为估算值）" : base
    }

    private static func formatTimestamp(_ timestamp: TimeInterval) -> String {
        let seconds = max(0, Int(timestamp.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func renderSelectedMode() {
        if modeControl.selectedSegment == 1 || currentSegments.isEmpty {
            renderPlainText(currentText)
            return
        }

        let transcript = NSMutableAttributedString()
        let headerParagraph = NSMutableParagraphStyle()
        headerParagraph.paragraphSpacing = 6
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 5
        bodyParagraph.paragraphSpacing = 18

        for segment in currentSegments {
            let header = segment.isEstimated
                ? "\(segment.speakerName)  ·  ~\(Self.formatTimestamp(segment.start))  ·  时间估算\n"
                : "\(segment.speakerName)  ·  \(Self.formatTimestamp(segment.start))\n"
            transcript.append(
                NSAttributedString(
                    string: header,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: headerParagraph,
                    ]
                )
            )
            transcript.append(
                NSAttributedString(
                    string: segment.text + "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 17),
                        .foregroundColor: NSColor.textColor,
                        .paragraphStyle: bodyParagraph,
                    ]
                )
            )
        }
        textView.textStorage?.setAttributedString(transcript)
    }

    private func renderPlainText(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 10
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )
    }
}
