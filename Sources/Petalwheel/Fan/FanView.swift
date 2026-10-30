import AppKit

/// Shared colours and fonts of the fan. The fan is dark glass in both appearances,
/// so it uses the fixed dark variants of the Grove palette.
enum FanStyle {
    static let accent = NSColor(srgbRed: 0.25, green: 0.45, blue: 0.94, alpha: 1) // NurTo mint
    static let peel = KQPalette.Dark.peel               // #B8520E
    static let glass = NSColor.white
    static let centerDisc = NSColor.white
    static let ink = KQPalette.Dark.ink                 // text/icons on coloured fills
    static let text = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.22, alpha: 1)               // text on glass
    static let textSecondary = NSColor(srgbRed: 0.39, green: 0.44, blue: 0.51, alpha: 1)
    /// Width of the coloured rim on the outer edge of an unhighlighted petal.
    static let rimWidth: CGFloat = 2.5

    /// Colour of a petal: categories use their own colour, presets Driftwood, everything else `tint`.
    static func color(for item: FanItem, tint: NSColor?) -> NSColor { accent }

    /// `color` lightened towards white by `amount` (0…1).
    static func lighter(_ color: NSColor, _ amount: CGFloat) -> NSColor {
        color.usingColorSpace(.sRGB)?.blended(withFraction: amount, of: .white) ?? color
    }

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }
}

/// Draws the donut of petals plus the centre, and handles hit testing, hover, clicks and file drops.
final class FanView: NSView {
    // Content
    var mode: FanMode = .conversions
    private(set) var items: [FanItem] = []
    private(set) var layout = FanLayout(count: 0, hasSymbols: false)
    var message: String? { didSet { needsDisplay = true } }
    var thumbnail: NSImage? { didSet { needsDisplay = true } }
    var isIconThumbnail = true
    var fileCount = 0 { didSet { needsDisplay = true } }
    var clickEnabled = false
    var captureDrops = false
    private var clickArmed = false
    /// Colour of the open category; nil at the root, where each category petal uses its own colour.
    var tint: NSColor? { didSet { needsDisplay = true } }

    private(set) var highlighted: Int?

    // Callbacks (main thread)
    var onHighlightChange: ((Int?) -> Void)?
    var onDrop: ((Int, [URL]) -> Void)?
    var onClick: ((Int) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Cursor entered/left the centre circle (drag or hover). Used for "back" navigation.
    var onCenterHoverChange: ((Bool) -> Void)?
    /// Centre clicked (click mode).
    var onCenterClick: (() -> Void)?
    /// Replaces the mode hint in the centre (e.g. the open category's title).
    var hintOverride: String? { didSet { needsDisplay = true } }
    /// When true, hovering the centre shows "‹ Back".
    var canGoBack = false { didSet { needsDisplay = true } }
    private(set) var isCenterHovered = false

    private var petalPaths: [CGPath] = []
    private var grownPaths: [Int: CGPath] = [:]
    private var trackingArea: NSTrackingArea?
    private var accessibilityPetals: [PetalAccessibilityElement] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    func configure(mode: FanMode, items: [FanItem]) {
        self.mode = mode
        self.items = items
        self.layout = FanLayout(count: items.count, hasSymbols: items.contains { $0.symbol != nil })
        self.highlighted = nil
        rebuildPaths()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildPaths()
    }

    private func rebuildPaths() {
        let c = center
        petalPaths = layout.petals.map { FanLayout.path(for: $0, center: c) }
        grownPaths = [:]
        rebuildAccessibility()
    }

    /// Union of all glass shapes (petals + centre) for masking the blur and the shadow.
    func glassShape() -> CGPath {
        let p = CGMutablePath()
        for path in petalPaths { p.addPath(path) }
        let r = layout.centerRadius
        let c = center
        p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        return p
    }

    // MARK: Highlight

    func setHighlighted(_ index: Int?) {
        guard index != highlighted else { return }
        highlighted = index
        needsDisplay = true
        onHighlightChange?(index)
    }

    /// Sets the highlight without sound/haptic feedback.
    func setHighlightedSilently(_ index: Int?) {
        guard index != highlighted else { return }
        highlighted = index
        needsDisplay = true
    }

    func isInCenter(windowPoint p: NSPoint) -> Bool {
        let local = convert(p, from: nil)
        return hypot(local.x - center.x, local.y - center.y) <= layout.centerRadius
    }

    private func updateCenterHover(_ p: NSPoint?) {
        let inside = p.map(isInCenter(windowPoint:)) ?? false
        guard inside != isCenterHovered else { return }
        isCenterHovered = inside
        needsDisplay = true
        onCenterHoverChange?(inside)
    }

    func petalIndex(atWindowPoint p: NSPoint) -> Int? {
        let local = convert(p, from: nil)
        return layout.petalIndex(at: CGPoint(x: local.x - center.x, y: local.y - center.y))
    }

    /// True when the window point lies on the drawn donut or centre (for "click outside" detection).
    func isOnFan(windowPoint p: NSPoint) -> Bool {
        let local = convert(p, from: nil)
        let r = hypot(local.x - center.x, local.y - center.y)
        return r <= layout.centerRadius || petalIndex(atWindowPoint: p) != nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = center
        for (i, petal) in layout.petals.enumerated() where i < items.count {
            if i == highlighted { continue }
            drawPetal(ctx, petal: petal, path: petalPaths[i], item: items[i], highlighted: false)
        }
        if let h = highlighted, h < layout.petals.count, h < items.count {
            let path = grownPaths[h] ?? FanLayout.path(for: layout.petals[h], center: c, grow: FanLayout.highlightGrow)
            grownPaths[h] = path
            drawPetal(ctx, petal: layout.petals[h], path: path, item: items[h], highlighted: true)
        }
        drawCenter(ctx)
    }

    private func drawGlassFill(_ ctx: CGContext, path: CGPath, rect: CGRect, fill: NSColor? = nil) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        // Warm graphite tint so the glass reads well over any wallpaper, plus a soft top sheen.
        ctx.setFillColor((fill ?? FanStyle.glass.withAlphaComponent(0.48)).cgColor)
        ctx.fill(rect)
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [NSColor(white: 1, alpha: 0.035).cgColor, NSColor(white: 1, alpha: 0.01).cgColor] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    private func strokeInside(_ ctx: CGContext, path: CGPath, color: NSColor, width: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width * 2)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawPetal(_ ctx: CGContext, petal: FanLayout.Petal, path: CGPath, item: FanItem, highlighted: Bool) {
        let box = path.boundingBoxOfPath
        let color = FanStyle.color(for: item, tint: tint)
        if highlighted {
            drawGlassFill(ctx, path: path, rect: box, fill: NSColor(white: 1, alpha: 0.9))
            strokeInside(ctx, path: path, color: color, width: 1.6)
        } else {
            drawGlassFill(ctx, path: path, rect: box)
            strokeInside(ctx, path: path, color: NSColor(white: 1, alpha: 0.8), width: 0.7)
        }
        let textColor = FanStyle.text
        let iconColor = highlighted ? color : FanStyle.textSecondary

        let lc = petal.labelCenter(center)
        let maxW = petal.labelWidth
        if let symbol = item.symbol {
            let symbolSize: CGFloat = petal.outer - petal.inner >= 58 ? 20 : 16
            let lines = captionLines(item.title, maxWidth: maxW, color: textColor)
            let lineSizes = lines.map { $0.size() }
            let capHeight = lineSizes.reduce(0) { $0 + $1.height } - CGFloat(max(0, lines.count - 1)) * 2
            let config = NSImage.SymbolConfiguration(pointSize: lines.count > 1 ? symbolSize - 2 : symbolSize, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [iconColor]))
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title)?.withSymbolConfiguration(config)
            let s = img?.size ?? .zero
            let spacing: CGFloat = img == nil ? 0 : 3
            let total = s.height + spacing + capHeight
            if let img {
                img.draw(in: CGRect(x: lc.x - s.width / 2, y: lc.y + total / 2 - s.height, width: s.width, height: s.height))
            }
            var y = lc.y + total / 2 - s.height - spacing
            for (line, size) in zip(lines, lineSizes) {
                y -= size.height
                line.draw(at: CGPoint(x: lc.x - size.width / 2, y: y))
                y += 2
            }
        } else {
            let s = fittedString(item.title, maxWidth: maxW, sizes: [16, 15, 14, 13, 12, 11, 10, 9],
                                 weight: .bold, color: textColor)
            let size = s.size()
            s.draw(at: CGPoint(x: lc.x - size.width / 2, y: lc.y - size.height / 2))
        }
    }

    /// Thin coloured stripe along the outer edge of an unhighlighted petal.
    private func drawRim(_ ctx: CGContext, path: CGPath, petal: FanLayout.Petal, color: NSColor) {
        let c = center
        let outer = petal.outer + 2
        let inner = petal.outer - FanStyle.rimWidth
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer))
        ring.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner))
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.addPath(ring)
        ctx.setFillColor(color.withAlphaComponent(0.92).cgColor)
        ctx.fillPath(using: .evenOdd)
        // Faint wash of the colour over the rest of the petal so it reads as "belonging" to its category.
        ctx.addPath(path)
        ctx.setFillColor(color.withAlphaComponent(0.07).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// Caption for tool/action petals: one line if it fits at a readable size, otherwise two lines.
    private func captionLines(_ text: String, maxWidth: CGFloat, color: NSColor) -> [NSAttributedString] {
        let attrs: (CGFloat) -> [NSAttributedString.Key: Any] = { [.font: FanStyle.rounded($0, .semibold), .foregroundColor: color] }
        for size: CGFloat in [10.5, 10, 9.5] {
            let one = NSAttributedString(string: text, attributes: attrs(size))
            if one.size().width <= maxWidth { return [one] }
        }
        // Long single words (e.g. Russian «Конвертировать») carry soft hyphens from the translation: break there.
        let softHyphen: Character = "\u{00AD}"
        if !text.contains(" "), text.contains(softHyphen) {
            let parts = text.split(separator: softHyphen).map(String.init)
            var best: (String, String)?
            var bestDiff = Int.max
            for i in 1..<parts.count {
                let a = parts[..<i].joined() + "-", b = parts[i...].joined()
                let d = abs(a.count - b.count)
                if d < bestDiff { bestDiff = d; best = (a, b) }
            }
            if let (a, b) = best {
                return [a, b].map { fittedString($0, maxWidth: maxWidth, sizes: [10, 9.5, 9, 8.5], weight: .semibold, color: color) }
            }
        }
        let words = text.split(separator: " ")
        if words.count > 1 {
            // Split at the word boundary that best balances the two lines.
            var best: (String, String)?
            var bestDiff = Int.max
            for i in 1..<words.count {
                let a = words[..<i].joined(separator: " "), b = words[i...].joined(separator: " ")
                let d = abs(a.count - b.count)
                if d < bestDiff { bestDiff = d; best = (a, b) }
            }
            if let (a, b) = best {
                return [a, b].map { fittedString($0, maxWidth: maxWidth, sizes: [10, 9.5, 9, 8.5], weight: .semibold, color: color) }
            }
        }
        return [fittedString(text, maxWidth: maxWidth, sizes: [9, 8.5], weight: .semibold, color: color)]
    }

    /// Largest font size from `sizes` at which `text` fits in `maxWidth` (truncating at the smallest).
    private func fittedString(_ text: String, maxWidth: CGFloat, sizes: [CGFloat],
                              weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        var last: NSAttributedString?
        for size in sizes {
            let s = NSAttributedString(string: text, attributes: [.font: FanStyle.rounded(size, weight), .foregroundColor: color])
            if s.size().width <= maxWidth { return s }
            last = s
        }
        // Truncate with an ellipsis at the smallest size.
        let font = FanStyle.rounded(sizes.last ?? 9, weight)
        var t = text
        while t.count > 1 {
            t.removeLast()
            let s = NSAttributedString(string: t + "…", attributes: [.font: font, .foregroundColor: color])
            if s.size().width <= maxWidth { return s }
        }
        return last ?? NSAttributedString(string: text)
    }

    private func drawCenter(_ ctx: CGContext) {
        let c = center
        let r = layout.centerRadius
        let circle = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
        drawGlassFill(ctx, path: circle, rect: circle.boundingBoxOfPath, fill: FanStyle.centerDisc.withAlphaComponent(0.65))
        strokeInside(ctx, path: circle, color: NSColor(white: 1, alpha: 0.16), width: 1)

        // Thumbnail
        let thumbSide: CGFloat = message == nil ? 46 : 36
        let thumbCenterY = c.y + (message == nil ? 11 : 15)
        var thumbFrame = CGRect(x: c.x - thumbSide / 2, y: thumbCenterY - thumbSide / 2, width: thumbSide, height: thumbSide)
        if let img = thumbnail, img.size.width > 0, img.size.height > 0 {
            let aspect = img.size.width / img.size.height
            var w = thumbSide, h = thumbSide
            if aspect > 1 { h = thumbSide / aspect } else { w = thumbSide * aspect }
            thumbFrame = CGRect(x: c.x - w / 2, y: thumbCenterY - h / 2, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            if !isIconThumbnail {
                NSBezierPath(roundedRect: thumbFrame, xRadius: 5, yRadius: 5).addClip()
            }
            img.draw(in: thumbFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            if !isIconThumbnail {
                NSColor(white: 1, alpha: 0.35).setStroke()
                let b = NSBezierPath(roundedRect: thumbFrame.insetBy(dx: 0.25, dy: 0.25), xRadius: 5, yRadius: 5)
                b.lineWidth = 0.5
                b.stroke()
            }
        }

        // Count badge
        if fileCount > 1 {
            let text = NSAttributedString(string: fileCount > 99 ? "99+" : "\(fileCount)",
                                          attributes: [.font: FanStyle.rounded(10.5, .bold), .foregroundColor: NSColor.white])  // white on Peel: 4.9:1
            let ts = text.size()
            let h: CGFloat = 17
            let w = max(h, ts.width + 9)
            let badge = CGRect(x: min(thumbFrame.maxX - w / 2 + 2, c.x + 30 - w / 2), y: thumbFrame.maxY - h / 2 - 2, width: w, height: h)
            let bp = NSBezierPath(roundedRect: badge, xRadius: h / 2, yRadius: h / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.set()
            FanStyle.peel.setFill()
            bp.fill()
            NSGraphicsContext.restoreGraphicsState()
            FanStyle.accent.setStroke()
            bp.lineWidth = 1.2
            bp.stroke()
            text.draw(at: CGPoint(x: badge.midX - ts.width / 2, y: badge.midY - ts.height / 2))
        }

        // Label
        let label: String
        let emphasized: Bool
        if let message {
            label = message; emphasized = false
        } else if let h = highlighted, h < items.count {
            label = items[h].title; emphasized = true
        } else if canGoBack && isCenterHovered {
            label = L("‹ Back"); emphasized = true
        } else {
            label = hintOverride ?? Self.hint(for: mode); emphasized = false
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let labelWidth: CGFloat = message != nil ? 92 : 84
        // Shrink the font until the longest word fits, so long words never break mid-word.
        let weight: NSFont.Weight = emphasized ? .bold : .semibold
        var fontSize: CGFloat = message != nil ? 10.5 : (emphasized ? 12 : 11)
        let longestWord = label.replacingOccurrences(of: "\u{00AD}", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            .max { $0.count < $1.count } ?? label
        while fontSize > 8.5,
              NSAttributedString(string: longestWord, attributes: [.font: FanStyle.rounded(fontSize, weight)]).size().width > labelWidth - 2 {
            fontSize -= 0.5
        }
        let font = FanStyle.rounded(fontSize, weight)
        let color = emphasized ? FanStyle.text : FanStyle.textSecondary
        let attr = NSAttributedString(string: label.replacingOccurrences(of: "\u{00AD}", with: ""),
                                      attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let labelHeight: CGFloat = 30   // two lines at 12 pt (e.g. "Strip Metadata", "Images → JPG")
        let top = thumbFrame.minY - 3
        let rect = CGRect(x: c.x - labelWidth / 2, y: top - labelHeight, width: labelWidth, height: labelHeight)
        let needed = attr.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]).height
        let drawRect = CGRect(x: rect.minX, y: rect.maxY - min(needed, labelHeight), width: rect.width, height: min(needed, labelHeight))
        attr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    static func hint(for mode: FanMode) -> String {
        switch mode {
        case .categories: return "NurTo"
        case .conversions: return L("Convert to…")
        case .tools: return L("Tools")
        case .actions: return L("Actions")
        }
    }

    // MARK: Mouse (click mode)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard clickEnabled else { return }
        setHighlighted(petalIndex(atWindowPoint: event.locationInWindow))
        updateCenterHover(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        guard clickEnabled else { return }
        setHighlighted(nil)
        updateCenterHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard clickEnabled else { return }
        clickArmed = true
        setHighlighted(petalIndex(atWindowPoint: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard clickEnabled, clickArmed else { return }
        clickArmed = false
        if let i = petalIndex(atWindowPoint: event.locationInWindow) { onClick?(i) }
        else if isInCenter(windowPoint: event.locationInWindow) { onCenterClick?() }
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }

    // MARK: NSDraggingDestination

    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let i = petalIndex(atWindowPoint: sender.draggingLocation)
        setHighlighted(i)
        updateCenterHover(sender.draggingLocation)
        return captureDrops ? .copy : (i == nil ? [] : .copy)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setHighlighted(nil); updateCenterHover(nil) }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        captureDrops || petalIndex(atWindowPoint: sender.draggingLocation) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if captureDrops { return true } // Captured URLs are already held by the controller.
        guard let i = petalIndex(atWindowPoint: sender.draggingLocation) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop?(i, urls)
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragEnded?()
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        let c = center
        accessibilityPetals = layout.petals.enumerated().compactMap { (i, petal) in
            guard i < items.count else { return nil }
            let el = PetalAccessibilityElement()
            el.index = i
            el.owner = self
            el.setAccessibilityRole(.button)
            el.setAccessibilityLabel(items[i].title)
            el.setAccessibilityParent(self)
            el.setAccessibilityFrameInParentSpace(FanLayout.path(for: petal, center: c).boundingBoxOfPath)
            return el
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { message ?? Self.hint(for: mode) }
    override func accessibilityChildren() -> [Any]? { accessibilityPetals }

    fileprivate func accessibilityPress(_ index: Int) {
        onClick?(index)
    }
}

final class PetalAccessibilityElement: NSAccessibilityElement {
    var index = 0
    weak var owner: FanView?
    override func accessibilityPerformPress() -> Bool {
        let i = index
        let owner = owner
        DispatchQueue.main.async { owner?.accessibilityPress(i) }
        return true
    }
}
