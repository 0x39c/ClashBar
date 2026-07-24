import AppKit

@MainActor
final class StatusItemImageRenderer {
    private let statusItemHorizontalPadding: CGFloat = 0
    private let iconSize: CGFloat = 24
    private let brandIconRenderSize: CGFloat = 24
    private let symbolPointSize: CGFloat = 20
    private let iconTextSpacing: CGFloat = 0
    private let textContainerWidth: CGFloat = 38
    private let textLineHeight: CGFloat = 11
    private let pendingBadgeSpacing: CGFloat = 1
    private let pendingBadgeMinWidth: CGFloat = 14
    private let pendingBadgeHeight: CGFloat = 13
    private let pendingBadgeHorizontalPadding: CGFloat = 4
    private let pendingBadgeFont = NSFont.systemFont(ofSize: 9, weight: .bold)

    private lazy var ruleBrandStatusIconImage: NSImage? = Self.makeBrandStatusIconImage(
        source: BrandIcon.runProxyImage,
        size: brandIconRenderSize,
        insetRatio: 0.14,
        preservesSourceCanvas: true)
    private lazy var runBrandStatusIconImage: NSImage? = Self.makeBrandStatusIconImage(
        source: BrandIcon.runProxyImage,
        size: brandIconRenderSize,
        preservesSourceCanvas: true)
    private lazy var sleepBrandStatusIconImage: NSImage? = Self.makeBrandStatusIconImage(
        source: BrandIcon.sleepImage,
        size: brandIconRenderSize)
    private lazy var globalBrandStatusIconImage: NSImage? = Self.makeGlyphStatusIconImage(
        glyph: "",
        size: brandIconRenderSize)
    private lazy var directBrandStatusIconImage: NSImage? = Self.makeGlyphStatusIconImage(
        glyph: "",
        size: brandIconRenderSize)
    private static let renderScales: [CGFloat] = [1, 2, 3]

    func image(for display: MenuBarDisplay) -> NSImage {
        let pointSize = NSSize(
            width: self.requiredWidth(for: display),
            height: self.iconSize)
        let image = NSImage(size: pointSize)

        for scale in Self.renderScales {
            guard let representation = self.makeRepresentation(
                for: display,
                pointSize: pointSize,
                scale: scale)
            else {
                continue
            }
            image.addRepresentation(representation)
        }

        image.isTemplate = true
        return image
    }

    func requiredWidth(for display: MenuBarDisplay) -> CGFloat {
        let badgeText = Self.pendingBadgeText(for: display.pendingCount)
        let badgeAddition = badgeText.isEmpty
            ? 0
            : self.pendingBadgeSpacing + self.pendingBadgeWidth(text: badgeText)

        switch display.mode {
        case .iconOnly:
            return self.statusItemHorizontalPadding * 2 + self.iconSize + badgeAddition
        case .iconAndSpeed:
            return self.statusItemHorizontalPadding * 2
                + self.iconSize
                + badgeAddition
                + self.iconTextSpacing
                + self.textContainerWidth
        case .speedOnly:
            return self.statusItemHorizontalPadding * 2 + self.textContainerWidth + badgeAddition
        }
    }

    private func makeRepresentation(
        for display: MenuBarDisplay,
        pointSize: NSSize,
        scale: CGFloat) -> NSBitmapImageRep?
    {
        guard let representation = Self.makeBitmapRepresentation(pointSize: pointSize, scale: scale),
              let context = NSGraphicsContext(bitmapImageRep: representation)
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let centerY = floor(pointSize.height / 2)
        let badgeText = Self.pendingBadgeText(for: display.pendingCount)
        let badgeWidth = badgeText.isEmpty ? 0 : self.pendingBadgeWidth(text: badgeText)
        let badgeAddition = badgeText.isEmpty ? 0 : badgeWidth + self.pendingBadgeSpacing

        if display.mode != .speedOnly {
            let iconRect = NSRect(
                x: floor(self.statusItemHorizontalPadding),
                y: floor(centerY - self.iconSize / 2),
                width: self.iconSize,
                height: self.iconSize)
            self.statusIconImage(for: display)?.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil)
        }

        if !badgeText.isEmpty {
            let badgeOriginX: CGFloat = switch display.mode {
            case .iconOnly, .iconAndSpeed:
                self.statusItemHorizontalPadding + self.iconSize + self.pendingBadgeSpacing
            case .speedOnly:
                self.statusItemHorizontalPadding + self.textContainerWidth + self.pendingBadgeSpacing
            }
            let badgeRect = NSRect(
                x: floor(badgeOriginX),
                y: floor(centerY - self.pendingBadgeHeight / 2),
                width: badgeWidth,
                height: self.pendingBadgeHeight)
            self.drawPendingBadge(text: badgeText, in: badgeRect)
        }

        if display.mode != .iconOnly {
            let speedOriginX = floor(
                self.statusItemHorizontalPadding
                    + (display.mode == .iconAndSpeed
                        ? self.iconSize + badgeAddition + self.iconTextSpacing
                        : 0))
            self.drawSpeedLines(
                display.speedLines ?? .zero,
                in: NSRect(
                    x: speedOriginX,
                    y: floor(centerY - self.textLineHeight),
                    width: self.textContainerWidth,
                    height: self.textLineHeight * 2))
        }

        // Template images use alpha as their mask. Normalize all source images
        // to black while preserving the badge background's lower alpha.
        context.cgContext.setBlendMode(.sourceIn)
        context.cgContext.setFillColor(NSColor.black.cgColor)
        context.cgContext.fill(NSRect(origin: .zero, size: pointSize))

        NSGraphicsContext.restoreGraphicsState()
        return representation
    }

    private func drawSpeedLines(_ lines: MenuBarSpeedLines, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingHead
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]

        // The bitmap context is not flipped, so the upload line is on top.
        (lines.up as NSString).draw(
            in: NSRect(
                x: rect.minX,
                y: rect.minY + self.textLineHeight,
                width: rect.width,
                height: self.textLineHeight),
            withAttributes: attributes)
        (lines.down as NSString).draw(
            in: NSRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: self.textLineHeight),
            withAttributes: attributes)
    }

    private func drawPendingBadge(text: String, in rect: NSRect) {
        NSColor.black.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: self.pendingBadgeFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let textHeight = ceil((text as NSString).size(withAttributes: attributes).height)
        (text as NSString).draw(
            in: NSRect(
                x: rect.minX,
                y: floor(rect.midY - textHeight / 2),
                width: rect.width,
                height: textHeight),
            withAttributes: attributes)
    }

    private static func pendingBadgeText(for count: Int) -> String {
        guard count > 0 else { return "" }
        return count > 99 ? "99+" : "\(count)"
    }

    private func pendingBadgeWidth(text: String) -> CGFloat {
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: self.pendingBadgeFont]).width)
        return max(self.pendingBadgeMinWidth, textWidth + self.pendingBadgeHorizontalPadding * 2)
    }

    private func statusIconImage(for display: MenuBarDisplay) -> NSImage? {
        if let brandIcon = self.brandStatusIconImage(display: display) {
            return brandIcon
        }
        guard let symbolName = display.symbolName else { return nil }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClashBar")
        let configuration = NSImage.SymbolConfiguration(
            pointSize: self.symbolPointSize,
            weight: .semibold)
        return image?.withSymbolConfiguration(configuration)
    }

    private func brandStatusIconImage(display: MenuBarDisplay) -> NSImage? {
        guard display.isRunning else {
            return self.sleepBrandStatusIconImage
        }

        switch display.symbolName {
        case "globe":
            return self.globalBrandStatusIconImage ?? self.runBrandStatusIconImage
        case "bolt.fill":
            return self.directBrandStatusIconImage ?? self.runBrandStatusIconImage
        default:
            return self.ruleBrandStatusIconImage ?? self.runBrandStatusIconImage
        }
    }

    private static func makeBitmapRepresentation(
        pointSize: NSSize,
        scale: CGFloat) -> NSBitmapImageRep?
    {
        let pixelWidth = max(1, Int((pointSize.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((pointSize.height * scale).rounded(.up)))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return nil
        }
        representation.size = pointSize
        return representation
    }

    private static func makeBrandStatusIconImage(
        source: NSImage?,
        size: CGFloat,
        insetRatio: CGFloat = 0.18,
        preservesSourceCanvas: Bool = false) -> NSImage?
    {
        guard let source else { return nil }
        let targetSize = NSSize(width: size, height: size)
        let rendered = NSImage(size: targetSize)

        for scale in Self.renderScales {
            guard let representation = self.makeBrandStatusIconRepresentation(
                source: source,
                pointSize: targetSize,
                insetRatio: insetRatio,
                preservesSourceCanvas: preservesSourceCanvas,
                scale: scale)
            else {
                continue
            }
            rendered.addRepresentation(representation)
        }

        guard !rendered.representations.isEmpty else { return nil }
        rendered.isTemplate = true
        return rendered
    }

    private static func makeGlyphStatusIconImage(glyph: String, size: CGFloat) -> NSImage? {
        let targetSize = NSSize(width: size, height: size)
        let fontNames = [
            "Maple Mono NF CN",
            "Maple Mono NF CN Regular",
            "Maple Mono NF CN Medium",
        ]

        for fontName in fontNames {
            guard let font = NSFont(name: fontName, size: size * 0.60) else { continue }
            let image = NSImage(size: targetSize)
            for scale in Self.renderScales {
                guard let representation = self.makeBitmapRepresentation(
                    pointSize: targetSize,
                    scale: scale),
                    let context = NSGraphicsContext(bitmapImageRep: representation)
                else {
                    continue
                }

                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.imageInterpolation = .high

                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: paragraph,
                ]
                (glyph as NSString).draw(
                    in: NSRect(
                        x: size * 0.04,
                        y: size * 0.13,
                        width: size * 0.80,
                        height: size * 0.80),
                    withAttributes: attributes)

                NSGraphicsContext.restoreGraphicsState()
                image.addRepresentation(representation)
            }
            guard !image.representations.isEmpty else { continue }
            image.isTemplate = true
            return image
        }

        return nil
    }

    private static func makeBrandStatusIconRepresentation(
        source: NSImage,
        pointSize: NSSize,
        insetRatio: CGFloat,
        preservesSourceCanvas: Bool,
        scale: CGFloat) -> NSBitmapImageRep?
    {
        guard let representation = self.makeBitmapRepresentation(
            pointSize: pointSize,
            scale: scale),
            let context = NSGraphicsContext(bitmapImageRep: representation)
        else {
            return nil
        }

        let sourceRect = preservesSourceCanvas
            ? NSRect(origin: .zero, size: source.size)
            : self.trimmedOpaqueRect(for: source)
        let destinationRect = self.fittedBrandIconRect(
            sourceRect: sourceRect,
            pointSize: pointSize,
            insetRatio: insetRatio)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: destinationRect,
            from: sourceRect,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil)
        context.cgContext.setBlendMode(.sourceIn)
        context.cgContext.setFillColor(NSColor.black.cgColor)
        context.cgContext.fill(NSRect(origin: .zero, size: pointSize))
        NSGraphicsContext.restoreGraphicsState()
        return representation
    }

    private static func fittedBrandIconRect(
        sourceRect: NSRect,
        pointSize: NSSize,
        insetRatio: CGFloat) -> NSRect
    {
        guard sourceRect.width > 0, sourceRect.height > 0 else {
            return NSRect(origin: .zero, size: pointSize)
        }

        let availableWidth = pointSize.width * (1 - insetRatio * 2)
        let availableHeight = pointSize.height * (1 - insetRatio * 2)
        let scale = min(availableWidth / sourceRect.width, availableHeight / sourceRect.height)
        let width = sourceRect.width * scale
        let height = sourceRect.height * scale
        return NSRect(
            x: (pointSize.width - width) / 2,
            y: (pointSize.height - height) / 2,
            width: width,
            height: height)
    }

    private static func trimmedOpaqueRect(for source: NSImage) -> NSRect {
        guard let tiff = source.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return NSRect(origin: .zero, size: source.size)
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent <= 0.01 { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return NSRect(origin: .zero, size: source.size)
        }

        let scaleX = source.size.width / CGFloat(width)
        let scaleY = source.size.height / CGFloat(height)
        return NSRect(
            x: CGFloat(minX) * scaleX,
            y: CGFloat(minY) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY)
    }
}
