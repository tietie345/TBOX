import AppKit
import Foundation

let size = NSSize(width: 720, height: 180)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 54, weight: .medium),
    .foregroundColor: NSColor.black,
]
"Hello OCR 123".draw(at: NSPoint(x: 28, y: 58), withAttributes: attributes)
image.unlockFocus()

guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("无法创建 OCR 测试图片")
}

let semaphore = DispatchSemaphore(value: 0)
var result: Result<String, Error>?
TextRecognitionService.shared.recognizeText(in: cgImage) {
    result = $0
    semaphore.signal()
}

while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

switch result {
case .success(let text):
    guard text.localizedCaseInsensitiveContains("Hello OCR"), text.contains("123") else {
        fatalError("OCR 结果不符合预期: \(text)")
    }
    print("TextRecognition smoke tests passed: \(text)")
case .failure(let error):
    fatalError("OCR 失败: \(error.localizedDescription)")
case .none:
    fatalError("OCR 没有返回结果")
}
