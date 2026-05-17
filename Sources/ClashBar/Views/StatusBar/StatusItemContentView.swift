import AppKit

final class StatusItemContentView: NSView {
    // No horizontal padding; icon and text sit flush against each other.
    private let statusItemHorizontalPadding: CGFloat = 0
    private let iconSize: CGFloat = 24
    private let brandIconRenderSize: CGFloat = 24
    private let symbolPointSize: CGFloat = 20
    private let iconTextSpacing: CGFloat = 0
    // Keep a small buffer so values like "12.3M↑" do not clip in the menu bar.
    private let textContainerWidth: CGFloat = 38
    private let textLineHeight: CGFloat = 11

    private let iconView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = true
        return imageView
    }()

    private let speedImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = true
        return imageView
    }()

    private var currentDisplay: MenuBarDisplay?
    private var cachedUpLine: String = ""
    private var cachedDownLine: String = ""
    private lazy var runBrandStatusIconImage: NSImage? = Self.makeGlyphStatusIconImage(
        glyph: "", size: brandIconRenderSize)
    private lazy var sleepBrandStatusIconImage: NSImage? = Self.makeBrandStatusIconImage(
        source: BrandIcon.sleepImage, size: brandIconRenderSize)
    private lazy var globalBrandStatusIconImage: NSImage? = Self.makeGlyphStatusIconImage(
        glyph: "", size: brandIconRenderSize)
    private lazy var directBrandStatusIconImage: NSImage? = Self.makeGlyphStatusIconImage(
        glyph: "", size: brandIconRenderSize)
    private static let brandIconRenderScales: [CGFloat] = [1, 2, 3]

    var usesBrandIcon: Bool {
        self.runBrandStatusIconImage != nil ||
            self.sleepBrandStatusIconImage != nil ||
            self.globalBrandStatusIconImage != nil ||
            self.directBrandStatusIconImage != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        self.addSubview(self.iconView)
        self.addSubview(self.speedImageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var intrinsicContentSize: NSSize {
        CGSize(width: self.requiredWidth, height: NSStatusBar.system.thickness)
    }

    var requiredWidth: CGFloat {
        let display = self.currentDisplay ?? MenuBarDisplay(
            mode: .iconOnly,
            symbolName: nil,
            speedLines: nil,
            isRunning: false)
        switch display.mode {
        case .iconOnly:
            return self.statusItemHorizontalPadding * 2 + self.iconSize
        case .iconAndSpeed:
            return self.statusItemHorizontalPadding * 2 + self.iconSize + self.iconTextSpacing + self.textContainerWidth
        case .speedOnly:
            return self.statusItemHorizontalPadding * 2 + self.textContainerWidth
        }
    }

    func apply(display: MenuBarDisplay) {
        let previousMode = self.currentDisplay?.mode
        let previousSymbolName = self.currentDisplay?.symbolName
        let previousIconHidden = self.iconView.isHidden
        let previousUpLine = self.cachedUpLine
        let previousDownLine = self.cachedDownLine

        self.currentDisplay = display
        self.cachedUpLine = display.speedLines?.up ?? ""
        self.cachedDownLine = display.speedLines?.down ?? ""

        let shouldShowIcon = display.mode != .speedOnly
        if shouldShowIcon, let brandIcon = self.brandStatusIconImage(display: display) {
            if self.iconView.image !== brandIcon {
                self.iconView.image = brandIcon
            }
        } else if let symbolName = display.symbolName, shouldShowIcon {
            if self.iconView.image == nil ||
                previousSymbolName != symbolName ||
                self.currentDisplay?.mode != previousMode
            {
                let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClashBar")
                let config = NSImage.SymbolConfiguration(pointSize: self.symbolPointSize, weight: .semibold)
                self.iconView.image = image?.withSymbolConfiguration(config)
            }
        } else {
            self.iconView.image = nil
        }

        switch display.mode {
        case .iconOnly:
            self.iconView.isHidden = false
            self.speedImageView.isHidden = true
        case .iconAndSpeed:
            self.iconView.isHidden = false
            self.speedImageView.isHidden = false
        case .speedOnly:
            self.iconView.isHidden = true
            self.speedImageView.isHidden = false
        }

        let modeChanged = previousMode != display.mode
        let iconVisibilityChanged = previousIconHidden != self.iconView.isHidden
        let speedTextChanged = previousUpLine != self.cachedUpLine || previousDownLine != self.cachedDownLine

        if speedTextChanged || modeChanged, display.mode != .iconOnly {
            self.speedImageView.image = self.makeSpeedTemplateImage(
                upLine: self.cachedUpLine, downLine: self.cachedDownLine)
        }

        if modeChanged || iconVisibilityChanged {
            self.needsLayout = true
        }
        if modeChanged {
            self.invalidateIntrinsicContentSize()
        }
    }

    override func layout() {
        super.layout()

        let totalHeight = bounds.height
        let centerY = floor(totalHeight / 2)
        let iconOriginX = floor(self.statusItemHorizontalPadding)

        if self.iconView.isHidden == false {
            self.iconView.frame = CGRect(
                x: iconOriginX,
                y: floor(centerY - self.iconSize / 2),
                width: self.iconSize,
                height: self.iconSize)
        } else {
            self.iconView.frame = .zero
        }

        if self.speedImageView.isHidden == false {
            let originX = floor(
                self.statusItemHorizontalPadding +
                    ((self.currentDisplay?.mode == .iconAndSpeed) ? (self.iconSize + self.iconTextSpacing) : 0))
            let stackHeight = self.textLineHeight * 2
            let stackOriginY = floor(centerY - stackHeight / 2)
            self.speedImageView.frame = CGRect(
                x: originX,
                y: stackOriginY,
                width: self.textContainerWidth,
                height: stackHeight)
        } else {
            self.speedImageView.frame = .zero
        }
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
            return self.runBrandStatusIconImage
        }
    }

    private func makeSpeedTemplateImage(upLine: String, downLine: String) -> NSImage {
        let width = self.textContainerWidth
        let height = self.textLineHeight * 2
        let pointSize = NSSize(width: width, height: height)

        let image = NSImage(size: pointSize)
        for scale in Self.brandIconRenderScales {
            guard let rep = Self.makeSpeedTextRepresentation(
                upLine: upLine,
                downLine: downLine,
                pointSize: pointSize,
                textLineHeight: self.textLineHeight,
                scale: scale)
            else { continue }
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    private static func makeSpeedTextRepresentation(
        upLine: String,
        downLine: String,
        pointSize: NSSize,
        textLineHeight: CGFloat,
        scale: CGFloat) -> NSBitmapImageRep?
    {
        let pixelWidth = max(1, Int((pointSize.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((pointSize.height * scale).rounded(.up)))

        guard let rep = NSBitmapImageRep(
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
        else { return nil }

        rep.size = pointSize
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingHead
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]

        // Non-flipped context: y=0 is bottom.
        let upRect = CGRect(x: 0, y: textLineHeight, width: pointSize.width, height: textLineHeight)
        let downRect = CGRect(x: 0, y: 0, width: pointSize.width, height: textLineHeight)

        (upLine as NSString).draw(in: upRect, withAttributes: attributes)
        (downLine as NSString).draw(in: downRect, withAttributes: attributes)

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func makeBrandStatusIconImage(source: NSImage?, size: CGFloat) -> NSImage? {
        guard let source else { return nil }
        let targetSize = NSSize(width: size, height: size)
        let rendered = NSImage(size: targetSize)

        for scale in Self.brandIconRenderScales {
            guard let representation = self.makeBrandStatusIconRepresentation(
                source: source,
                pointSize: targetSize,
                scale: scale)
            else {
                continue
            }
            rendered.addRepresentation(representation)
        }

        guard rendered.representations.isEmpty == false else { return nil }
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
            for scale in Self.brandIconRenderScales {
                let pixelWidth = max(1, Int((targetSize.width * scale).rounded(.up)))
                let pixelHeight = max(1, Int((targetSize.height * scale).rounded(.up)))
                guard let rep = NSBitmapImageRep(
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
                else { continue }
                rep.size = targetSize
                guard let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }

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
                let rect = CGRect(
                    x: size * 0.04,
                    y: size * 0.13,
                    width: size * 0.80,
                    height: size * 0.80)
                (glyph as NSString).draw(in: rect, withAttributes: attributes)

                NSGraphicsContext.restoreGraphicsState()
                image.addRepresentation(rep)
            }
            guard image.representations.isEmpty == false else { continue }
            image.isTemplate = true
            return image
        }

        return nil
    }

    private static func makeBrandStatusIconRepresentation(
        source: NSImage,
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

        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return nil
        }

        let trimmedSourceRect = self.trimmedOpaqueRect(for: source)
        let destinationRect = self.fittedBrandIconRect(sourceRect: trimmedSourceRect, pointSize: pointSize)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: destinationRect,
            from: trimmedSourceRect,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil)
        context.cgContext.setBlendMode(.sourceIn)
        context.cgContext.setFillColor(NSColor.black.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: pointSize))
        NSGraphicsContext.restoreGraphicsState()
        return representation
    }

    private static func fittedBrandIconRect(sourceRect: NSRect, pointSize: NSSize) -> NSRect {
        guard sourceRect.width > 0, sourceRect.height > 0 else {
            return NSRect(origin: .zero, size: pointSize)
        }

        let insetRatio: CGFloat = 0.18
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
