import AppKit
import CoreGraphics

private func makeTestImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    for y in stride(from: 0, to: height, by: 8) {
        for x in stride(from: 0, to: width, by: 8) {
            let red = CGFloat(x) / CGFloat(width)
            let blue = CGFloat(y) / CGFloat(height)
            context.setFillColor(NSColor(red: red, green: 0.35, blue: blue, alpha: 1).cgColor)
            context.fill(CGRect(x: x, y: y, width: 8, height: 8))
        }
    }
    return context.makeImage()!
}

private func pixelData(_ image: CGImage) -> Data {
    let representation = NSBitmapImageRep(cgImage: image)
    return representation.representation(using: .png, properties: [:])!
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("失败：\(message)\n", stderr)
        exit(1)
    }
}

let source = makeTestImage(width: 160, height: 100)
let logicalSize = NSSize(width: 80, height: 50)
let region = NSRect(x: 15, y: 10, width: 38, height: 24)

let mosaic = ImageProcessing.effectRegion(
    from: source,
    logicalSize: logicalSize,
    rect: region,
    kind: .mosaic
)
let blur = ImageProcessing.effectRegion(
    from: source,
    logicalSize: logicalSize,
    rect: region,
    kind: .blur
)

require(mosaic != nil, "马赛克未生成图片")
require(blur != nil, "模糊未生成图片")
require(mosaic!.width == 76 && mosaic!.height == 48, "马赛克区域像素尺寸错误")
require(blur!.width == 76 && blur!.height == 48, "模糊区域像素尺寸错误")
require(pixelData(mosaic!) != pixelData(blur!), "马赛克与模糊结果意外相同")

let styled = ImageProcessing.applyStyle(
    to: source,
    cornerRadiusPoints: 8,
    hasShadow: true,
    scale: 2
)
require(styled != nil, "圆角阴影未生成图片")
require(styled!.width > source.width && styled!.height > source.height, "阴影输出没有透明边距")

let unchanged = ImageProcessing.applyStyle(
    to: source,
    cornerRadiusPoints: 0,
    hasShadow: false,
    scale: 2
)
require(unchanged === source, "无样式输出不应重新生成图片")

print("图像处理冒烟测试通过")
