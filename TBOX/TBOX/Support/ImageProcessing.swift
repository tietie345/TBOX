import Cocoa

enum ImageEffectKind: Equatable {
    case mosaic
    case blur
}

enum ImageProcessing {
    static func effectRegion(
        from source: CGImage,
        logicalSize: NSSize,
        rect: NSRect,
        kind: ImageEffectKind
    ) -> CGImage? {
        guard logicalSize.width > 0, logicalSize.height > 0,
              rect.width > 0, rect.height > 0 else { return nil }

        let scaleX = CGFloat(source.width) / logicalSize.width
        let scaleY = CGFloat(source.height) / logicalSize.height
        let pixelRect = CGRect(
            x: rect.minX * scaleX,
            y: CGFloat(source.height) - rect.maxY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0,
              let region = source.cropping(to: pixelRect) else { return nil }

        switch kind {
        case .mosaic:
            let blockSize = max(8, Int((8 * max(scaleX, scaleY)).rounded()))
            let smallWidth = max(1, region.width / blockSize)
            let smallHeight = max(1, region.height / blockSize)
            guard let reduced = draw(
                region,
                width: smallWidth,
                height: smallHeight,
                interpolation: .none
            ) else { return nil }
            return draw(
                reduced,
                width: region.width,
                height: region.height,
                interpolation: .none
            )
        case .blur:
            let divisor = max(6, Int((6 * max(scaleX, scaleY)).rounded()))
            let smallWidth = max(1, region.width / divisor)
            let smallHeight = max(1, region.height / divisor)
            guard let reduced = draw(
                region,
                width: smallWidth,
                height: smallHeight,
                interpolation: .high
            ) else { return nil }
            return draw(
                reduced,
                width: region.width,
                height: region.height,
                interpolation: .high
            )
        }
    }

    private static func draw(
        _ image: CGImage,
        width: Int,
        height: Int,
        interpolation: CGInterpolationQuality
    ) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func applyStyle(
        to image: CGImage,
        cornerRadiusPoints: CGFloat,
        hasShadow: Bool,
        scale: CGFloat
    ) -> CGImage? {
        guard cornerRadiusPoints > 0 || hasShadow else { return image }

        let safeScale = max(1, scale)
        let radius = max(0, cornerRadiusPoints * safeScale)
        let padding = hasShadow ? Int(ceil(18 * safeScale)) : 0
        let outputWidth = image.width + padding * 2
        let outputHeight = image.height + padding * 2
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let imageRect = CGRect(x: padding, y: padding, width: image.width, height: image.height)
        let roundedPath = CGPath(
            roundedRect: imageRect,
            cornerWidth: min(radius, imageRect.width / 2),
            cornerHeight: min(radius, imageRect.height / 2),
            transform: nil
        )

        context.saveGState()
        if hasShadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -3 * safeScale),
                blur: 10 * safeScale,
                color: NSColor.black.withAlphaComponent(0.32).cgColor
            )
            context.addPath(roundedPath)
            context.setFillColor(NSColor.white.cgColor)
            context.fillPath()
        }
        context.restoreGState()

        context.saveGState()
        context.addPath(roundedPath)
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()
        return context.makeImage()
    }
}
