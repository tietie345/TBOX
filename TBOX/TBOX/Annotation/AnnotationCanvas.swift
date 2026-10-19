import Cocoa

/// 透明标注画布，支持绘制、选中、拖拽、删除和原位文字输入。
class AnnotationCanvas: NSView, NSTextFieldDelegate {

    // MARK: - 状态

    var elements: [AnnotationElement] = []
    private var undoStack: [[AnnotationElement]] = []
    private var redoStack: [[AnnotationElement]] = []
    var currentTool: AnnotationToolType = .rect
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 3
    var sourceImage: CGImage? {
        didSet { needsDisplay = true }
    }
    var onDone: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private var isDrawing = false
    private var drawStart: NSPoint = .zero
    private var drawCurrent: NSPoint = .zero
    private var tempElement: AnnotationElement? // 正在绘制的临时元素
    private var selectedIndex: Int = -1
    private var isDraggingElement = false
    private var isResizingElement = false
    private enum ResizeHandle {
        case topLeft, top, topRight, right
        case bottomRight, bottom, bottomLeft, left
    }
    private var resizeHandle: ResizeHandle?
    private var resizeOriginalRect: NSRect = .zero
    private var interactionStartState: [AnnotationElement]?
    private var interactionDidChange = false
    private var dragOffset: NSPoint = .zero
    private var hoveredIndex: Int = -1
    private var inlineTextField: NSTextField?
    private var inlineTextOrigin: NSPoint = .zero
    private var isRenderingOutput = false

    // 控制点
    private let handleRadius: CGFloat = 5

    // MARK: - 初始化

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func activateTool(_ tool: AnnotationToolType) {
        finishInlineTextEditing(commit: true)
        currentTool = tool
        selectedIndex = -1
        isDrawing = false
        tempElement = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    func commitPendingEdits() {
        finishInlineTextEditing(commit: true)
    }

    /// 将底图与当前标注合成为原始像素尺寸的图片，导出时不包含选中框和控制点。
    func renderedComposite(with baseImage: CGImage) -> CGImage? {
        commitPendingEdits()
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: baseImage.width,
            height: baseImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        context.saveGState()
        context.scaleBy(
            x: CGFloat(baseImage.width) / bounds.width,
            y: CGFloat(baseImage.height) / bounds.height
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        isRenderingOutput = true
        draw(bounds)
        isRenderingOutput = false
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        return context.makeImage()
    }

    override func resetCursorRects() {
        let cursor: NSCursor = currentTool == .text ? .iBeam : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 绘制已完成的元素
        for (i, el) in elements.enumerated() {
            drawElement(el, isSelected: i == selectedIndex, ctx: ctx)
        }

        // 绘制临时元素（正在拖拽中）
        if let temp = tempElement {
            drawElement(temp, isSelected: false, ctx: ctx)
        }
    }

    private func drawElement(_ el: AnnotationElement, isSelected: Bool, ctx: CGContext) {
        ctx.saveGState()

        switch el.type {
        case .rect, .highlight:
            drawRect(el, ctx: ctx)
        case .arrow:
            drawArrow(el, ctx: ctx)
        case .pen:
            drawPen(el, ctx: ctx)
        case .text, .number:
            drawText(el, ctx: ctx)
        case .mosaic:
            drawMosaic(el, ctx: ctx)
        case .blur:
            drawBlur(el, ctx: ctx)
        }

        // 选中态：蓝色边框 + 控制点
        if isSelected && !isRenderingOutput {
            drawSelectionHandles(el.rect)
        }

        ctx.restoreGState()
    }

    // MARK: - 各工具绘制

    private func drawRect(_ el: AnnotationElement, ctx: CGContext) {
        let isHighlight = el.type == .highlight
        let fill = isHighlight ? el.strokeColor.withAlphaComponent(0.25) : NSColor.clear
        fill.setFill()
        el.strokeColor.setStroke()
        let path = NSBezierPath(rect: el.rect)
        path.lineWidth = el.lineWidth
        path.fill()
        path.stroke()
    }

    private func drawArrow(_ el: AnnotationElement, ctx: CGContext) {
        let from = el.path.first ?? el.rect.origin
        let tip = el.path.dropFirst().first ?? NSPoint(x: el.rect.maxX, y: el.rect.maxY)
        el.strokeColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = el.lineWidth
        path.move(to: from)
        path.line(to: tip)

        // 箭头头部
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let arrowLen: CGFloat = 12
        let arrowAngle: CGFloat = .pi / 6

        path.move(to: tip)
        path.line(to: NSPoint(
            x: tip.x - arrowLen * cos(angle - arrowAngle),
            y: tip.y - arrowLen * sin(angle - arrowAngle)
        ))
        path.move(to: tip)
        path.line(to: NSPoint(
            x: tip.x - arrowLen * cos(angle + arrowAngle),
            y: tip.y - arrowLen * sin(angle + arrowAngle)
        ))
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawPen(_ el: AnnotationElement, ctx: CGContext) {
        guard el.path.count >= 2 else { return }
        el.strokeColor.setStroke()
        let path = NSBezierPath()
        path.move(to: el.path[0])
        for pt in el.path.dropFirst() {
            path.line(to: pt)
        }
        path.lineWidth = el.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawText(_ el: AnnotationElement, ctx: CGContext) {
        if el.type == .number {
            // 序号：圆形底 + 数字
            let r = min(el.rect.width, el.rect.height) / 2
            let center = NSPoint(x: el.rect.midX, y: el.rect.midY)
            el.strokeColor.setFill()
            let circle = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            circle.fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: el.fontSize),
                .foregroundColor: NSColor.white,
            ]
            let size = el.text.size(withAttributes: attrs)
            el.text.draw(
                at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                withAttributes: attrs
            )
        } else {
            let attrs = textAttributes(fontSize: el.fontSize, color: el.strokeColor)
            (el.text as NSString).draw(
                with: el.rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs,
                context: nil
            )
        }
    }

    private func drawMosaic(_ el: AnnotationElement, ctx: CGContext) {
        drawImageEffect(el, kind: .mosaic, fallbackColor: NSColor(white: 0.45, alpha: 0.65))
    }

    private func drawBlur(_ el: AnnotationElement, ctx: CGContext) {
        drawImageEffect(el, kind: .blur, fallbackColor: NSColor.white.withAlphaComponent(0.55))
    }

    private func drawImageEffect(_ element: AnnotationElement, kind: ImageEffectKind, fallbackColor: NSColor) {
        if let sourceImage,
           let effected = ImageProcessing.effectRegion(
               from: sourceImage,
               logicalSize: bounds.size,
               rect: element.rect,
               kind: kind
           ) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: effected, size: element.rect.size).draw(in: element.rect)
        } else {
            fallbackColor.setFill()
            element.rect.fill()
        }
    }

    // MARK: - 选中态控制点

    private func drawSelectionHandles(_ rect: NSRect) {
        NSColor.tboxBlue.setStroke()
        let bp = NSBezierPath(rect: rect)
        bp.lineWidth = 1.5
        bp.stroke()

        let handles: [NSPoint] = [
            rect.origin, NSPoint(x: rect.midX, y: rect.origin.y), NSPoint(x: rect.maxX, y: rect.origin.y),
            NSPoint(x: rect.maxX, y: rect.midY), NSPoint(x: rect.maxX, y: rect.maxY),
            NSPoint(x: rect.midX, y: rect.maxY), NSPoint(x: rect.origin.x, y: rect.maxY),
            NSPoint(x: rect.origin.x, y: rect.midY),
        ]

        for hp in handles {
            NSColor.white.setFill()
            let hRect = NSRect(x: hp.x - handleRadius, y: hp.y - handleRadius,
                                width: handleRadius * 2, height: handleRadius * 2)
            let hPath = NSBezierPath(ovalIn: hRect)
            hPath.fill()
            NSColor.tboxBlue.setStroke()
            hPath.lineWidth = 1.5
            hPath.stroke()
        }
    }

    // MARK: - 鼠标交互

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // 检查是否点击了已有元素的控制点
        if selectedIndex >= 0, let handle = handleAt(p, for: elements[selectedIndex].rect) {
            interactionStartState = snapshot()
            interactionDidChange = false
            isResizingElement = true
            resizeHandle = handle
            resizeOriginalRect = elements[selectedIndex].rect
            return
        }

        // 检查是否点击了已有元素
        if let idx = elementAt(p) {
            selectedIndex = idx
            interactionStartState = snapshot()
            interactionDidChange = false
            isDraggingElement = true
            dragOffset = NSPoint(x: elements[idx].rect.origin.x - p.x,
                                  y: elements[idx].rect.origin.y - p.y)
            needsDisplay = true
            return
        }

        // 取消选中
        if selectedIndex >= 0 {
            selectedIndex = -1
            needsDisplay = true
        }

        // 开始绘制新元素
        isDrawing = true
        drawStart = p
        drawCurrent = p

        if currentTool == .text {
            beginInlineTextEditing(at: p)
            isDrawing = false
        } else if currentTool == .number {
            recordHistory()
            let nextNumber = elements
                .filter { $0.type == .number }
                .compactMap { Int($0.text) }
                .max().map { $0 + 1 } ?? 1
            let size: CGFloat = 32
            elements.append(AnnotationElement(
                type: .number,
                rect: NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size),
                strokeColor: currentColor,
                text: String(nextNumber),
                fontSize: 16
            ))
            selectedIndex = elements.count - 1
            isDrawing = false
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if isResizingElement, selectedIndex >= 0, let resizeHandle {
            let el = elements[selectedIndex]
            let oldRect = el.rect
            let newRect = resizedRect(from: resizeOriginalRect, handle: resizeHandle, point: p)
            updateElement(el, from: oldRect, to: newRect)
            if oldRect != newRect {
                interactionDidChange = true
                needsDisplay = true
            }
            return
        }

        if isDraggingElement, selectedIndex >= 0 {
            let el = elements[selectedIndex]
            let oldRect = el.rect
            var newRect = oldRect
            newRect.origin = NSPoint(x: p.x + dragOffset.x, y: p.y + dragOffset.y)
            updateElement(el, from: oldRect, to: newRect)
            if oldRect != el.rect {
                interactionDidChange = true
                needsDisplay = true
            }
            return
        }

        guard isDrawing else { return }
        drawCurrent = p

        let rect = NSRect(
            x: min(drawStart.x, drawCurrent.x),
            y: min(drawStart.y, drawCurrent.y),
            width: abs(drawCurrent.x - drawStart.x),
            height: abs(drawCurrent.y - drawStart.y)
        )

        if currentTool == .pen {
            if let temp = tempElement, temp.type == .pen {
                temp.path.append(p)
                temp.rect = boundingRect(for: temp.path)
            } else {
                tempElement = AnnotationElement(
                    type: .pen, rect: rect,
                    strokeColor: currentColor, lineWidth: currentLineWidth,
                    path: [drawStart, p]
                )
            }
        } else if currentTool == .arrow {
            tempElement = AnnotationElement(
                type: .arrow,
                rect: rect,
                strokeColor: currentColor,
                lineWidth: currentLineWidth,
                path: [drawStart, drawCurrent]
            )
        } else {
            tempElement = AnnotationElement(
                type: currentTool, rect: rect,
                strokeColor: currentColor, lineWidth: currentLineWidth
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingElement || isResizingElement {
            isDraggingElement = false
            isResizingElement = false
            resizeHandle = nil
            finishElementInteraction()
            return
        }

        guard isDrawing, let temp = tempElement else {
            isDrawing = false
            tempElement = nil
            return
        }

        isDrawing = false
        tempElement = nil

        // 最小尺寸过滤
        let minSize: CGFloat = currentTool == .arrow ? 5 : 3
        let size = NSSize(width: abs(temp.rect.width), height: abs(temp.rect.height))
        if size.width < minSize && size.height < minSize && currentTool != .pen { return }

        recordHistory()
        elements.append(temp)
        selectedIndex = elements.count - 1
        needsDisplay = true
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 1 { // Cmd+S
            commitPendingEdits()
            onSave?()
            return
        }
        switch event.keyCode {
        case 51, 117: // Delete / Forward Delete
            if selectedIndex >= 0 {
                recordHistory()
                elements.remove(at: selectedIndex)
                selectedIndex = -1
                needsDisplay = true
            }
        case 36, 76: // Enter / Keypad Enter
            onDone?()
        case 53: // Esc
            onCancel?()
        case 6: // Cmd+Z
            if event.modifierFlags.contains(.command) {
                event.modifierFlags.contains(.shift) ? redo() : undo()
            }
        default:
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishInlineTextEditing(commit: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = inlineTextField else { return }
        // 文本实际由 field editor 更新；放到下一轮 run loop 可确保拿到最新字符串，
        // 避免输入较快时尺寸落后一字符。
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, field === self.inlineTextField else { return }
            self.resizeInlineTextField(field)
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishInlineTextEditing(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishInlineTextEditing(commit: false)
            return true
        }
        return false
    }

    // MARK: - 撤销/重做

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        elements = clone(previous)
        selectedIndex = -1
        needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        elements = clone(next)
        selectedIndex = -1
        needsDisplay = true
    }

    // MARK: - 辅助方法

    private func elementAt(_ point: NSPoint) -> Int? {
        for (i, el) in elements.enumerated().reversed() {
            if el.rect.insetBy(dx: -4, dy: -4).contains(point) { return i }
        }
        return nil
    }

    private func handleAt(_ point: NSPoint, for rect: NSRect) -> ResizeHandle? {
        let handles: [(ResizeHandle, NSPoint)] = [
            (.bottomLeft, rect.origin),
            (.bottom, NSPoint(x: rect.midX, y: rect.minY)),
            (.bottomRight, NSPoint(x: rect.maxX, y: rect.minY)),
            (.right, NSPoint(x: rect.maxX, y: rect.midY)),
            (.topRight, NSPoint(x: rect.maxX, y: rect.maxY)),
            (.top, NSPoint(x: rect.midX, y: rect.maxY)),
            (.topLeft, NSPoint(x: rect.minX, y: rect.maxY)),
            (.left, NSPoint(x: rect.minX, y: rect.midY)),
        ]
        for (handle, handlePoint) in handles {
            if hypot(point.x - handlePoint.x, point.y - handlePoint.y) <= handleRadius + 4 {
                return handle
            }
        }
        return nil
    }

    private func resizedRect(from rect: NSRect, handle: ResizeHandle, point: NSPoint) -> NSRect {
        let minimum: CGFloat = 10
        var result = rect

        switch handle {
        case .topLeft, .left, .bottomLeft:
            result.origin.x = min(point.x, rect.maxX - minimum)
            result.size.width = rect.maxX - result.minX
        case .topRight, .right, .bottomRight:
            result.size.width = max(point.x - rect.minX, minimum)
        case .top, .bottom:
            break
        }

        switch handle {
        case .bottomLeft, .bottom, .bottomRight:
            result.origin.y = min(point.y, rect.maxY - minimum)
            result.size.height = rect.maxY - result.minY
        case .topLeft, .top, .topRight:
            result.size.height = max(point.y - rect.minY, minimum)
        case .left, .right:
            break
        }

        return result
    }

    private func snapshot() -> [AnnotationElement] {
        clone(elements)
    }

    private func clone(_ source: [AnnotationElement]) -> [AnnotationElement] {
        source.map { $0.copy() }
    }

    private func recordHistory() {
        undoStack.append(snapshot())
        redoStack.removeAll()
    }

    private func finishElementInteraction() {
        defer {
            interactionStartState = nil
            interactionDidChange = false
        }
        guard interactionDidChange, let previous = interactionStartState else { return }
        undoStack.append(previous)
        redoStack.removeAll()
    }

    private func boundingRect(for points: [NSPoint]) -> NSRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func updateElement(_ element: AnnotationElement, from oldRect: NSRect, to newRect: NSRect) {
        if (element.type == .pen || element.type == .arrow), !element.path.isEmpty {
            let scaleX = oldRect.width == 0 ? 1 : newRect.width / oldRect.width
            let scaleY = oldRect.height == 0 ? 1 : newRect.height / oldRect.height
            element.path = element.path.map { point in
                NSPoint(
                    x: newRect.minX + (point.x - oldRect.minX) * scaleX,
                    y: newRect.minY + (point.y - oldRect.minY) * scaleY
                )
            }
        }
        element.rect = newRect
    }

    private func beginInlineTextEditing(at point: NSPoint) {
        finishInlineTextEditing(commit: true)

        let availableWidth = max(80, bounds.maxX - point.x - 6)
        let width = min(220, availableWidth)
        let height: CGFloat = 30
        let origin = NSPoint(
            x: min(max(0, point.x), max(0, bounds.width - width)),
            y: min(max(0, point.y - 4), max(0, bounds.height - height))
        )
        inlineTextOrigin = origin

        let field = NSTextField(frame: NSRect(origin: origin, size: NSSize(width: width, height: height)))
        field.delegate = self
        field.font = NSFont.systemFont(ofSize: 18)
        field.textColor = currentColor
        field.backgroundColor = NSColor.white.withAlphaComponent(0.92)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = "输入文字，Enter 确认"
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        addSubview(field)
        inlineTextField = field
        window?.makeFirstResponder(field)
    }

    /// 输入框随内容横向扩展，到选区边缘后自动换行并向下/上增高。
    private func resizeInlineTextField(_ field: NSTextField) {
        let text = field.currentEditor()?.string ?? field.stringValue
        let font = field.font ?? NSFont.systemFont(ofSize: 18)
        let horizontalPadding: CGFloat = 14
        let verticalPadding: CGFloat = 8
        let minimumWidth: CGFloat = 120
        let maximumWidth = max(minimumWidth, bounds.maxX - inlineTextOrigin.x - 6)

        let singleLineSize = (text as NSString).size(withAttributes: [.font: font])
        let naturalWidth = max(minimumWidth, ceil(singleLineSize.width) + horizontalPadding)
        let wraps = naturalWidth > maximumWidth
        let width = wraps ? maximumWidth : naturalWidth
        let height: CGFloat
        if wraps {
            let contentWidth = max(20, width - horizontalPadding)
            let measured = (text as NSString).boundingRect(
                with: NSSize(width: contentWidth, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            height = max(30, ceil(measured.height) + verticalPadding)
        } else {
            height = 30
        }

        field.usesSingleLineMode = !wraps
        field.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        field.cell?.wraps = wraps
        field.cell?.isScrollable = !wraps

        // 优先保留用户点击的位置；触及右侧/顶部时向反方向扩展，保证内容始终可见。
        let origin = NSPoint(
            x: min(max(6, inlineTextOrigin.x), max(6, bounds.width - width - 6)),
            y: min(max(6, inlineTextOrigin.y), max(6, bounds.height - height - 6))
        )
        field.frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    private func finishInlineTextEditing(commit: Bool) {
        guard let field = inlineTextField else { return }
        resizeInlineTextField(field)
        inlineTextField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = field.textColor ?? currentColor
        let textRect = field.frame.insetBy(dx: 6, dy: 4)
        field.delegate = nil
        field.removeFromSuperview()

        if commit, !text.isEmpty {
            recordHistory()
            elements.append(AnnotationElement(
                type: .text,
                rect: textRect,
                strokeColor: color,
                text: text,
                fontSize: 18
            ))
            selectedIndex = elements.count - 1
            needsDisplay = true
        }

        window?.makeFirstResponder(self)
    }

    private func textAttributes(fontSize: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }
}
