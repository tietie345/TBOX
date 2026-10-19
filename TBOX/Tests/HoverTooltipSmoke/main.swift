import AppKit
import Foundation

let application = NSApplication.shared
guard let screen = NSScreen.main else {
    fatalError("没有可用屏幕")
}

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
let overlay = OverlayView(frame: window.contentView!.bounds, screen: screen)
window.contentView = overlay

guard let toolbar = overlay.subviews.compactMap({ $0 as? CaptureToolbar }).first else {
    fatalError("找不到截图工具栏")
}
toolbar.isHidden = false
let toolbarSize = toolbar.calcFittingSize()
toolbar.frame = NSRect(x: 120, y: 120, width: toolbarSize.width, height: toolbarSize.height)
toolbar.layoutButtons()

let buttons = toolbar.subviews.compactMap { $0 as? HoverTrackingButton }
let expectedTexts = [
    "标注", "画笔", "文字", "录制选区", "录音转写", "提取框选区域文字",
    "翻译框选区域文字", "贴图", "保存", "复制", "取消",
]
guard buttons.count == expectedTexts.count else {
    fatalError("功能按钮数量异常: \(buttons.count)")
}
guard let bubble = overlay.subviews.compactMap({ $0 as? HoverTooltipView }).first else {
    fatalError("找不到提示浮层")
}

for (index, button) in buttons.enumerated() {
    let expectedText = expectedTexts[index]
    guard button.toolTip == expectedText else {
        fatalError("按钮 \(index) 中文名称异常: \(button.toolTip ?? "nil")")
    }
    let buttonCenter = toolbar.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: overlay)
    guard let event = NSEvent.mouseEvent(
        with: .mouseMoved,
        location: buttonCenter,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: index + 1,
        clickCount: 0,
        pressure: 0
    ) else {
        fatalError("无法创建按钮 \(index) 的鼠标事件")
    }

    button.mouseEntered(with: event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.42))
    guard !bubble.isHidden, bubble.text == expectedText else {
        fatalError("按钮 \(index) 的中文提示没有显示: \(expectedText)")
    }
    button.mouseExited(with: event)
    guard bubble.isHidden else {
        fatalError("按钮 \(index) 离开后提示没有隐藏")
    }
}

print("Hover tooltip smoke tests passed: \(expectedTexts.joined(separator: ", "))")
_ = application
