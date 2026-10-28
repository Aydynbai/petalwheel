import AppKit
import SwiftUI

// Annotate renderer shared by the canvas and the export. Geometry is in IMAGE pixel coordinates
// with a top-left origin.

// MARK: - Renderer

enum AnnotateRenderer {
    static let highlighterWidthFactor: CGFloat = 4
    static let highlighterAlpha: CGFloat = 0.45

    // MARK: Measurement / hit testing

    static func textAttributes(_ t: AnnotateText, color: ImageCanvasRGBA) -> [NSAttributedString.Key: Any] {
        [.font: t.family.font(size: t.fontSize), .foregroundColor: color.nsColor]
    }

    static func textHeight(_ t: AnnotateText) -> CGFloat {
        let s = t.string.isEmpty ? " " : t.string
        let a = NSAttributedString(string: s, attributes: [.font: t.family.font(size: t.fontSize)])
        let r = a.boundingRect(with: CGSize(width: max(1, t.width), height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(ceil(r.height), ceil(t.fontSize * 1.2))
    }

    static func textRect(_ t: AnnotateText) -> CGRect {
        CGRect(x: t.origin.x, y: t.origin.y, width: t.width, height: textHeight(t))
    }

    static func pointsBounds(_ ps: [CGPoint]) -> CGRect {
        guard let f = ps.first else { return .null }
        var r = CGRect(origin: f, size: .zero)
        for p in ps.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    static func bounds(_ item: AnnotateItem) -> CGRect {
        let lw = item.lineWidth
        switch item.shape {
        case let .arrow(a, b):
            return ImageCanvasGeometry.rect(a, b).insetBy(dx: -lw * 2, dy: -lw * 2)
        case let .pen(ps): return pointsBounds(ps).insetBy(dx: -lw / 2, dy: -lw / 2)
        case let .highlighter(ps):
            let w = lw * highlighterWidthFactor / 2
            return pointsBounds(ps).insetBy(dx: -w, dy: -w)
        case let .rectangle(r), let .ellipse(r): return r.insetBy(dx: -lw / 2, dy: -lw / 2)
        case let .text(t): return textRect(t)
        case let .step(c, _, r): return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case let .magnifier(c, r, _): return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case let .sticker(r, _): return r
        }
    }

    static func hitTest(_ item: AnnotateItem, _ p: CGPoint, tolerance tol: CGFloat) -> Bool {
        let lw = item.lineWidth
        switch item.shape {
        case let .arrow(a, b):
            return ImageCanvasGeometry.distance(p, toSegment: a, b) <= lw * 1.6 + tol
        case let .pen(ps), let .highlighter(ps):
            let w = (item.shape.isHighlighter ? lw * highlighterWidthFactor : lw) / 2 + tol
            if ps.count == 1 { return ImageCanvasGeometry.distance(p, ps[0]) <= w }
            for i in 1..<max(1, ps.count) where ImageCanvasGeometry.distance(p, toSegment: ps[i - 1], ps[i]) <= w { return true }
            return false
        case let .rectangle(r):
            let e = lw / 2 + tol
            let outer = r.insetBy(dx: -e, dy: -e), inner = r.insetBy(dx: e, dy: e)
            return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        case let .ellipse(r):
            let rx = max(1, r.width / 2), ry = max(1, r.height / 2)
            let dx = (p.x - r.midX) / rx, dy = (p.y - r.midY) / ry
            return abs(sqrt(dx * dx + dy * dy) - 1) * min(rx, ry) <= lw / 2 + tol
        default:
            return bounds(item).insetBy(dx: -tol, dy: -tol).contains(p)
        }
    }

    // MARK: Drawing

    /// Draws `items` into a y-down context in image coordinates. `base` is the image (any resolution) that
    /// covers the `imageSize` rect, used by magnifiers.
    static func draw(_ items: [AnnotateItem], base: CGImage, imageSize: CGSize, in ctx: CGContext, skipping skip: UUID? = nil) {
        for item in items where item.id != skip {
            draw(item, base: base, imageSize: imageSize, in: ctx)
        }
    }

    static func draw(_ item: AnnotateItem, base: CGImage, imageSize: CGSize, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = item.color.cgColor
        let lw = item.lineWidth
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch item.shape {
        case let .arrow(a, b):
            ctx.setFillColor(color)
            ctx.addPath(arrowPath(from: a, to: b, width: lw))
            ctx.fillPath()

        case let .pen(ps):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lw)
            ctx.addPath(smoothPath(ps))
            ctx.strokePath()

        case let .highlighter(ps):
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(item.color.withAlpha(highlighterAlpha).cgColor)
            ctx.setLineWidth(lw * highlighterWidthFactor)
            ctx.setLineCap(.square)
            ctx.addPath(smoothPath(ps))
            ctx.strokePath()

        case let .rectangle(r):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lw)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(lw, r.width / 2), cornerHeight: min(lw, r.height / 2), transform: nil))
            ctx.strokePath()

        case let .ellipse(r):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lw)
            ctx.strokeEllipse(in: r)

        case let .text(t):
            drawText(t, color: item.color, in: ctx)

        case let .step(c, n, r):
            let circle = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: r * 0.08), blur: r * 0.3, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: circle)
            ctx.restoreGState()
            ctx.setFillColor(color)
            ctx.fillEllipse(in: circle.insetBy(dx: r * 0.12, dy: r * 0.12))
            let fg: NSColor = item.color.luminance > 0.65 ? .black : .white
            let font = NSFont.monospacedDigitSystemFont(ofSize: r * (n >= 10 ? 0.85 : 1.05), weight: .bold)
            let s = NSAttributedString(string: "\(n)", attributes: [.font: font, .foregroundColor: fg])
            let size = s.size()
            withAppKit(ctx) {
                s.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
            }

        case let .magnifier(c, r, z):
            let circle = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: r * 0.04), blur: r * 0.18, color: CGColor(gray: 0, alpha: 0.45))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: circle)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addEllipse(in: circle)
            ctx.clip()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.scaleBy(x: z, y: z)
            ctx.translateBy(x: -c.x, y: -c.y)
            ImageCanvasIO.drawImage(base, in: CGRect(origin: .zero, size: imageSize), ctx: ctx)
            ctx.restoreGState()
            let ring = max(lw, r * 0.035)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(ring)
            ctx.strokeEllipse(in: circle.insetBy(dx: ring / 2, dy: ring / 2))

        case let .sticker(r, img):
            ImageCanvasIO.drawImage(img, in: r, ctx: ctx)
        }
    }

    static func drawText(_ t: AnnotateText, color: ImageCanvasRGBA, in ctx: CGContext) {
        guard !t.string.isEmpty else { return }
        let s = NSAttributedString(string: t.string, attributes: textAttributes(t, color: color))
        let rect = CGRect(x: t.origin.x, y: t.origin.y, width: t.width, height: textHeight(t) + t.fontSize)
        ctx.saveGState()
        // A soft halo keeps light text readable on light backgrounds.
        if color.luminance > 0.6 {
            ctx.setShadow(offset: .zero, blur: t.fontSize * 0.15, color: CGColor(gray: 0, alpha: 0.55))
        }
        withAppKit(ctx) {
            s.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        ctx.restoreGState()
    }

    /// Runs AppKit text drawing against a y-down CGContext.
    static func withAppKit(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A filled arrow: tapered shaft (thin tail → full width) and a swept-back head.
    static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> CGPath {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let path = CGMutablePath()
        guard len > 0.5 else { return path }
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let headLen = min(len * 0.6, max(w * 5, 12))
        let headHalf = headLen * 0.58
        func pt(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: a.x + ux * along + nx * side, y: a.y + uy * along + ny * side)
        }
        let tailHalf = w * 0.18
        let neckHalf = w * 0.55
        let baseAt = len - headLen
        let neckAt = len - headLen * 0.78   // shaft meets the head inside its swept-back notch
        path.move(to: pt(0, tailHalf))
        path.addLine(to: pt(neckAt, neckHalf))
        path.addLine(to: pt(baseAt, headHalf))
        path.addLine(to: b)
        path.addLine(to: pt(baseAt, -headHalf))
        path.addLine(to: pt(neckAt, -neckHalf))
        path.addLine(to: pt(0, -tailHalf))
        path.addArc(center: a, radius: tailHalf, startAngle: atan2(-ny, -nx), endAngle: atan2(ny, nx), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Quadratic-midpoint smoothing through the captured points.
    static func smoothPath(_ ps: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = ps.first else { return p }
        p.move(to: first)
        if ps.count == 1 { p.addLine(to: first); return p }
        if ps.count == 2 { p.addLine(to: ps[1]); return p }
        for i in 1..<(ps.count - 1) {
            let mid = CGPoint(x: (ps[i].x + ps[i + 1].x) / 2, y: (ps[i].y + ps[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: ps[i])
        }
        p.addLine(to: ps[ps.count - 1])
        return p
    }

    /// Light moving-average to remove mouse jitter (keeps the end points).
    static func smoothed(_ ps: [CGPoint]) -> [CGPoint] {
        guard ps.count > 3 else { return ps }
        var out = [ps[0]]
        for i in 1..<(ps.count - 1) {
            out.append(CGPoint(x: (ps[i - 1].x + ps[i].x * 2 + ps[i + 1].x) / 4,
                               y: (ps[i - 1].y + ps[i].y * 2 + ps[i + 1].y) / 4))
        }
        out.append(ps[ps.count - 1])
        return out
    }

    /// Renders the full-resolution image with all annotations flattened.
    static func renderFlattened(image: CGImage, items: [AnnotateItem]) throws -> CGImage {
        let w = image.width, h = image.height
        let opaque = !ImageCodec.hasAlpha(image)
        guard let ctx = ImageCanvasIO.makeFlippedContext(like: image, width: w, height: h, opaque: opaque) else {
            throw PetalwheelError(l: "Could not allocate an image of %d×%d.", w, h)
        }
        let size = CGSize(width: w, height: h)
        ImageCanvasIO.drawImage(image, in: CGRect(origin: .zero, size: size), ctx: ctx)
        draw(items, base: image, imageSize: size, in: ctx)
        guard let out = ctx.makeImage() else { throw PetalwheelError(l: "Could not render the annotated image.") }
        return out
    }
}

extension AnnotateItem.Shape {
    var isHighlighter: Bool { if case .highlighter = self { return true }; return false }
}
