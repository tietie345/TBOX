import Cocoa
import UniformTypeIdentifiers

class ClipboardManager {
    static func copyImage(_ cgImage: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        pasteboard.writeObjects([nsImage])
    }

    static func saveImage(_ cgImage: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let ext = url.pathExtension.lowercased()
        let type: NSBitmapImageRep.FileType = ext == "jpg" || ext == "jpeg" ? .jpeg : .png
        let data = rep.representation(using: type, properties: [:])
        try? data?.write(to: url)
    }
    
    static func cropImage(_ cgImage: CGImage, to rect: NSRect, logicalSize: NSSize) -> CGImage? {
        guard rect.width > 0, rect.height > 0,
              logicalSize.width > 0, logicalSize.height > 0 else { return nil }

        // rect 是当前显示器的本地点坐标。按图像与显示器逻辑尺寸的实际比例换算，
        // 不假设所有显示器都使用相同的 1x/2x backingScaleFactor。
        let scaleX = CGFloat(cgImage.width) / logicalSize.width
        let scaleY = CGFloat(cgImage.height) / logicalSize.height
        let cropRect = CGRect(
            x: rect.origin.x * scaleX,
            y: CGFloat(cgImage.height) - (rect.origin.y + rect.height) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0 else { return nil }
        return cgImage.cropping(to: cropRect)
    }
}
