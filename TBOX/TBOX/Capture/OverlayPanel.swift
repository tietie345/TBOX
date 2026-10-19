import Cocoa

// MARK: - OverlayWindow（全屏遮罩窗口）

/// 使用 NSWindow（非 NSPanel）+ CGShieldingWindowLevel 是 macOS 截图工具的标准方案
class OverlayPanel: NSWindow {
    var overlayView: OverlayView!

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // CGShieldingWindowLevel: 高于 screen saver 的窗口级别，专为截屏设计
        self.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.isReleasedWhenClosed = false
        self.alphaValue = 0
        self.acceptsMouseMovedEvents = true

        overlayView = OverlayView(frame: contentView!.bounds, screen: screen)
        self.contentView = overlayView
    }

    /// 截图完成后调用，显示遮罩并启用交互
    func showOverlay() {
        self.ignoresMouseEvents = false
        self.alphaValue = 1
        self.orderFrontRegardless()
        self.makeFirstResponder(overlayView)
        self.makeKey()
        overlayView.needsDisplay = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 在 window 层级拦截所有鼠标事件，确保鼠标移动时始终更新光标和 tooltip。
    /// 这样即使鼠标在子视图（按钮）上，OverlayView 也能收到 mouseMoved。
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .mouseMoved {
            overlayView.handleMouseMoved(event)
        }
    }
}

// MARK: - OverlayView（主视图：遮罩 + 框选 + 控制点 + 放大镜）

class OverlayView: NSView {
    private(set) var screenshotImage: NSImage?
    private var startPoint: NSPoint = .zero
    private(set) var selectionRect: NSRect = .zero
    private var isDragging = false
    private(set) var hasSelection = false
    private var mouseLocation: NSPoint = .zero

    var onCapture: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAnnotated: ((CGImage) -> Void)?
    var onPin: ((NSRect) -> Void)?
    var onRecord: ((NSRect) -> Void)?
    var onTranscribe: (() -> Void)?
    /// 标注完成后，传合成图片（截图+标注）直接复制
    var onCaptureAnnotated: ((CGImage) -> Void)?

    private var infoBar: SelectionInfoBar!
    private var toolbar: CaptureToolbar!
    private var textResultPanel: TextResultPanel!
    private var translationBridge: NSView?
    private var textOperationGeneration = 0
    private var translationTimeoutWorkItem: DispatchWorkItem?
    private var lastTranslationSource: String?

    // 标注模式
    private var isAnnotationMode = false
    private var annotationCanvas: AnnotationCanvas!
    private var annotationToolbar: AnnotationToolbarView!

    var outputCornerRadius: CGFloat { infoBar.cornerRadius }
    var outputHasShadow: Bool { infoBar.hasShadow }

    // 自定义 tooltip（系统 tooltip 在 CGShieldingWindowLevel 下不显示）
    private var tooltipTimer: Timer?
    private var currentTooltipText: String?
    private var tooltipBubble: HoverTooltipView!
    private var directHoverText: String?

    // 控制点拖拽 + 整体移动
    private enum Handle {
        case none
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case move
    }
    private var draggingHandle: Handle = .none
    private var handleAnchor: NSPoint = .zero   // 拖拽锚点（对角不动点）
    private var moveOffset: NSPoint = .zero      // 整体移动时的鼠标偏移
    private let handleSize: CGFloat = 12
    private let edgeHitWidth: CGFloat = 6         // 边缘命中宽度

    // 窗口智能识别
    private struct WindowInfo {
        let bounds: NSRect
        let appName: String
        let windowName: String
    }
    private var visibleWindows: [WindowInfo] = []
    private var highlightedWindowIndex: Int = -1
    private var pendingWindowIndex: Int = -1
    private var didDragSelection = false
    private let minimumSelectionSize: CGFloat = 2
    private var isHoveringWindow: Bool { highlightedWindowIndex >= 0 }

    init(frame frameRect: NSRect, screen: NSScreen) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.isOpaque = false
        setupSubViews()
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupSubViews() {
        infoBar = SelectionInfoBar()
        infoBar.isHidden = true
        addSubview(infoBar)

        toolbar = CaptureToolbar()
        toolbar.isHidden = true
        toolbar.onCopy = { [weak self] in
            guard let self = self, self.hasSelection else { return }
            self.onCapture?(self.selectionRect)
        }
        toolbar.onCancel = { [weak self] in
            self?.onCancel?()
        }
        toolbar.onSave = { [weak self] in
            self?.onSave?()
        }
        toolbar.onAnnotate = { [weak self] tool in
            self?.enterAnnotationMode(initialTool: tool)
        }
        toolbar.onPin = { [weak self] in
            guard let self, self.hasSelection else { return }
            self.onPin?(self.selectionRect)
        }
        toolbar.onRecord = { [weak self] in
            guard let self, self.hasSelection else { return }
            self.onRecord?(self.selectionRect)
        }
        toolbar.onTranscribe = { [weak self] in
            self?.onTranscribe?()
        }
        toolbar.onExtractText = { [weak self] in
            self?.extractSelectedText()
        }
        toolbar.onTranslate = { [weak self] in
            self?.translateSelectedText()
        }
        toolbar.onHover = { [weak self] text, event in
            self?.handleToolbarHover(text: text, event: event)
        }
        addSubview(toolbar)

        textResultPanel = TextResultPanel()
        textResultPanel.isHidden = true
        textResultPanel.onClose = { [weak self] in
            self?.textOperationGeneration += 1
        }
        textResultPanel.onRetry = { [weak self] in
            self?.retryTranslation()
        }
        addSubview(textResultPanel)

        if #available(macOS 15.0, *) {
            let bridge = TranslationBridgeHost(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            translationBridge = bridge
            addSubview(bridge)
        }

        // 标注工具栏
        annotationToolbar = AnnotationToolbarView()
        annotationToolbar.isHidden = true
        annotationToolbar.onToolChange = { [weak self] tool in
            self?.annotationCanvas?.activateTool(tool)
        }
        annotationToolbar.onColorChange = { [weak self] color in
            self?.annotationCanvas.currentColor = color
        }
        annotationToolbar.onLineWidthChange = { [weak self] w in
            self?.annotationCanvas.currentLineWidth = w
        }
        annotationToolbar.onUndo = { [weak self] in
            self?.annotationCanvas.undo()
        }
        annotationToolbar.onRedo = { [weak self] in
            self?.annotationCanvas.redo()
        }
        annotationToolbar.onDone = { [weak self] in
            self?.exitAnnotationMode()
        }
        annotationToolbar.onSave = { [weak self] in
            self?.saveAnnotatedImage()
        }
        annotationToolbar.onCancel = { [weak self] in
            self?.cancelAnnotationMode()
        }
        addSubview(annotationToolbar)

        // 必须作为最上层独立子视图显示。若在 OverlayView.draw 内绘制，之后绘制的工具栏
        // 子视图会把提示覆盖掉，尤其是提示位于按钮附近时。
        tooltipBubble = HoverTooltipView()
        tooltipBubble.isHidden = true
        addSubview(tooltipBubble, positioned: .above, relativeTo: nil)
    }

    func setScreenshot(_ cgImage: CGImage) {
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        self.screenshotImage = NSImage(cgImage: cgImage, size: size)
        print("[TBOX] setScreenshot: \(cgImage.width)x\(cgImage.height), view bounds: \(bounds.size)")
        self.needsDisplay = true
        visibleWindows.removeAll(keepingCapacity: true)
        highlightedWindowIndex = -1
        // 窗口智能识别不影响手动框选，先让遮罩完成首帧绘制，再补充窗口列表。
        // 避免 CGWindowListCopyWindowInfo 阻塞热键到遮罩出现的关键路径。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.refreshWindows()
        }
    }

    // MARK: - 标注模式

    private func enterAnnotationMode(initialTool: AnnotationToolType = .rect) {
        guard hasSelection else { return }
        resetTextResult()
        isAnnotationMode = true

        // 创建透明标注层，底下保留选区截图
        let canvasFrame = NSRect(origin: .zero, size: selectionRect.size)
        annotationCanvas = AnnotationCanvas(frame: canvasFrame)
        annotationCanvas.sourceImage = selectedScreenshotImage()
        annotationCanvas.frame.origin = selectionRect.origin
        annotationCanvas.wantsLayer = true
        annotationCanvas.layer?.cornerRadius = 0
        annotationCanvas.onDone = { [weak self] in self?.exitAnnotationMode() }
        annotationCanvas.onSave = { [weak self] in self?.saveAnnotatedImage() }
        annotationCanvas.onCancel = { [weak self] in self?.cancelAnnotationMode() }
        addSubview(annotationCanvas)
        annotationCanvas.activateTool(initialTool)

        // 更新工具栏状态
        annotationToolbar.currentTool = annotationCanvas.currentTool
        annotationToolbar.currentColor = annotationCanvas.currentColor
        annotationToolbar.currentLineWidth = annotationCanvas.currentLineWidth

        // 隐藏截图工具栏，显示标注工具栏
        updateFloatingElements()
        needsDisplay = true

        DispatchQueue.main.async { [weak self] in
            guard let self, let canvas = self.annotationCanvas else { return }
            canvas.activateTool(initialTool)
        }
    }

    private func exitAnnotationMode() {
        // 合成标注到截图
        if let canvas = annotationCanvas, let screenshot = screenshotImage {
            canvas.commitPendingEdits()
            let composited = renderAnnotatedImage(canvas: canvas, screenshot: screenshot)
            isAnnotationMode = false
            annotationCanvas?.removeFromSuperview()
            annotationCanvas = nil
            updateFloatingElements()
            needsDisplay = true
            // 优先用合成图回调，否则回退到普通选区复制
            if let composited = composited, let cb = onCaptureAnnotated {
                cb(composited)
            } else {
                onCapture?(selectionRect)
            }
            return
        }

        isAnnotationMode = false
        annotationCanvas?.removeFromSuperview()
        annotationCanvas = nil
        updateFloatingElements()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    private func cancelAnnotationMode() {
        isAnnotationMode = false
        annotationCanvas?.removeFromSuperview()
        annotationCanvas = nil
        updateFloatingElements()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    private func saveAnnotatedImage() {
        guard let canvas = annotationCanvas,
              let screenshot = screenshotImage else { return }
        canvas.commitPendingEdits()
        guard let image = renderAnnotatedImage(canvas: canvas, screenshot: screenshot) else { return }
        onSaveAnnotated?(image)
    }

    private func selectedScreenshotImage() -> CGImage? {
        guard let screenshot = screenshotImage,
              let fullCG = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scaleX = CGFloat(fullCG.width) / bounds.width
        let scaleY = CGFloat(fullCG.height) / bounds.height
        let rect = CGRect(
            x: selectionRect.minX * scaleX,
            y: CGFloat(fullCG.height) - selectionRect.maxY * scaleY,
            width: selectionRect.width * scaleX,
            height: selectionRect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: fullCG.width, height: fullCG.height))
        guard !rect.isNull else { return nil }
        return fullCG.cropping(to: rect)
    }

    // MARK: - 文字识别与翻译

    private func extractSelectedText() {
        recognizeSelectedText(title: "提取文字") { [weak self] text, generation in
            guard let self, generation == self.textOperationGeneration else { return }
            self.textResultPanel.showResult(title: "提取结果", text: text)
            self.layoutTextResultPanel()
        }
    }

    private func translateSelectedText() {
        recognizeSelectedText(title: "翻译") { [weak self] text, generation in
            guard let self, generation == self.textOperationGeneration else { return }
            self.lastTranslationSource = text
            self.startTranslation(text, generation: generation)
        }
    }

    private func retryTranslation() {
        guard let text = lastTranslationSource else {
            translateSelectedText()
            return
        }
        textOperationGeneration += 1
        startTranslation(text, generation: textOperationGeneration)
    }

    private func startTranslation(_ text: String, generation: Int) {
        let direction = TranslationDirection.detect(from: text)
        guard #available(macOS 15.0, *),
              let bridge = translationBridge as? TranslationBridgeHost else {
            textResultPanel.showTranslationError(
                direction: direction.displayName,
                source: text,
                message: "系统翻译需要 macOS 15 或更高版本。提取文字仍可正常使用。"
            )
            return
        }

        translationTimeoutWorkItem?.cancel()
        textResultPanel.showTranslationLoading(
            direction: direction.displayName,
            source: text,
            message: "文字识别完成，正在检查翻译语言包…"
        )
        layoutTextResultPanel()

        let timeout = DispatchWorkItem { [weak self, weak bridge] in
            guard let self, generation == self.textOperationGeneration else { return }
            bridge?.cancelPending()
            self.textResultPanel.showTranslationError(
                direction: direction.displayName,
                source: text,
                message: "翻译准备时间过长。请检查网络和系统语言包提示，然后点击重试。"
            )
        }
        translationTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)

        bridge.translate(text, direction: direction) { [weak self] status in
            guard let self, generation == self.textOperationGeneration else { return }
            self.textResultPanel.updateTranslationStatus(status)
        } completion: { [weak self] result in
            guard let self, generation == self.textOperationGeneration else { return }
            self.translationTimeoutWorkItem?.cancel()
            switch result {
            case .success(let translated):
                self.textResultPanel.showTranslationResult(
                    direction: direction.displayName,
                    source: text,
                    translation: translated
                )
            case .failure(let error):
                AppLog.error("翻译失败: \(error.localizedDescription)")
                self.textResultPanel.showTranslationError(
                    direction: direction.displayName,
                    source: text,
                    message: self.translationErrorMessage(error)
                )
            }
            self.layoutTextResultPanel()
        }
    }

    private func translationErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("language") ||
            message.localizedCaseInsensitiveContains("asset") ||
            message.localizedCaseInsensitiveContains("download") {
            return "中英文语言包尚未就绪。请确认网络可用后点击重试，首次使用时留意系统下载提示。"
        }
        return message.isEmpty ? "翻译暂时不可用，请稍后点击重试。" : message
    }

    private func recognizeSelectedText(
        title: String,
        completion: @escaping (String, Int) -> Void
    ) {
        guard let image = selectedScreenshotImage() else {
            textResultPanel.showError(title: title, message: "无法读取框选区域")
            return
        }

        textOperationGeneration += 1
        let generation = textOperationGeneration
        textResultPanel.showLoading(title: title, message: "正在识别框选区域…")
        layoutTextResultPanel()

        TextRecognitionService.shared.recognizeText(in: image) { [weak self] result in
            guard let self, generation == self.textOperationGeneration else { return }
            switch result {
            case .success(let text):
                completion(text, generation)
            case .failure(let error):
                self.textResultPanel.showError(title: title, message: error.localizedDescription)
                self.layoutTextResultPanel()
            }
        }
    }

    private func resetTextResult() {
        translationTimeoutWorkItem?.cancel()
        if #available(macOS 15.0, *), let bridge = translationBridge as? TranslationBridgeHost {
            bridge.cancelPending()
        }
        textOperationGeneration += 1
        lastTranslationSource = nil
        textResultPanel.isHidden = true
    }

    /// 把标注元素合成到选区截图上，返回合成后的 CGImage
    private func renderAnnotatedImage(canvas: AnnotationCanvas, screenshot: NSImage) -> CGImage? {
        // 从全屏截图中裁剪选区
        guard let fullCG = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scaleX = CGFloat(fullCG.width) / bounds.width
        let scaleY = CGFloat(fullCG.height) / bounds.height
        let w = Int((selectionRect.width * scaleX).rounded())
        let h = Int((selectionRect.height * scaleY).rounded())
        guard w > 0 && h > 0 else { return nil }
        let cropRect = CGRect(
            x: selectionRect.origin.x * scaleX,
            y: CGFloat(fullCG.height) - (selectionRect.origin.y + selectionRect.height) * scaleY,
            width: CGFloat(w),
            height: CGFloat(h)
        ).integral.intersection(CGRect(x: 0, y: 0, width: fullCG.width, height: fullCG.height))
        guard !cropRect.isNull else { return nil }
        guard let cropped = fullCG.cropping(to: cropRect) else { return nil }

        // 创建位图上下文，先画截图，再画标注
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 画截图
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 画标注元素（坐标从画布本地坐标缩放到像素坐标）
        ctx.saveGState()
        ctx.scaleBy(x: scaleX, y: scaleY)
        // 翻转 Y 轴：NSView 原点在左下，CGContext 原点在左下，但画布的坐标和选区坐标一致
        for el in canvas.elements {
            drawAnnotationElement(ctx: ctx, el: el)
        }
        ctx.restoreGState()

        guard let composited = ctx.makeImage() else { return nil }
        return ImageProcessing.applyStyle(
            to: composited,
            cornerRadiusPoints: infoBar.cornerRadius,
            hasShadow: infoBar.hasShadow,
            scale: max(scaleX, scaleY)
        )
    }

    /// 在 CGContext 中绘制单个标注元素
    private func drawAnnotationElement(ctx: CGContext, el: AnnotationElement) {
        ctx.saveGState()

        switch el.type {
        case .rect, .highlight:
            let isHighlight = el.type == .highlight
            let fill = isHighlight ? el.strokeColor.withAlphaComponent(0.25) : NSColor.clear
            ctx.setFillColor(fill.cgColor)
            ctx.setStrokeColor(el.strokeColor.cgColor)
            ctx.setLineWidth(el.lineWidth)
            ctx.fill(el.rect)
            ctx.stroke(el.rect)
        case .arrow:
            let from = el.path.first ?? el.rect.origin
            let tip = el.path.dropFirst().first ?? NSPoint(x: el.rect.maxX, y: el.rect.maxY)
            ctx.setStrokeColor(el.strokeColor.cgColor)
            ctx.setLineWidth(el.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: from)
            ctx.addLine(to: tip)
            let angle = atan2(tip.y - from.y, tip.x - from.x)
            let arrowLen: CGFloat = 12
            let arrowAngle: CGFloat = .pi / 6
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(
                x: tip.x - arrowLen * cos(angle - arrowAngle),
                y: tip.y - arrowLen * sin(angle - arrowAngle)
            ))
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(
                x: tip.x - arrowLen * cos(angle + arrowAngle),
                y: tip.y - arrowLen * sin(angle + arrowAngle)
            ))
            ctx.strokePath()
        case .pen:
            guard el.path.count >= 2 else { break }
            ctx.setStrokeColor(el.strokeColor.cgColor)
            ctx.setLineWidth(el.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: el.path[0])
            for pt in el.path.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.strokePath()
        case .text, .number:
            // 文字需要用 Cocoa 绘制，在位图上下文中翻转坐标
            ctx.restoreGState()
            let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            if el.type == .number {
                let r = min(el.rect.width, el.rect.height) / 2
                let center = NSPoint(x: el.rect.midX, y: el.rect.midY)
                el.strokeColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: el.fontSize),
                    .foregroundColor: NSColor.white,
                ]
                let size = el.text.size(withAttributes: attrs)
                el.text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
            } else {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: el.fontSize),
                    .foregroundColor: el.strokeColor,
                    .paragraphStyle: paragraph,
                ]
                (el.text as NSString).draw(
                    with: el.rect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attrs,
                    context: nil
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        case .mosaic:
            drawProcessedRegion(ctx: ctx, element: el, kind: .mosaic)
        case .blur:
            drawProcessedRegion(ctx: ctx, element: el, kind: .blur)
        }

        ctx.restoreGState()
    }

    private func drawProcessedRegion(ctx: CGContext, element: AnnotationElement, kind: ImageEffectKind) {
        guard let source = annotationCanvas?.sourceImage,
              let effected = ImageProcessing.effectRegion(
                  from: source,
                  logicalSize: selectionRect.size,
                  rect: element.rect,
                  kind: kind
              ) else { return }
        ctx.interpolationQuality = kind == .mosaic ? .none : .high
        ctx.draw(effected, in: element.rect)
    }

    // MARK: - 窗口识别

    /// 获取当前屏幕所有可见窗口
    private func refreshWindows() {
        guard let screen = window?.screen else { return }
        let options = CGWindowListOption(arrayLiteral: [.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }

        visibleWindows = list.compactMap { dict in
            guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0, // 只取普通窗口
                  let owner = dict[kCGWindowOwnerName as String] as? String,
                  owner != "TBOX" // 排除自己
            else { return nil }

            let windowBounds = NSRect(x: x, y: y, width: w, height: h)
            // 只保留在当前屏幕范围内的窗口
            let appKitBounds = NSRect(
                x: windowBounds.origin.x,
                y: cgCoordinateReferenceY - windowBounds.maxY,
                width: windowBounds.width,
                height: windowBounds.height
            )
            guard appKitBounds.intersects(screen.frame) else { return nil }

            let name = dict[kCGWindowName as String] as? String ?? ""
            return WindowInfo(bounds: windowBounds, appName: owner, windowName: name)
        }
    }

    /// 查找鼠标所在的窗口（point 为本地视图坐标，需转为 CG 全局坐标）
    private func windowAt(_ localPoint: NSPoint) -> Int {
        guard let screen = window?.screen else { return -1 }
        // 本地坐标（左下角原点）→ CG 全局坐标（左上角原点）
        let globalX = localPoint.x + screen.frame.origin.x
        let appKitGlobalY = localPoint.y + screen.frame.origin.y
        let globalY = cgCoordinateReferenceY - appKitGlobalY
        let globalPoint = NSPoint(x: globalX, y: globalY)

        for (i, win) in visibleWindows.enumerated() {
            if NSRect(x: win.bounds.origin.x, y: win.bounds.origin.y,
                       width: win.bounds.width, height: win.bounds.height).contains(globalPoint) {
                return i
            }
        }
        return -1
    }

    /// CG 窗口坐标（左上角原点）→ 本地视图坐标（左下角原点）
    private func convertToLocal(_ globalBounds: NSRect) -> NSRect {
        guard let screen = window?.screen else { return globalBounds }
        let appKitGlobalY = cgCoordinateReferenceY - globalBounds.maxY
        let localY = appKitGlobalY - screen.frame.origin.y
        return NSRect(x: globalBounds.origin.x - screen.frame.origin.x,
                       y: localY,
                       width: globalBounds.width,
                       height: globalBounds.height).intersection(bounds)
    }

    /// CoreGraphics 的全局 Y 原点位于主屏顶部，AppKit 位于主屏底部。
    private var cgCoordinateReferenceY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        updateFloatingElements()
    }

    private func updateFloatingElements() {
        let showFloating = hasSelection && !selectionRect.isEmpty

        if showFloating {
            if isAnnotationMode {
                infoBar.isHidden = true
                toolbar.isHidden = true
                layoutAnnotationToolbar()
            } else {
                infoBar.isHidden = false
                toolbar.isHidden = false
                annotationToolbar.isHidden = true
                layoutInfoBar()
                layoutToolbar()
                if !textResultPanel.isHidden {
                    layoutTextResultPanel()
                }
            }
        } else {
            infoBar.isHidden = true
            toolbar.isHidden = true
            annotationToolbar.isHidden = true
            textResultPanel.isHidden = true
        }
    }

    private func layoutInfoBar() {
        infoBar.isHidden = false
        infoBar.updateSize(width: selectionRect.width, height: selectionRect.height)
        let infoSize = infoBar.calcFittingSize()
        let pad: CGFloat = 8

        // 优先放在选区上方
        var y = selectionRect.maxY + pad
        if y + infoSize.height > bounds.maxY - 4 {
            // 上方溢出 → 翻到下方
            y = selectionRect.minY - infoSize.height - pad
        }
        if y < 4 {
            // 下方也溢出 → 放在选区内部顶部
            y = selectionRect.maxY - infoSize.height - pad
        }

        var x = selectionRect.midX - infoSize.width / 2
        x = max(4, min(x, bounds.maxX - infoSize.width - 4))

        infoBar.frame = NSRect(x: x, y: y, width: infoSize.width, height: infoSize.height)
    }

    private func layoutToolbar() {
        toolbar.isHidden = false
        let tbSize = toolbar.calcFittingSize()
        let pad: CGFloat = 8

        // 优先放在选区右下角外侧
        var y = selectionRect.minY - tbSize.height - pad
        if y < 4 {
            // 下方溢出 → 翻到上方
            y = selectionRect.maxY + pad
        }
        if y + tbSize.height > bounds.maxY - 4 {
            // 上方也溢出 → 放在选区内部底部
            y = selectionRect.minY + pad
        }

        var x = selectionRect.maxX - tbSize.width
        if x < 4 {
            // 右侧溢出 → 靠左
            x = selectionRect.minX
        }
        if x + tbSize.width > bounds.maxX - 4 {
            x = bounds.maxX - tbSize.width - 4
        }
        x = max(4, x)

        toolbar.frame = NSRect(x: x, y: y, width: tbSize.width, height: tbSize.height)
        toolbar.layoutButtons()
    }

    private func layoutTextResultPanel() {
        guard hasSelection, !textResultPanel.isHidden else { return }
        let panelWidth: CGFloat = min(340, max(280, bounds.width - 16))
        let panelHeight: CGFloat = min(360, max(280, selectionRect.height))
        let pad: CGFloat = 10

        var x = selectionRect.maxX + pad
        if x + panelWidth > bounds.maxX - 4 {
            x = selectionRect.minX - panelWidth - pad
        }
        if x < 4 {
            x = max(4, min(selectionRect.maxX - panelWidth, bounds.maxX - panelWidth - 4))
        }

        var y = selectionRect.maxY - panelHeight
        y = max(4, min(y, bounds.maxY - panelHeight - 4))
        textResultPanel.frame = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        textResultPanel.needsLayout = true
    }

    private func layoutAnnotationToolbar() {
        annotationToolbar.isHidden = false
        let tbSize = annotationToolbar.calcFittingSize()
        let pad: CGFloat = 8

        // 放在选区下方
        var y = selectionRect.minY - tbSize.height - pad
        if y < 4 {
            y = selectionRect.maxY + pad
        }
        var x = selectionRect.midX - tbSize.width / 2
        x = max(4, min(x, bounds.maxX - tbSize.width - 4))

        annotationToolbar.frame = NSRect(x: x, y: y, width: tbSize.width, height: tbSize.height)
        annotationToolbar.layoutButtons()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 如果没有截图，画暗色背景作为后备
        guard let image = screenshotImage else {
            NSColor(white: 0, alpha: 0.5).setFill()
            ctx.fill(bounds)
        print("[TBOX] draw: 无截图，画暗色后备背景")
            return
        }

        // 全屏截图
        image.draw(in: bounds)

        // 窗口高亮（鼠标悬停时，在加暗色遮罩之前画）
        if isHoveringWindow && !hasSelection && !isDragging {
            let winBounds = visibleWindows[highlightedWindowIndex].bounds
            let hb = convertToLocal(winBounds)

            // 擦亮窗口区域
            ctx.saveGState()
            ctx.clip(to: hb)
            image.draw(in: bounds)
            ctx.restoreGState()

            // 蓝色边框
            NSColor.tboxBlue.setStroke()
            let bp = NSBezierPath(rect: hb)
            bp.lineWidth = 2.0
            bp.stroke()

            // 窗口名称提示
            let win = visibleWindows[highlightedWindowIndex]
            let title = win.windowName.isEmpty ? win.appName : "\(win.appName) — \(win.windowName)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
            ]
            let titleSize = title.size(withAttributes: attrs)
            // 提示卡片放在窗口顶部中间
            let cardPad: CGFloat = 6
            let cardRect = NSRect(
                x: hb.midX - titleSize.width / 2 - cardPad,
                y: hb.maxY + 4,
                width: titleSize.width + cardPad * 2,
                height: titleSize.height + cardPad
            )
            NSColor.tboxBlue.setFill()
            let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 4, yRadius: 4)
            cardPath.fill()
            title.draw(
                at: NSPoint(x: cardRect.midX - titleSize.width / 2, y: cardRect.minY + 3),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
            )
        }

        // 全屏加暗，选区随后重绘原截图保持清晰。
        NSColor(white: 0, alpha: 0.35).setFill()
        ctx.fill(bounds)

        // 选区区域：无论普通框选还是标注模式，都重绘原截图。
        let showSelection = (hasSelection || isDragging) && !selectionRect.isEmpty && selectionRect.width > 0
        if showSelection {
            // 擦亮选区
            ctx.saveGState()
            ctx.clip(to: selectionRect)
            image.draw(in: bounds)
            ctx.restoreGState()

            // 选区边框
            NSColor.tboxBlue.setStroke()
            let borderPath = NSBezierPath(rect: selectionRect)
            borderPath.lineWidth = 1.5
            borderPath.stroke()

            // 标注模式由透明画布接管交互，不显示选区控制点。
            if hasSelection && !isAnnotationMode {
                drawHandles(ctx: ctx)
            }
        }

        // 放大镜（拖拽中）
        if isDragging {
            drawMagnifier(ctx: ctx)
        }

    }

    private var tooltipVisible = false

    private func drawHandles(ctx: CGContext) {
        // 四角控制点
        let corners = [
            NSPoint(x: selectionRect.minX, y: selectionRect.minY),
            NSPoint(x: selectionRect.maxX, y: selectionRect.minY),
            NSPoint(x: selectionRect.minX, y: selectionRect.maxY),
            NSPoint(x: selectionRect.maxX, y: selectionRect.maxY),
        ]
        for corner in corners {
            let rect = NSRect(
                x: corner.x - handleSize / 2,
                y: corner.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.tboxBlue.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 1.5
            path.stroke()
        }

        // 四边中点控制点（小矩形）
        let edgeHandles: [(NSPoint, CGFloat, CGFloat)] = [
            (NSPoint(x: selectionRect.midX, y: selectionRect.minY), 20, 4),  // 下
            (NSPoint(x: selectionRect.midX, y: selectionRect.maxY), 20, 4),  // 上
            (NSPoint(x: selectionRect.minX, y: selectionRect.midY), 4, 20),  // 左
            (NSPoint(x: selectionRect.maxX, y: selectionRect.midY), 4, 20),  // 右
        ]
        for (center, w, h) in edgeHandles {
            let rect = NSRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            NSColor.tboxBlue.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    private func drawMagnifier(ctx: CGContext) {
        guard let image = screenshotImage else { return }
        let magSize: CGFloat = 90
        let zoom: CGFloat = 6
        let mp = mouseLocation

        var magOrigin = NSPoint(x: mp.x + 16, y: mp.y + 16)
        if magOrigin.x + magSize > bounds.maxX { magOrigin.x = mp.x - magSize - 16 }
        if magOrigin.y + magSize > bounds.maxY { magOrigin.y = mp.y - magSize - 16 }
        let magRect = NSRect(origin: magOrigin, size: NSSize(width: magSize, height: magSize))

        // 背景
        NSColor(white: 0, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: magRect, xRadius: 6, yRadius: 6).fill()

        // 放大像素
        let srcSize = magSize / zoom
        let srcRect = NSRect(
            x: mp.x - srcSize / 2,
            y: mp.y - srcSize / 2,
            width: srcSize,
            height: srcSize
        )
        ctx.saveGState()
        NSBezierPath(roundedRect: magRect, xRadius: 6, yRadius: 6).addClip()
        image.draw(in: magRect, from: srcRect, operation: .copy, fraction: 1.0)
        ctx.restoreGState()

        // 十字准星
        NSColor.tboxBlue.setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: magRect.midX, y: magRect.minY))
        cross.line(to: NSPoint(x: magRect.midX, y: magRect.maxY))
        cross.move(to: NSPoint(x: magRect.minX, y: magRect.midY))
        cross.line(to: NSPoint(x: magRect.maxX, y: magRect.midY))
        cross.lineWidth = 1
        cross.stroke()

        // 边框
        NSColor.white.withAlphaComponent(0.3).setStroke()
        NSBezierPath(roundedRect: magRect, xRadius: 6, yRadius: 6).stroke()

        // 坐标文字
        let coordText = "\(Int(mp.x)), \(Int(mp.y))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        coordText.draw(at: NSPoint(x: magRect.minX + 4, y: magRect.minY + 4), withAttributes: attrs)
    }

    // MARK: - 控制点命中检测

    private func handleAt(_ p: NSPoint) -> Handle {
        guard hasSelection else { return .none }

        // 先检查选区内部 → 整体移动
        let inner = selectionRect.insetBy(dx: handleSize, dy: handleSize)
        if inner.contains(p) { return .move }

        // 四角控制点
        let r: CGFloat = handleSize
        if p.x < selectionRect.minX + r && p.y < selectionRect.minY + r { return .bottomLeft }
        if p.x > selectionRect.maxX - r && p.y < selectionRect.minY + r { return .bottomRight }
        if p.x < selectionRect.minX + r && p.y > selectionRect.maxY - r { return .topLeft }
        if p.x > selectionRect.maxX - r && p.y > selectionRect.maxY - r { return .topRight }

        // 四条边缘 → 水平/垂直缩放
        let e = edgeHitWidth
        if abs(p.x - selectionRect.minX) < e && p.y > selectionRect.minY + r && p.y < selectionRect.maxY - r { return .left }
        if abs(p.x - selectionRect.maxX) < e && p.y > selectionRect.minY + r && p.y < selectionRect.maxY - r { return .right }
        if abs(p.y - selectionRect.minY) < e && p.x > selectionRect.minX + r && p.x < selectionRect.maxX - r { return .bottom }
        if abs(p.y - selectionRect.maxY) < e && p.x > selectionRect.minX + r && p.x < selectionRect.maxX - r { return .top }

        return .none
    }

    // MARK: - 事件命中测试

    /// 重写 hitTest，让子视图（工具栏按钮、画布）通过 AppKit 正常事件链接收事件。
    /// super.hitTest 已正确处理坐标转换和子视图遍历，这里只做透明区域穿透。
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 标注模式下，非画布/工具栏区域不接收事件（让事件穿透到下方）
        if isAnnotationMode {
            // super.hitTest 会遍历子视图，如果命中画布或工具栏按钮就返回它们
            // 如果没命中任何子视图，返回 self → 但我们希望非子视图区域不拦截事件
            if let hit = super.hitTest(point), hit !== self {
                return hit
            }
            return nil  // 非子视图区域：不拦截，事件穿透
        }

        // 非标注模式：默认行为，子视图（工具栏/信息条）命中优先，否则返回 self 处理框选
        return super.hitTest(point)
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // 标注模式下，点击非画布区域 → 不做任何事（hitTest 已将画布/工具栏事件派发给子视图）
        if isAnnotationMode {
            return
        }

        // 检查控制点拖拽 / 边缘缩放 / 整体移动
        let h = handleAt(p)
        if h != .none {
            draggingHandle = h
            if h == .move {
                moveOffset = NSPoint(x: selectionRect.origin.x - p.x, y: selectionRect.origin.y - p.y)
            } else {
                handleAnchor = anchorPoint(for: h)
            }
            return
        }

        // 已有选区，点击外围 → 取消
        if hasSelection && !selectionRect.contains(p) {
            onCancel?()
            return
        }

        // 无论当前是否悬停窗口，都先进入自由框选候选状态。
        // 只有鼠标没有产生有效拖动时，mouseUp 才把这次操作解释为“单击选中窗口”。
        pendingWindowIndex = isHoveringWindow ? highlightedWindowIndex : -1
        didDragSelection = false
        startPoint = p
        selectionRect = NSRect(origin: p, size: .zero)
        isDragging = true
        hasSelection = false
        needsDisplay = true
        updateFloatingElements()
    }

    override func mouseDragged(with event: NSEvent) {
        if isAnnotationMode { return }
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p

        if draggingHandle != .none {
            resetTextResult()
            if draggingHandle == .move {
                // 整体移动
                let newX = p.x + moveOffset.x
                let newY = p.y + moveOffset.y
                selectionRect.origin = NSPoint(x: newX, y: newY)
            } else {
                adjustSelectionWithHandle(at: p)
                normalizeSelection()
            }
            needsDisplay = true
            updateFloatingElements()
            return
        }

        guard isDragging else { return }

        resetTextResult()

        // 只要收到 mouseDragged 就进入自定义框选；没有拖拽事件才属于单击自动框选。
        didDragSelection = true
        pendingWindowIndex = -1
        highlightedWindowIndex = -1

        let origin = NSPoint(x: min(startPoint.x, p.x), y: min(startPoint.y, p.y))
        let size = NSSize(width: abs(p.x - startPoint.x), height: abs(p.y - startPoint.y))
        selectionRect = NSRect(origin: origin, size: size)
        needsDisplay = true
        updateFloatingElements()
    }

    override func mouseUp(with event: NSEvent) {
        if isAnnotationMode { return }
        if draggingHandle != .none {
            draggingHandle = .none
            return
        }
        guard isDragging else { return }
        isDragging = false

        if didDragSelection,
           selectionRect.width >= minimumSelectionSize,
           selectionRect.height >= minimumSelectionSize {
            hasSelection = true
            pendingWindowIndex = -1
            highlightedWindowIndex = -1
            needsDisplay = true
            updateFloatingElements()
        } else if pendingWindowIndex >= 0, pendingWindowIndex < visibleWindows.count {
            // 没有有效拖动：保留窗口智能吸附的单击选择行为。
            selectionRect = convertToLocal(visibleWindows[pendingWindowIndex].bounds)
            hasSelection = !selectionRect.isEmpty
            pendingWindowIndex = -1
            highlightedWindowIndex = -1
            needsDisplay = true
            updateFloatingElements()
        } else {
            hasSelection = false
            selectionRect = .zero
            pendingWindowIndex = -1
            needsDisplay = true
            updateFloatingElements()
        }
        didDragSelection = false
    }

    /// 由 OverlayPanel.sendEvent 调用，确保即使鼠标在子视图上也能更新光标和 tooltip
    func handleMouseMoved(_ event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)

        // 窗口悬停检测（仅在无选区时）
        if !hasSelection && !isDragging {
            let prev = highlightedWindowIndex
            highlightedWindowIndex = windowAt(mouseLocation)
            if prev != highlightedWindowIndex {
                needsDisplay = true
            }
        }

        updateCursor()
        if directHoverText != nil {
            if tooltipVisible, let text = directHoverText {
                showTooltipBubble(text: text, at: mouseLocation)
            }
        } else {
            updateTooltip(for: mouseLocation)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        handleMouseMoved(event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        hideTooltip()
    }

    // MARK: - 自定义 Tooltip

    /// 主功能栏由按钮自身的 tracking area 驱动，不再依赖父视图 hitTest。
    private func handleToolbarHover(text: String?, event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        tooltipVisible = false
        tooltipBubble.isHidden = true
        directHoverText = text
        currentTooltipText = text

        guard let text, !text.isEmpty else {
            AppLog.ui("功能按钮悬停结束")
            return
        }

        AppLog.ui("功能按钮悬停命中: \(text)")
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, self.directHoverText == text else { return }
            self.tooltipVisible = true
            self.showTooltipBubble(text: text, at: self.mouseLocation)
            AppLog.ui("功能按钮提示已显示: \(text)")
        }
        tooltipTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 检测鼠标下按钮的 toolTip，延迟显示
    private func updateTooltip(for point: NSPoint) {
        let newTip = tooltipTextAt(point)

        if newTip != currentTooltipText {
            // 切换到新目标：先隐藏，重新计时
            tooltipVisible = false
            tooltipBubble.isHidden = true
            tooltipTimer?.invalidate()
            currentTooltipText = newTip
            if let newTip {
                let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
                    guard let self, self.currentTooltipText == newTip else { return }
                    self.tooltipVisible = true
                    self.showTooltipBubble(text: newTip, at: self.mouseLocation)
                }
                tooltipTimer = timer
                // 鼠标跟踪会切换 RunLoop mode；使用 common 确保停留时计时器仍能触发。
                RunLoop.main.add(timer, forMode: .common)
            }
        } else if tooltipVisible {
            showTooltipBubble(text: newTip ?? "", at: point)
        }
    }

    /// 获取鼠标位置下按钮的 toolTip
    private func tooltipTextAt(_ point: NSPoint) -> String? {
        for sv in [toolbar, infoBar, annotationToolbar, textResultPanel] {
            guard let sv = sv, !sv.isHidden else { continue }
            if sv.frame.contains(point) {
                let localP = sv.convert(point, from: self)
                var hit = sv.hitTest(localP)
                // 命中按钮内部视图时向上查找，直到获得按钮设置的中文 toolTip。
                while let view = hit, view !== sv {
                    if let tip = view.toolTip, !tip.isEmpty {
                        return tip
                    }
                    hit = view.superview
                }
            }
        }
        return nil
    }

    private func showTooltipBubble(text: String, at point: NSPoint) {
        guard !text.isEmpty else {
            tooltipBubble.isHidden = true
            return
        }
        let size = tooltipBubble.fittingSize(for: text)
        let margin: CGFloat = 6
        var x = point.x - size.width / 2
        var y = point.y - size.height - 22

        x = max(margin, min(x, bounds.maxX - size.width - margin))
        if y < margin {
            y = point.y + 22
        }
        y = max(margin, min(y, bounds.maxY - size.height - margin))

        tooltipBubble.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        tooltipBubble.text = text
        tooltipBubble.isHidden = false
        addSubview(tooltipBubble, positioned: .above, relativeTo: nil)
    }

    private func hideTooltip() {
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        tooltipVisible = false
        currentTooltipText = nil
        directHoverText = nil
        tooltipBubble?.isHidden = true
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    /// 计算拖拽时的对角锚点（不动点）
    private func anchorPoint(for handle: Handle) -> NSPoint {
        switch handle {
        case .topLeft:     return NSPoint(x: selectionRect.maxX, y: selectionRect.minY)
        case .topRight:    return NSPoint(x: selectionRect.minX, y: selectionRect.minY)
        case .bottomLeft:  return NSPoint(x: selectionRect.maxX, y: selectionRect.maxY)
        case .bottomRight: return NSPoint(x: selectionRect.minX, y: selectionRect.maxY)
        case .left:        return NSPoint(x: selectionRect.maxX, y: selectionRect.minY)
        case .right:       return NSPoint(x: selectionRect.minX, y: selectionRect.minY)
        case .top:         return NSPoint(x: selectionRect.minX, y: selectionRect.minY)
        case .bottom:      return NSPoint(x: selectionRect.minX, y: selectionRect.maxY)
        default:           return .zero
        }
    }

    private func adjustSelectionWithHandle(at p: NSPoint) {
        let a = handleAnchor
        switch draggingHandle {
        case .bottomLeft, .topLeft, .left:
            selectionRect.origin.x = min(p.x, a.x)
            selectionRect.size.width = abs(p.x - a.x)
        case .bottomRight, .topRight, .right:
            selectionRect.origin.x = min(p.x, a.x)
            selectionRect.size.width = abs(p.x - a.x)
        case .top, .bottom:
            break // 宽度不变，只下面处理高度
        default: break
        }
        switch draggingHandle {
        case .bottomLeft, .bottomRight, .bottom:
            selectionRect.origin.y = min(p.y, a.y)
            selectionRect.size.height = abs(p.y - a.y)
        case .topLeft, .topRight, .top:
            selectionRect.origin.y = min(p.y, a.y)
            selectionRect.size.height = abs(p.y - a.y)
        case .left, .right:
            break // 高度不变
        default: break
        }
    }

    private func normalizeSelection() {
        if selectionRect.width < 0 {
            selectionRect.origin.x += selectionRect.width
            selectionRect.size.width = -selectionRect.width
        }
        if selectionRect.height < 0 {
            selectionRect.origin.y += selectionRect.height
            selectionRect.size.height = -selectionRect.height
        }
    }

    // MARK: - 光标样式

    private lazy var cursorNWSE = makeDiagonalCursor(angle: -45) // ↖
    private lazy var cursorNESW = makeDiagonalCursor(angle: 45)  // ↗
    private lazy var cursorMove  = makeMoveCursor()

    private func updateCursor() {
        // 窗口悬停
        if isHoveringWindow && !hasSelection {
            NSCursor.pointingHand.set()
            return
        }
        // 鼠标在工具栏/信息条按钮上 → 指向手
        if isMouseOverButton() {
            NSCursor.pointingHand.set()
            return
        }
        let h = handleAt(mouseLocation)
        switch h {
        case .topLeft, .bottomRight:     cursorNWSE.set()
        case .topRight, .bottomLeft:     cursorNESW.set()
        case .top, .bottom:              NSCursor.resizeUpDown.set()
        case .left, .right:              NSCursor.resizeLeftRight.set()
        case .move:                      cursorMove.set()
        case .none:
            // 有选区时选区外显示箭头，无选区时显示十字
            if hasSelection { NSCursor.arrow.set() }
            else { NSCursor.crosshair.set() }
        }
    }

    /// 鼠标是否悬停在工具栏/信息条的按钮上
    private func isMouseOverButton() -> Bool {
        for sv in [toolbar, infoBar, annotationToolbar, textResultPanel] {
            guard let sv = sv, !sv.isHidden else { continue }
            if sv.frame.contains(mouseLocation) {
                let localP = sv.convert(mouseLocation, from: self)
                if let hit = sv.hitTest(localP), hit !== sv {
                    return true
                }
            }
        }
        return false
    }

    /// 绘制对角缩放光标（angle: -45 = NW-SE, 45 = NE-SW）
    private func makeDiagonalCursor(angle: CGFloat) -> NSCursor {
        let sz = NSSize(width: 16, height: 16)
        let img = NSImage(size: sz, flipped: false) { [angle] rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            NSColor.black.setStroke()
            let path = NSBezierPath()
            let cx = rect.midX, cy = rect.midY
            let len: CGFloat = 5
            // 计算两个箭头方向
            let rad = angle * .pi / 180
            func drawArrow(at origin: NSPoint, dir: CGPoint) {
                let tip = NSPoint(x: origin.x + dir.x * len, y: origin.y + dir.y * len)
                let rx = dir.y * 2, ry = -dir.x * 2
                path.move(to: NSPoint(x: tip.x - rx, y: tip.y - ry))
                path.line(to: tip)
                path.line(to: NSPoint(x: tip.x + rx, y: tip.y + ry))
            }
            let d1 = CGPoint(x: cos(rad), y: sin(rad))
            let d2 = CGPoint(x: -cos(rad), y: -sin(rad))
            drawArrow(at: NSPoint(x: cx, y: cy), dir: d1)
            drawArrow(at: NSPoint(x: cx, y: cy), dir: d2)
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 8, y: 8))
    }

    /// 绘制四向箭头（移动光标）
    private func makeMoveCursor() -> NSCursor {
        let sz = NSSize(width: 16, height: 16)
        let img = NSImage(size: sz, flipped: false) { rect in
            let cx = rect.midX, cy = rect.midY
            let len: CGFloat = 5, gap: CGFloat = 2
            NSColor.black.setStroke()
            let path = NSBezierPath()
            // 上箭头
            path.move(to: NSPoint(x: cx, y: cy + gap))
            path.line(to: NSPoint(x: cx, y: cy + len))
            path.move(to: NSPoint(x: cx - 2, y: cy + len - 2))
            path.line(to: NSPoint(x: cx, y: cy + len))
            path.line(to: NSPoint(x: cx + 2, y: cy + len - 2))
            // 下箭头
            path.move(to: NSPoint(x: cx, y: cy - gap))
            path.line(to: NSPoint(x: cx, y: cy - len))
            path.move(to: NSPoint(x: cx - 2, y: cy - len + 2))
            path.line(to: NSPoint(x: cx, y: cy - len))
            path.line(to: NSPoint(x: cx + 2, y: cy - len + 2))
            // 左箭头
            path.move(to: NSPoint(x: cx + gap, y: cy))
            path.line(to: NSPoint(x: cx + len, y: cy))
            path.move(to: NSPoint(x: cx + len - 2, y: cy - 2))
            path.line(to: NSPoint(x: cx + len, y: cy))
            path.line(to: NSPoint(x: cx + len - 2, y: cy + 2))
            // 右箭头
            path.move(to: NSPoint(x: cx - gap, y: cy))
            path.line(to: NSPoint(x: cx - len, y: cy))
            path.move(to: NSPoint(x: cx - len + 2, y: cy - 2))
            path.line(to: NSPoint(x: cx - len, y: cy))
            path.line(to: NSPoint(x: cx - len + 2, y: cy + 2))
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 8, y: 8))
    }

    // MARK: - 键盘事件

    override func keyDown(with event: NSEvent) {
        if isAnnotationMode, let canvas = annotationCanvas {
            canvas.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36: // Enter
            if hasSelection { onCapture?(selectionRect) }
        default:
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - HoverTooltipView（高层截图遮罩中的自定义悬停提示）

final class HoverTooltipView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        layer?.cornerRadius = 6
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func fittingSize(for text: String) -> NSSize {
        label.stringValue = text
        let labelSize = label.fittingSize
        return NSSize(width: labelSize.width + 18, height: labelSize.height + 10)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 9, dy: 5)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// 按钮自行监听进入/离开事件，避免高层截图窗口中父视图 hitTest 不稳定。
final class HoverTrackingButton: NSButton {
    var onHoverChange: ((String?, NSEvent) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(toolTip, event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(nil, event)
    }
}

// MARK: - SelectionInfoBar（选区上方信息条）

class SelectionInfoBar: NSView {
    private let sizeLabel = NSTextField(labelWithString: "0 × 0")
    private let cornerSlider = NSSlider(value: 0, minValue: 0, maxValue: 30, target: nil, action: nil)
    private let cornerLabel = NSTextField(labelWithString: "圆角")
    private let shadowToggle = NSButton(checkboxWithTitle: "阴影", target: nil, action: nil)

    var cornerRadius: CGFloat = 0
    var hasShadow = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.15
        layer?.shadowRadius = 6
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        sizeLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = NSColor(calibratedWhite: 0.2, alpha: 1)

        cornerSlider.controlSize = .small
        cornerSlider.isContinuous = true
        cornerSlider.target = self
        cornerSlider.action = #selector(cornerChanged(_:))
        cornerSlider.toolTip = "圆角半径"

        cornerLabel.font = NSFont.systemFont(ofSize: 11)
        cornerLabel.textColor = NSColor(calibratedWhite: 0.4, alpha: 1)

        shadowToggle.controlSize = .small
        shadowToggle.font = NSFont.systemFont(ofSize: 11)
        shadowToggle.target = self
        shadowToggle.action = #selector(shadowToggled(_:))
        shadowToggle.toolTip = "截图阴影"

        addSubview(sizeLabel)
        addSubview(cornerLabel)
        addSubview(cornerSlider)
        addSubview(shadowToggle)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func cornerChanged(_ s: NSSlider) {
        cornerRadius = CGFloat(s.doubleValue)
    }

    @objc private func shadowToggled(_ b: NSButton) {
        hasShadow = b.state == .on
    }

    func updateSize(width: CGFloat, height: CGFloat) {
        sizeLabel.stringValue = "\(Int(width)) × \(Int(height))"
    }

    func calcFittingSize() -> NSSize {
        layoutSubtreeIfNeeded()
        let h: CGFloat = 30
        let w = sizeLabel.fittingSize.width + 16
            + cornerLabel.fittingSize.width + 4 + 70 + 16
            + shadowToggle.fittingSize.width + 12
        return NSSize(width: w, height: h)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 10

        sizeLabel.frame = NSRect(
            x: x, y: (h - sizeLabel.fittingSize.height) / 2,
            width: sizeLabel.fittingSize.width, height: sizeLabel.fittingSize.height
        )
        x += sizeLabel.fittingSize.width + 14

        cornerLabel.frame = NSRect(
            x: x, y: (h - cornerLabel.fittingSize.height) / 2,
            width: cornerLabel.fittingSize.width, height: cornerLabel.fittingSize.height
        )
        x += cornerLabel.fittingSize.width + 4

        cornerSlider.frame = NSRect(x: x, y: (h - 14) / 2, width: 70, height: 14)
        x += 70 + 14

        shadowToggle.frame = NSRect(
            x: x, y: (h - shadowToggle.fittingSize.height) / 2,
            width: shadowToggle.fittingSize.width, height: shadowToggle.fittingSize.height
        )
    }
}

// MARK: - AnnotationToolbarView（标注工具栏）

class AnnotationToolbarView: NSView {
    var onToolChange: ((AnnotationToolType) -> Void)?
    var onColorChange: ((NSColor) -> Void)?
    var onLineWidthChange: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onDone: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    var currentTool: AnnotationToolType = .rect {
        didSet { updateToolButtons() }
    }
    var currentColor: NSColor = .systemRed {
        didSet { updateColorButtons() }
    }
    var currentLineWidth: CGFloat = 3 {
        didSet { updateLineWidthButtons() }
    }

    private let btnSize: CGFloat = 30
    private let toolGap: CGFloat = 2
    private let colorButtonSize: CGFloat = 24
    private let lineButtonSize: CGFloat = 26
    private let groupGap: CGFloat = 9
    private let horizontalInset: CGFloat = 8
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]
    private let lineWidths: [CGFloat] = [2, 3, 5, 8]
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var lineWidthButtons: [NSButton] = []
    private var actionButtons: [NSButton] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 0.75, alpha: 0.55).cgColor

        setupToolButtons()
        setupColorButtons()
        setupLineWidthButtons()
        setupActionButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupToolButtons() {
        let tools: [AnnotationToolType] = [.rect, .arrow, .pen, .text, .mosaic, .number, .highlight, .blur]
        for tool in tools {
            let btn = NSButton(frame: .zero)
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.title = ""
            btn.imagePosition = .imageOnly
            btn.image = NSImage(systemSymbolName: tool.icon, accessibilityDescription: tool.tooltip)
            btn.image?.isTemplate = true
            btn.toolTip = tool.tooltip
            btn.target = self
            btn.action = #selector(toolClicked(_:))
            btn.tag = tools.firstIndex(of: tool) ?? 0
            addSubview(btn)
            toolButtons.append(btn)
        }
        updateToolButtons()
    }

    private func setupColorButtons() {
        let colorNames = ["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "黑色", "白色"]
        for (i, color) in colors.enumerated() {
            let btn = NSButton(frame: .zero)
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.title = ""
            btn.image = nil
            btn.imagePosition = .noImage
            btn.wantsLayer = true
            btn.layer?.cornerRadius = colorButtonSize / 2
            btn.layer?.backgroundColor = color.cgColor
            btn.layer?.borderWidth = 0
            btn.toolTip = colorNames[i]
            btn.target = self
            btn.action = #selector(colorClicked(_:))
            btn.tag = i
            addSubview(btn)
            colorButtons.append(btn)
        }
        updateColorButtons()
    }

    private func setupLineWidthButtons() {
        for (i, w) in lineWidths.enumerated() {
            let btn = NSButton(frame: .zero)
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.title = ""
            btn.image = nil
            btn.imagePosition = .noImage
            btn.wantsLayer = true
            btn.layer?.backgroundColor = NSColor(white: 0.94, alpha: 1).cgColor
            btn.layer?.cornerRadius = 6
            btn.toolTip = "线宽 \(Int(w))px"
            let dot = NSView(frame: .zero)
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.darkGray.cgColor
            dot.layer?.cornerRadius = w / 2
            dot.allowedTouchTypes = []
            btn.addSubview(dot)
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
                dot.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: w),
                dot.heightAnchor.constraint(equalToConstant: w),
            ])
            btn.target = self
            btn.action = #selector(lineWidthClicked(_:))
            btn.tag = i
            addSubview(btn)
            lineWidthButtons.append(btn)
        }
        updateLineWidthButtons()
    }

    private func setupActionButtons() {
        let actions: [(String, String, Selector)] = [
            ("arrow.uturn.backward", "撤销", #selector(undoClicked)),
            ("arrow.uturn.forward", "重做", #selector(redoClicked)),
            ("square.and.arrow.down", "保存", #selector(saveClicked)),
            ("checkmark", "完成", #selector(doneClicked)),
            ("xmark", "取消", #selector(cancelClicked)),
        ]
        for (icon, tip, sel) in actions {
            let btn = NSButton(frame: .zero)
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.title = ""
            btn.imagePosition = .imageOnly
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tip)
            btn.image?.isTemplate = true
            btn.contentTintColor = NSColor(calibratedWhite: 0.35, alpha: 1)
            btn.toolTip = tip
            btn.target = self
            btn.action = sel
            addSubview(btn)
            actionButtons.append(btn)
        }
    }

    private func updateToolButtons() {
        for (i, btn) in toolButtons.enumerated() {
            guard i < AnnotationToolType.allCases.count else { break }
            let isSelected = AnnotationToolType.allCases[i] == currentTool
            btn.contentTintColor = isSelected ? .white : NSColor(calibratedWhite: 0.32, alpha: 1)
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 6
            btn.layer?.backgroundColor = isSelected ? NSColor.tboxBlue.cgColor : NSColor.clear.cgColor
        }
    }

    private func updateColorButtons() {
        for (i, btn) in colorButtons.enumerated() {
            let isSelected = colors[i] == currentColor
            btn.layer?.borderWidth = isSelected || colors[i] == .white ? 2 : 0
            btn.layer?.borderColor = isSelected
                ? NSColor.tboxBlue.cgColor
                : NSColor(white: 0.72, alpha: 1).cgColor
        }
    }

    private func updateLineWidthButtons() {
        for (i, btn) in lineWidthButtons.enumerated() {
            btn.layer?.borderWidth = lineWidths[i] == currentLineWidth ? 1.5 : 0
            btn.layer?.borderColor = NSColor.tboxBlue.cgColor
            btn.layer?.backgroundColor = lineWidths[i] == currentLineWidth
                ? NSColor.tboxBlue.withAlphaComponent(0.12).cgColor
                : NSColor(white: 0.94, alpha: 1).cgColor
        }
    }

    @objc private func toolClicked(_ sender: NSButton) {
        currentTool = AnnotationToolType.allCases[sender.tag]
        onToolChange?(currentTool)
    }

    @objc private func colorClicked(_ sender: NSButton) {
        guard sender.tag < colors.count else { return }
        currentColor = colors[sender.tag]
        onColorChange?(currentColor)
    }

    @objc private func lineWidthClicked(_ sender: NSButton) {
        guard sender.tag < lineWidths.count else { return }
        currentLineWidth = lineWidths[sender.tag]
        onLineWidthChange?(currentLineWidth)
    }

    @objc private func undoClicked() { onUndo?() }
    @objc private func redoClicked() { onRedo?() }
    @objc private func saveClicked() { onSave?() }
    @objc private func doneClicked() { onDone?() }
    @objc private func cancelClicked() { onCancel?() }

    func calcFittingSize() -> NSSize {
        layoutButtons()
        let toolsWidth = CGFloat(toolButtons.count) * btnSize + CGFloat(max(0, toolButtons.count - 1)) * toolGap
        let colorsWidth = CGFloat(colorButtons.count) * colorButtonSize + CGFloat(max(0, colorButtons.count - 1)) * toolGap
        let linesWidth = CGFloat(lineWidthButtons.count) * lineButtonSize + CGFloat(max(0, lineWidthButtons.count - 1)) * toolGap
        let actionsWidth = CGFloat(actionButtons.count) * btnSize + CGFloat(max(0, actionButtons.count - 1)) * toolGap
        let width = horizontalInset * 2 + toolsWidth + colorsWidth + linesWidth + actionsWidth + groupGap * 3
        return NSSize(width: width, height: 40)
    }

    /// 手动布局所有按钮，不依赖 layout() 自动调用
    func layoutButtons() {
        var x = horizontalInset
        let toolY: CGFloat = 5

        for btn in toolButtons {
            btn.frame = NSRect(x: x, y: toolY, width: btnSize, height: btnSize)
            x += btnSize + toolGap
        }
        x += groupGap - toolGap

        for btn in colorButtons {
            btn.frame = NSRect(x: x, y: (40 - colorButtonSize) / 2, width: colorButtonSize, height: colorButtonSize)
            btn.layer?.cornerRadius = colorButtonSize / 2
            x += colorButtonSize + toolGap
        }
        x += groupGap - toolGap

        for btn in lineWidthButtons {
            btn.frame = NSRect(x: x, y: (40 - lineButtonSize) / 2, width: lineButtonSize, height: lineButtonSize)
            x += lineButtonSize + toolGap
        }
        x += groupGap - toolGap

        for btn in actionButtons {
            btn.frame = NSRect(x: x, y: toolY, width: btnSize, height: btnSize)
            x += btnSize + toolGap
        }
    }
}

// MARK: - CaptureToolbar（选区下方工具栏）

class CaptureToolbar: NSView {
    var onCopy: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onAnnotate: ((AnnotationToolType) -> Void)?
    var onPin: (() -> Void)?
    var onExtractText: (() -> Void)?
    var onTranslate: (() -> Void)?
    var onRecord: (() -> Void)?
    var onTranscribe: (() -> Void)?
    var onHover: ((String?, NSEvent) -> Void)?

    private struct ToolItem {
        let icon: String
        let tooltip: String
        let action: (() -> Void)?
    }

    private var buttons: [NSButton] = []
    private var buttonActions: [(() -> Void)?] = []
    private let btnSize: CGFloat = 38
    private let iconPointSize: CGFloat = 18
    private let padding: CGFloat = 5
    private let separatorSpacing: CGFloat = 10

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        let items: [ToolItem] = [
            ToolItem(icon: "square.and.pencil", tooltip: "矩形标注") { [weak self] in self?.onAnnotate?(.rect) },
            ToolItem(icon: "arrow.up.right", tooltip: "箭头标注") { [weak self] in self?.onAnnotate?(.arrow) },
            ToolItem(icon: "scribble", tooltip: "画笔") { [weak self] in self?.onAnnotate?(.pen) },
            ToolItem(icon: "textformat", tooltip: "文字") { [weak self] in self?.onAnnotate?(.text) },
            ToolItem(icon: "record.circle", tooltip: "录制选区") { [weak self] in self?.onRecord?() },
            ToolItem(icon: "waveform", tooltip: "录音转写") { [weak self] in self?.onTranscribe?() },
            ToolItem(icon: "doc.text.viewfinder", tooltip: "提取框选区域文字") { [weak self] in self?.onExtractText?() },
            ToolItem(icon: "globe", tooltip: "翻译框选区域文字") { [weak self] in self?.onTranslate?() },
            ToolItem(icon: "pin", tooltip: "贴图") { [weak self] in self?.onPin?() },
            ToolItem(icon: "square.and.arrow.down", tooltip: "保存") { [weak self] in self?.onSave?() },
            ToolItem(icon: "checkmark", tooltip: "复制") { [weak self] in self?.onCopy?() },
            ToolItem(icon: "xmark", tooltip: "取消") { [weak self] in self?.onCancel?() },
        ]
        buttonActions = items.map(\.action)

        for (i, item) in items.enumerated() {
            let btn = HoverTrackingButton(frame: .zero)
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.tooltip)
            btn.image = btn.image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .medium)
            )
            btn.image?.isTemplate = true
            btn.title = ""
            btn.imagePosition = .imageOnly
            btn.contentTintColor = NSColor(calibratedWhite: 0.35, alpha: 1)
            btn.toolTip = item.tooltip
            btn.isEnabled = item.action != nil
            btn.target = self
            btn.tag = i
            btn.action = #selector(buttonClicked(_:))
            btn.onHoverChange = { [weak self] text, event in
                self?.onHover?(text, event)
            }
            addSubview(btn)
            buttons.append(btn)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard buttonActions.indices.contains(sender.tag) else { return }
        buttonActions[sender.tag]?()
    }

    func calcFittingSize() -> NSSize {
        layoutButtons()
        let count = CGFloat(buttons.count)
        let outerPadding: CGFloat = 10
        let w = count * btnSize + (count - 1) * padding + separatorSpacing + outerPadding
        return NSSize(width: w, height: btnSize + outerPadding)
    }

    /// 手动布局所有按钮
    func layoutButtons() {
        var x: CGFloat = 5
        let y: CGFloat = 5

        for (i, btn) in buttons.enumerated() {
            if i == 9 {
                x += separatorSpacing
            }
            btn.frame = NSRect(x: x, y: y, width: btnSize, height: btnSize)
            x += btnSize + padding
        }
    }
}
