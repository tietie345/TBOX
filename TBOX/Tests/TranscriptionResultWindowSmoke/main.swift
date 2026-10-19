import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("失败：\(message)\n", stderr)
        exit(1)
    }
}

private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
}

_ = NSApplication.shared
let window = RecordingTranscriptionResultWindow()
let result = RecordingTranscriptionResult(
    audioURL: URL(fileURLWithPath: "/tmp/tbox-window-smoke.m4a"),
    duration: 18,
    text: "马路上有一根钢轨，到底是怎么不跑偏的？这种情况很常见。",
    segments: [
        RecordingTranscriptionSegment(
            start: 8,
            end: 13,
            text: "马路上有一根钢轨，到底是怎么不跑偏的？",
            speakerName: "我"
        ),
        RecordingTranscriptionSegment(
            start: 13,
            end: 18,
            text: "这种情况很常见。",
            speakerName: "我"
        ),
    ]
)
window.present(result: result)

guard let contentView = window.contentView,
      let textView = descendants(of: contentView).compactMap({ $0 as? NSTextView }).first else {
    fatalError("结果窗口中找不到文本视图")
}
textView.layoutManager?.ensureLayout(for: textView.textContainer!)
let usedHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0

require(textView.frame.width > 100 && textView.frame.height > 100, "文本视图仍然没有可绘制尺寸：\(textView.frame)")
require(textView.string.contains("马路上有一根钢轨"), "逐句文本没有写入结果窗口")
require(textView.string.contains("我  ·  00:08"), "逐句视图没有显示说话人和时间戳")
require(usedHeight > 20, "TextKit 没有生成可见文本布局")

window.presentTranscribing(audioURL: result.audioURL, duration: 90)
window.updatePartial(result: result)
window.updateProgress(RecordingTranscriptionProgress(completedChunks: 1, totalChunks: 2))
let progress = descendants(of: contentView).compactMap { $0 as? NSProgressIndicator }.first!
require(!progress.isHidden && !progress.isIndeterminate && progress.doubleValue == 0.5, "转写进度未显示 50%")
require(!textView.isEditable && textView.string.contains("马路上"), "处理中应显示只读的部分结果")
window.orderOut(nil)
window.makeKeyAndOrderFront(nil)
require(progress.doubleValue == 0.5, "关闭重开不应重置进度")
window.present(result: result)
require(progress.isHidden && textView.isEditable, "转写完成后应隐藏进度并恢复编辑")

print("Transcription result window smoke tests passed")
if ProcessInfo.processInfo.environment["TBOX_UI_HOLD"] == "1" {
    NSApplication.shared.run()
} else {
    window.orderOut(nil)
}
