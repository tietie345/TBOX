import Cocoa
import UniformTypeIdentifiers

private final class PinImageView: NSImageView {
    var onZoom: ((CGFloat) -> Void)?
    var onEdit: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 4
        onZoom?(exp(delta * 0.025))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onEdit?()
            return
        }

        // 图片视图覆盖了整个无边框窗口，依赖 isMovableByWindowBackground
        // 无法收到拖动；由图片视图明确发起系统窗口拖动。
        NSCursor.closedHand.push()
        window?.performDrag(with: event)
        NSCursor.pop()
    }
}

class PinWindow: NSPanel {
    private var cgImage: CGImage
    private let imageView: PinImageView
    private let baseWindowSize: NSSize
    private var zoomScale: CGFloat = 1

    var onClose: (() -> Void)?
    var onEdit: ((PinWindow, CGImage) -> Void)?

    init(image: CGImage) {
        cgImage = image

        let maxInitialSize = NSSize(width: 720, height: 520)
        let imageSize = NSSize(width: image.width, height: image.height)
        let scale = min(1, maxInitialSize.width / imageSize.width, maxInitialSize.height / imageSize.height)
        baseWindowSize = NSSize(
            width: max(80, imageSize.width * scale),
            height: max(60, imageSize.height * scale)
        )
        imageView = PinImageView(frame: NSRect(origin: .zero, size: baseWindowSize))

        super.init(
            contentRect: NSRect(origin: .zero, size: baseWindowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false

        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.menu = makeContextMenu()
        imageView.onZoom = { [weak self] factor in self?.zoom(by: factor) }
        imageView.onEdit = { [weak self] in self?.beginEditing() }
        contentView = imageView
        updateImage(image)
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { true }

    func showNearMouse() {
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height / 2)
        setFrameOrigin(constrainedOrigin(origin, size: frame.size))
        orderFrontRegardless()
        makeKey()
    }

    func updateImage(_ image: CGImage) {
        cgImage = image
        imageView.image = NSImage(cgImage: image, size: imageView.bounds.size)
        imageView.needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "重新标注…", action: #selector(editImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "复制", action: #selector(copyImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "保存…", action: #selector(saveImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "关闭", action: #selector(closePin), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    private func zoom(by factor: CGFloat) {
        let nextScale = min(4, max(0.2, zoomScale * factor))
        guard abs(nextScale - zoomScale) > 0.001 else { return }
        zoomScale = nextScale

        let oldFrame = frame
        var newSize = NSSize(
            width: max(48, baseWindowSize.width * zoomScale),
            height: max(36, baseWindowSize.height * zoomScale)
        )
        if let screen = screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let fit = min(1, visible.width / newSize.width, visible.height / newSize.height)
            newSize.width *= fit
            newSize.height *= fit
        }
        let centeredOrigin = NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.midY - newSize.height / 2
        )
        setFrame(
            NSRect(origin: constrainedOrigin(centeredOrigin, size: newSize), size: newSize),
            display: true,
            animate: false
        )
    }

    private func beginEditing() {
        onEdit?(self, cgImage)
    }

    @objc private func editImage() { beginEditing() }

    @objc private func copyImage() {
        ClipboardManager.copyImage(cgImage)
    }

    @objc private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "贴图_\(Int(Date().timeIntervalSince1970)).png"
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            ClipboardManager.saveImage(self.cgImage, to: url)
        }
    }

    @objc private func closePin() { close() }

    private func constrainedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)) })
            ?? NSScreen.main else { return origin }
        let visible = screen.visibleFrame
        return NSPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        )
    }
}

/// 图钉的独立标注窗口。完成后将合成结果回写原图钉，取消则保留原图。
final class PinEditorWindow: NSWindow {
    private let sourceImage: CGImage
    private let canvas: AnnotationCanvas
    private var didNotifyClose = false

    var onDone: ((CGImage) -> Void)?
    var onClose: (() -> Void)?

    init(image: CGImage) {
        sourceImage = image

        let maxCanvas = NSSize(width: 980, height: 680)
        let imageSize = NSSize(width: image.width, height: image.height)
        let imageScale = min(1, maxCanvas.width / imageSize.width, maxCanvas.height / imageSize.height)
        let canvasSize = NSSize(
            width: imageSize.width * imageScale,
            height: imageSize.height * imageScale
        )
        canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: canvasSize))

        let toolbar = AnnotationToolbarView()
        let toolbarSize = toolbar.calcFittingSize()
        let contentSize = NSSize(
            width: max(canvasSize.width, toolbarSize.width) + 24,
            height: canvasSize.height + toolbarSize.height + 36
        )

        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        title = "重新标注贴图"
        isReleasedWhenClosed = false
        center()

        let root = NSView(frame: NSRect(origin: .zero, size: contentSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let canvasOrigin = NSPoint(
            x: (contentSize.width - canvasSize.width) / 2,
            y: toolbarSize.height + 24
        )
        let imageView = NSImageView(frame: NSRect(origin: canvasOrigin, size: canvasSize))
        imageView.image = NSImage(cgImage: image, size: canvasSize)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        root.addSubview(imageView)

        canvas.frame.origin = canvasOrigin
        canvas.sourceImage = image
        root.addSubview(canvas)

        toolbar.frame = NSRect(
            x: (contentSize.width - toolbarSize.width) / 2,
            y: 10,
            width: toolbarSize.width,
            height: toolbarSize.height
        )
        toolbar.layoutButtons()
        root.addSubview(toolbar)
        contentView = root

        toolbar.onToolChange = { [weak canvas] tool in canvas?.activateTool(tool) }
        toolbar.onColorChange = { [weak canvas] color in canvas?.currentColor = color }
        toolbar.onLineWidthChange = { [weak canvas] width in canvas?.currentLineWidth = width }
        toolbar.onUndo = { [weak canvas] in canvas?.undo() }
        toolbar.onRedo = { [weak canvas] in canvas?.redo() }
        toolbar.onSave = { [weak self] in self?.saveComposite() }
        toolbar.onDone = { [weak self] in self?.finishEditing() }
        toolbar.onCancel = { [weak self] in self?.close() }
        canvas.onSave = { [weak self] in self?.saveComposite() }
        canvas.onDone = { [weak self] in self?.finishEditing() }
        canvas.onCancel = { [weak self] in self?.close() }
        canvas.activateTool(.rect)
    }

    required init?(coder: NSCoder) { nil }

    func showEditor() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(canvas)
    }

    override func close() {
        super.close()
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose?()
        onClose = nil
    }

    private func finishEditing() {
        guard let image = canvas.renderedComposite(with: sourceImage) else { return }
        onDone?(image)
        close()
    }

    private func saveComposite() {
        guard let image = canvas.renderedComposite(with: sourceImage) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "标注贴图_\(Int(Date().timeIntervalSince1970)).png"
        panel.beginSheetModal(for: self) { response in
            guard response == .OK, let url = panel.url else { return }
            ClipboardManager.saveImage(image, to: url)
        }
    }
}
