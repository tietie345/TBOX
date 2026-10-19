import Cocoa

// MARK: - 标注工具类型

enum AnnotationToolType: CaseIterable {
    case rect       // 矩形
    case arrow      // 箭头
    case pen        // 画笔
    case text       // 文字
    case mosaic     // 马赛克
    case number     // 序号
    case highlight  // 高亮
    case blur       // 模糊

    var icon: String {
        switch self {
        case .rect:      return "rectangle"
        case .arrow:     return "arrow.up.right"
        case .pen:       return "scribble"
        case .text:      return "textformat"
        case .mosaic:    return "square.grid.3x3"
        case .number:    return "1.circle"
        case .highlight: return "highlighter"
        case .blur:      return "eyeglasses"
        }
    }

    var tooltip: String {
        switch self {
        case .rect:      return "矩形"
        case .arrow:     return "箭头"
        case .pen:       return "画笔"
        case .text:      return "文字"
        case .mosaic:    return "马赛克"
        case .number:    return "序号"
        case .highlight: return "高亮"
        case .blur:      return "模糊"
        }
    }
}

// MARK: - 标注元素

class AnnotationElement {
    var type: AnnotationToolType
    var rect: NSRect          // 元素包围盒（本地坐标）
    var strokeColor: NSColor
    var fillColor: NSColor
    var lineWidth: CGFloat
    var text: String          // 文字/序号内容
    var path: [NSPoint]       // 画笔路径（画布坐标）
    var fontSize: CGFloat

    init(type: AnnotationToolType, rect: NSRect,
         strokeColor: NSColor = .systemRed,
         fillColor: NSColor = .clear,
         lineWidth: CGFloat = 3,
         text: String = "",
         path: [NSPoint] = [],
         fontSize: CGFloat = 18) {
        self.type = type
        self.rect = rect
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.text = text
        self.path = path
        self.fontSize = fontSize
    }

    func copy() -> AnnotationElement {
        AnnotationElement(
            type: type,
            rect: rect,
            strokeColor: strokeColor,
            fillColor: fillColor,
            lineWidth: lineWidth,
            text: text,
            path: path,
            fontSize: fontSize
        )
    }
}
