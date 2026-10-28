import AppKit
import SwiftUI
import Combine

// Shared infrastructure for the image editors (Annotate, Redact Image): colour value type, image I/O,
// geometry, shortcuts and a zoomable canvas NSView that works in IMAGE pixel coordinates
// (top-left origin, y down). The window itself is an `EditorWindowHost`.

// MARK: - Colour

/// An sRGB colour stored as plain values so edit snapshots are immutable and thread-safe.
struct ImageCanvasRGBA: Equatable, Hashable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? NSColor.black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    init(_ color: Color) { self.init(NSColor(color)) }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(nsColor: nsColor) }
    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func withAlpha(_ alpha: CGFloat) -> ImageCanvasRGBA { ImageCanvasRGBA(r: r, g: g, b: b, a: alpha) }

    static let red = ImageCanvasRGBA(r: 0.96, g: 0.20, b: 0.20)
    static let orange = ImageCanvasRGBA(r: 1.0, g: 0.478, b: 0.102)
    static let yellow = ImageCanvasRGBA(r: 1.0, g: 0.84, b: 0.10)
    static let green = ImageCanvasRGBA(r: 0.20, g: 0.78, b: 0.35)
    static let blue = ImageCanvasRGBA(r: 0.12, g: 0.52, b: 1.0)
    static let purple = ImageCanvasRGBA(r: 0.62, g: 0.32, b: 0.95)
    static let black = ImageCanvasRGBA(r: 0.06, g: 0.06, b: 0.06)
    static let white = ImageCanvasRGBA(r: 1, g: 1, b: 1)

    static let palette: [ImageCanvasRGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

// MARK: - Image I/O

enum ImageCanvasIO {
    /// Long side of the on-screen copy of the image (the export always uses full resolution).
    static let previewMaxSide = 3072

    /// jpg/png/heic/tiff keep their format, anything else becomes PNG.
    static func outputFormat(for url: URL) -> FileFormat {
        if let f = FileFormat.detect(url), [.jpg, .png, .heic, .tiff].contains(f), ImageCodec.canEncode(f) { return f }
        return .png
    }

    /// Loads the first input with orientation applied, plus a screen-sized preview copy.
    static func load(_ url: URL) throws -> (full: LoadedImage, preview: CGImage) {
        let loaded = try ImageCodec.load(url)
        return (loaded, ImageCodec.limited(loaded.image, maxSide: previewMaxSide))
    }

    static func colorSpace(of image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb, cs.supportsOutput { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// An 8-bit context matching the image's RGB colour space, flipped so (0,0) is the top-left corner.
    static func makeFlippedContext(like image: CGImage, width: Int, height: Int, opaque: Bool) -> CGContext? {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace(of: image), bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        return ctx
    }

    /// Draws `image` upright into `rect` of a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Encodes `image` into a NEW file next to `source` (never overwrites).
    static func write(_ image: CGImage, nextTo source: URL, suffix: String, metadata: [CFString: Any]?) throws -> URL {
        let format = outputFormat(for: source)
        let data = try ImageCodec.encode(image, format: format, quality: 0.92, metadata: metadata)
        let out = OutputNaming.url(for: source, ext: format.fileExtension, suffix: suffix)
        try data.write(to: out, options: .withoutOverwriting)
        return out
    }
}

// MARK: - Geometry helpers

enum ImageCanvasGeometry {
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    static func rect(_ a: CGPoint, _ b: CGPoint, square: Bool = false) -> CGRect {
        var w = b.x - a.x, h = b.y - a.y
        if square {
            let s = max(abs(w), abs(h))
            w = w < 0 ? -s : s
            h = h < 0 ? -s : s
        }
        return CGRect(x: a.x, y: a.y, width: w, height: h).standardized
    }

    /// Snaps b around a to 45° steps.
    static func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }

    static func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    /// Corners 0…3 (tl, tr, br, bl) then edges 4…7 (top, right, bottom, left).
    static func handlePoints(of r: CGRect) -> [CGPoint] {
        corners(of: r) + [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                          CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    /// Resizes `r` by dragging handle `index` (see `handlePoints`) to `p`.
    static func resize(_ r: CGRect, handle index: Int, to p: CGPoint, keepAspect: Bool = false, minSize: CGFloat = 4) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch index {
        case 0: minX = p.x; minY = p.y
        case 1: maxX = p.x; minY = p.y
        case 2: maxX = p.x; maxY = p.y
        case 3: minX = p.x; maxY = p.y
        case 4: minY = p.y
        case 5: maxX = p.x
        case 6: maxY = p.y
        case 7: minX = p.x
        default: break
        }
        var out = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        if keepAspect, index < 4, r.width > 0, r.height > 0 {
            let aspect = r.width / r.height
            let w = max(out.width, out.height * aspect)
            let h = w / aspect
            // Anchor at the corner opposite the handle.
            let anchor = corners(of: r)[(index + 2) % 4]
            let sx: CGFloat = p.x >= anchor.x ? 1 : -1, sy: CGFloat = p.y >= anchor.y ? 1 : -1
            out = CGRect(x: anchor.x, y: anchor.y, width: w * sx, height: h * sy).standardized
        }
        if out.width < minSize { out.size.width = minSize }
        if out.height < minSize { out.size.height = minSize }
        return out
    }
}

// MARK: - Canvas

/// A zoomable / pannable view that shows an image. Subclasses draw in image coordinates.
class ImageCanvasView: NSView {
    var imageSize: CGSize = .zero { didSet { zoomToFit() } }
    private(set) var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var fitting = true
    var showsCheckerboard = false
    /// Called whenever the zoom factor changes.
    var onZoomChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // macOS 14 no longer clips view drawing to bounds by default.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Coordinates

    private var fitZoom: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        let inset: CGFloat = 20
        return max(0.01, min((bounds.width - inset * 2) / imageSize.width, (bounds.height - inset * 2) / imageSize.height))
    }

    var imageOrigin: CGPoint {
        CGPoint(x: ((bounds.width - imageSize.width * zoom) / 2 + pan.x).rounded(),
                y: ((bounds.height - imageSize.height * zoom) / 2 + pan.y).rounded())
    }

    var imageRectInView: CGRect { CGRect(origin: imageOrigin, size: CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)) }

    func toImage(_ p: CGPoint) -> CGPoint {
        let o = imageOrigin
        return CGPoint(x: (p.x - o.x) / zoom, y: (p.y - o.y) / zoom)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        let o = imageOrigin
        return CGPoint(x: o.x + p.x * zoom, y: o.y + p.y * zoom)
    }

    func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
    }

    func imagePoint(_ event: NSEvent) -> CGPoint { toImage(convert(event.locationInWindow, from: nil)) }
    func viewPoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// Centre of the visible part of the image, in image coordinates.
    var visibleImageCenter: CGPoint {
        let vis = bounds.intersection(imageRectInView)
        let c = vis.isNull ? CGPoint(x: bounds.midX, y: bounds.midY) : CGPoint(x: vis.midX, y: vis.midY)
        return toImage(c)
    }

    // MARK: Zoom

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitting { applyFit() } else { clampPan() }
    }

    private func applyFit() {
        let z = fitZoom
        pan = .zero
        if z != zoom { zoom = z; zoomDidChange() }
        needsDisplay = true
    }

    func zoomToFit() {
        fitting = true
        applyFit()
    }

    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        let z = max(0.02, min(32, newZoom))
        let a = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let ip = toImage(a)
        fitting = false
        zoom = z
        pan.x = a.x - ip.x * z - (bounds.width - imageSize.width * z) / 2
        pan.y = a.y - ip.y * z - (bounds.height - imageSize.height * z) / 2
        clampPan()
        zoomDidChange()
        needsDisplay = true
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    /// Hook for subclasses (e.g. to reposition inline editors).
    func zoomDidChange() { onZoomChange?(zoom) }

    private func clampPan() {
        let w = imageSize.width * zoom, h = imageSize.height * zoom
        let mx = max(0, (w - bounds.width) / 2 + 40), my = max(0, (h - bounds.height) / 2 + 40)
        pan.x = w <= bounds.width ? 0 : max(-mx, min(mx, pan.x))
        pan.y = h <= bounds.height ? 0 : max(-my, min(my, pan.y))
    }

    func panBy(_ dx: CGFloat, _ dy: CGFloat) {
        pan.x += dx; pan.y += dy
        fitting = false
        clampPan()
        zoomDidChange()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: viewPoint(event))
    }

    override func smartMagnify(with event: NSEvent) {
        if fitting { setZoom(1, anchor: viewPoint(event)) } else { zoomToFit() }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            setZoom(zoom * (1 + d), anchor: viewPoint(event))
        } else {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            panBy(event.scrollingDeltaX * k, event.scrollingDeltaY * k)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.underPageBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        let ir = imageRectInView
        // Soft drop shadow under the page.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 10, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(ir)
        ctx.restoreGState()
        if showsCheckerboard { drawCheckerboard(ctx, in: ir.intersection(dirtyRect)) }

        ctx.saveGState()
        ctx.clip(to: ir)
        ctx.translateBy(x: ir.minX, y: ir.minY)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.interpolationQuality = zoom > 2 ? .none : .high
        drawContent(ctx)
        ctx.restoreGState()

        drawOverlay(ctx)
    }

    private func drawCheckerboard(_ ctx: CGContext, in r: CGRect) {
        guard !r.isNull, r.width > 0 else { return }
        let s: CGFloat = 10
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setFillColor(NSColor(white: 0.84, alpha: 1).cgColor)
        let ir = imageRectInView
        var y = ir.minY + ((r.minY - ir.minY) / s).rounded(.down) * s
        while y < r.maxY {
            let row = Int(((y - ir.minY) / s).rounded())
            var x = ir.minX + ((r.minX - ir.minX) / s).rounded(.down) * s
            while x < r.maxX {
                let col = Int(((x - ir.minX) / s).rounded())
                if (row + col) % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: s, height: s)) }
                x += s
            }
            y += s
        }
        ctx.restoreGState()
    }

    /// Draw the image and edits. The context is in image coordinates (y down), clipped to the image.
    func drawContent(_ ctx: CGContext) {}
    /// Draw selection chrome in view coordinates.
    func drawOverlay(_ ctx: CGContext) {}

    static let handleRadius: CGFloat = 5

    static func drawHandle(_ ctx: CGContext, at p: CGPoint) {
        let r = CGRect(x: p.x - handleRadius, y: p.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        ctx.setStrokeColor(KQTheme.accentNS.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: r.insetBy(dx: 0.75, dy: 0.75))
    }

    static func drawSelectionBox(_ ctx: CGContext, _ r: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(KQTheme.accentNS.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        ctx.restoreGState()
    }

    /// Index of the handle near view point `p`, if any.
    func handleIndex(at p: CGPoint, handles: [CGPoint]) -> Int? {
        var best: (Int, CGFloat)?
        for (i, h) in handles.enumerated() {
            let d = ImageCanvasGeometry.distance(p, toView(h))
            if d <= Self.handleRadius + 4, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }
}

// MARK: - SwiftUI pieces

/// Hosts an existing NSView (the canvas) in SwiftUI.
struct ImageCanvasHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ImageCanvasToolButton: View {
    let symbol: String
    let help: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(selected ? KQTheme.onAccentProminent : Color.primary)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? KQTheme.accentProminentFill : Color.primary.opacity(0.0001)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(help))
    }
}

struct ImageCanvasIconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .help(L(help))
    }
}

/// Colour swatches + system colour picker.
struct ImageCanvasColorRow: View {
    let colors: [ImageCanvasRGBA]
    let selection: ImageCanvasRGBA
    let onPick: (ImageCanvasRGBA) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(colors, id: \.self) { c in
                Button { onPick(c) } label: {
                    Circle()
                        .fill(c.color)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .overlay(Circle().strokeBorder(KQTheme.accent, lineWidth: selection.withAlpha(1) == c ? 2 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: Binding(get: { selection.withAlpha(1).color },
                                               set: { onPick(ImageCanvasRGBA($0).withAlpha(1)) }),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30)
                .help("Custom colour")
        }
    }
}

struct ImageCanvasZoomControls: View {
    let percent: Int
    let fit: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ImageCanvasIconButton(symbol: "minus.magnifyingglass", help: "Zoom Out (⌘−)", action: zoomOut)
            Text(verbatim: "\(percent)%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)
            ImageCanvasIconButton(symbol: "plus.magnifyingglass", help: "Zoom In (⌘+)", action: zoomIn)
            Button("Fit", action: fit)
                .buttonStyle(KQSecondaryButtonStyle())
                .help("Zoom to Fit (⌘0)")
        }
    }
}

/// Canvas shortcuts shared by both image editors (⌘S, Esc, ⌘W and undo are handled by the
/// `EditorWindowHost`). Returns true if handled.
@MainActor
enum ImageCanvasKeys {
    struct Actions {
        var deleteSelection: () -> Void
        var zoomIn: () -> Void
        var zoomOut: () -> Void
        var zoomFit: () -> Void
        var nudge: (CGFloat, CGFloat) -> Bool
        var paste: (() -> Void)? = nil
        /// Plain (unmodified) character shortcuts such as tool letters.
        var character: ((String) -> Bool)? = nil
    }

    static func handle(_ event: NSEvent, _ a: Actions) -> Bool {
        let mods = EditorKeys.modifiers(event)
        let key = event.charactersIgnoringModifiers ?? ""
        if mods.contains(.command) {
            switch key.lowercased() {
            case "=", "+": a.zoomIn(); return true
            case "-", "_": a.zoomOut(); return true
            case "0": a.zoomFit(); return true
            case "v":
                if let paste = a.paste { paste(); return true }
                return false
            default: return false
            }
        }
        guard !mods.contains(.control), !mods.contains(.option) else { return false }
        let step: CGFloat = mods.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case EditorKeys.delete, EditorKeys.forwardDelete: a.deleteSelection(); return true
        case EditorKeys.left: return a.nudge(-step, 0)
        case EditorKeys.right: return a.nudge(step, 0)
        case EditorKeys.down: return a.nudge(0, step)
        case EditorKeys.up: return a.nudge(0, -step)
        default: break
        }
        if mods.isEmpty, let ch = a.character, key.count == 1 { return ch(key.lowercased()) }
        return false
    }
}
