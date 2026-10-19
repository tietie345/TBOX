import Cocoa

final class TextResultPanel: NSView {
    private let titleLabel = NSTextField(labelWithString: "提取文字")
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let sourceLabel = NSTextField(labelWithString: "原文")
    private let sourceScrollView = NSScrollView()
    private let sourceTextView = NSTextView()
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let retryButton = NSButton(frame: .zero)
    private let closeButton = NSButton(frame: .zero)
    private let progress = NSProgressIndicator()

    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?
    private(set) var displayedText = ""
    private var isTranslationLayout = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 10
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -3)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        sourceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor

        sourceTextView.isEditable = false
        sourceTextView.isSelectable = true
        sourceTextView.font = .systemFont(ofSize: 12)
        sourceTextView.textColor = .secondaryLabelColor
        sourceTextView.backgroundColor = .textBackgroundColor
        sourceTextView.textContainerInset = NSSize(width: 8, height: 6)
        sourceTextView.isVerticallyResizable = true
        sourceTextView.isHorizontallyResizable = false
        sourceTextView.autoresizingMask = [.width]
        sourceTextView.textContainer?.widthTracksTextView = true
        sourceScrollView.documentView = sourceTextView
        sourceScrollView.hasVerticalScroller = true
        sourceScrollView.autohidesScrollers = true
        sourceScrollView.borderType = .bezelBorder
        sourceLabel.isHidden = true
        sourceScrollView.isHidden = true

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.toolTip = "复制结果"

        retryButton.bezelStyle = .inline
        retryButton.isBordered = false
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重试翻译")
        retryButton.contentTintColor = .secondaryLabelColor
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.toolTip = "重试翻译"
        retryButton.isHidden = true

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭结果")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.toolTip = "关闭结果"

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        [titleLabel, statusLabel, sourceLabel, sourceScrollView, scrollView, copyButton, retryButton, closeButton, progress].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showLoading(title: String, message: String) {
        isTranslationLayout = false
        sourceLabel.isHidden = true
        sourceScrollView.isHidden = true
        retryButton.isHidden = true
        copyButton.title = "复制"
        titleLabel.stringValue = title
        statusLabel.stringValue = message
        displayedText = ""
        textView.string = ""
        copyButton.isEnabled = false
        progress.startAnimation(nil)
        isHidden = false
    }

    func showResult(title: String, text: String, status: String = "可选择文字，或一键复制") {
        isTranslationLayout = false
        sourceLabel.isHidden = true
        sourceScrollView.isHidden = true
        retryButton.isHidden = true
        copyButton.title = "复制"
        titleLabel.stringValue = title
        statusLabel.stringValue = status
        displayedText = text
        textView.string = text
        copyButton.isEnabled = !text.isEmpty
        progress.stopAnimation(nil)
        isHidden = false
    }

    func showError(title: String, message: String) {
        isTranslationLayout = false
        sourceLabel.isHidden = true
        sourceScrollView.isHidden = true
        retryButton.isHidden = true
        copyButton.title = "复制"
        titleLabel.stringValue = title
        statusLabel.stringValue = "处理失败"
        displayedText = ""
        textView.string = message
        copyButton.isEnabled = false
        progress.stopAnimation(nil)
        isHidden = false
    }

    func showTranslationLoading(direction: String, source: String, message: String) {
        // 原文只作为翻译输入保留，不在结果面板重复展示；译文区域使用完整高度。
        isTranslationLayout = false
        titleLabel.stringValue = direction
        statusLabel.stringValue = message
        sourceLabel.stringValue = "原文"
        sourceTextView.string = source
        sourceLabel.isHidden = true
        sourceScrollView.isHidden = true
        displayedText = ""
        textView.string = "等待翻译结果…"
        textView.textColor = .secondaryLabelColor
        copyButton.title = "复制译文"
        copyButton.isEnabled = false
        retryButton.isHidden = true
        progress.startAnimation(nil)
        isHidden = false
        needsLayout = true
    }

    func updateTranslationStatus(_ message: String) {
        statusLabel.stringValue = message
    }

    func showTranslationResult(direction: String, source: String, translation: String) {
        showTranslationLoading(direction: direction, source: source, message: "翻译完成")
        displayedText = translation
        textView.string = translation
        textView.textColor = .textColor
        copyButton.isEnabled = !translation.isEmpty
        progress.stopAnimation(nil)
    }

    func showTranslationError(direction: String, source: String, message: String) {
        showTranslationLoading(direction: direction, source: source, message: "翻译失败")
        textView.string = message
        textView.textColor = .systemRed
        retryButton.isHidden = false
        progress.stopAnimation(nil)
    }

    @objc private func copyText() {
        guard !displayedText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayedText, forType: .string)
        statusLabel.stringValue = "已复制到剪贴板"
    }

    @objc private func closePanel() {
        isHidden = true
        onClose?()
    }

    @objc private func retry() {
        onRetry?()
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let headerY = bounds.height - 31
        closeButton.frame = NSRect(x: bounds.width - 32, y: headerY, width: 24, height: 24)
        titleLabel.frame = NSRect(x: inset, y: headerY + 3, width: bounds.width - 76, height: 18)
        progress.frame = NSRect(x: bounds.width - 54, y: headerY + 5, width: 16, height: 16)
        statusLabel.frame = NSRect(x: inset, y: 10, width: bounds.width - 122, height: 18)
        copyButton.frame = NSRect(x: bounds.width - 74, y: 7, width: 62, height: 24)
        retryButton.frame = NSRect(x: bounds.width - 100, y: 7, width: 24, height: 24)

        if isTranslationLayout {
            let contentHeight = bounds.height - 82
            let sourceHeight = max(58, contentHeight * 0.42)
            sourceLabel.frame = NSRect(x: inset, y: bounds.height - 51, width: 60, height: 15)
            sourceScrollView.frame = NSRect(
                x: inset, y: bounds.height - 56 - sourceHeight,
                width: bounds.width - inset * 2, height: sourceHeight
            )
            scrollView.frame = NSRect(
                x: inset, y: 38,
                width: bounds.width - inset * 2,
                height: max(52, bounds.height - 102 - sourceHeight)
            )
        } else {
            scrollView.frame = NSRect(x: inset, y: 38, width: bounds.width - inset * 2, height: bounds.height - 76)
        }
    }
}
