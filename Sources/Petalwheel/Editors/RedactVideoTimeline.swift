import AppKit
import SwiftUI

/// Layer timeline: time ruler + thumbnail strip with a playhead, then one row per region whose
/// bar shows (and edits) the region's time range.
final class RedactVideoTimelineView: NSView {
    let model: RedactVideoModel

    static let gutter: CGFloat = 34
    static let rulerHeight: CGFloat = 16
    static let stripHeight: CGFloat = 40
    static let rowHeight: CGFloat = 22
    static let topArea: CGFloat = rulerHeight + stripHeight + 6

    static func height(rows: Int) -> CGFloat { topArea + CGFloat(max(rows, 1)) * rowHeight + 8 }

    private enum Drag {
        case none, scrub
        case move(id: UUID, start: Double, end: Double, anchor: Double)
        case resizeStart(id: UUID), resizeEnd(id: UUID)
    }
    private var drag = Drag.none

    init(model: RedactVideoModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var track: NSRect {
        NSRect(x: Self.gutter, y: 0, width: max(1, bounds.width - Self.gutter - 10), height: bounds.height)
    }

    private func x(for t: Double) -> CGFloat {
        let d = max(model.duration, 0.001)
        return track.minX + CGFloat(min(max(t / d, 0), 1)) * track.width
    }

    private func time(for x: CGFloat) -> Double {
        Double((x - track.minX) / track.width) * model.duration
    }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 0, y: Self.topArea + CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
    }

    private func barRect(_ r: RedactVideoRegion, row: Int) -> NSRect {
        let range = r.range(duration: model.duration)
        let x0 = x(for: range.lowerBound), x1 = max(x(for: range.upperBound), x0 + 3)
        let row = rowRect(row)
        return NSRect(x: x0, y: row.minY + 3, width: x1 - x0, height: row.height - 6)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let t = track
        // Ruler ticks.
        let d = model.duration
        if d > 0 {
            let step = TimelineRuler.step(visible: d, width: t.width)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            var s = 0.0
            NSColor.tertiaryLabelColor.setFill()
            while s <= d + 0.0001 {
                let px = x(for: s).rounded() + 0.5
                NSRect(x: px - 0.5, y: Self.rulerHeight - 5, width: 1, height: 5).fill()
                (TimelineRuler.label(s, step: step) as NSString).draw(at: NSPoint(x: px + 2, y: 1), withAttributes: attrs)
                s += step
            }
        }
        // Thumbnail strip.
        let strip = NSRect(x: t.minX, y: Self.rulerHeight, width: t.width, height: Self.stripHeight)
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6)
        clip.addClip()
        NSColor.black.withAlphaComponent(0.6).setFill()
        strip.fill()
        if let frames = model.filmstrip, !frames.images.isEmpty {
            let tw = max(16, strip.height * CGFloat(frames.aspect))
            let count = max(1, Int(ceil(strip.width / tw)))
            for i in 0..<count {
                let rect = NSRect(x: strip.minX + CGFloat(i) * tw, y: strip.minY, width: tw, height: strip.height)
                let center = (Double(i) + 0.5) / Double(count)
                guard let cg = frames.image(near: center * d) else { continue }
                NSImage(cgImage: cg, size: rect.size)
                    .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        clip.lineWidth = 1
        clip.stroke()

        // Rows.
        if model.regions.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            (L("Draw a rectangle on the video to add a redaction layer.") as NSString)
                .draw(at: NSPoint(x: t.minX + 4, y: Self.topArea + 4), withAttributes: attrs)
        }
        for (i, region) in model.regions.enumerated() {
            let row = rowRect(i)
            let selected = region.id == model.selectedID
            if selected {
                KQTheme.accentNS.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
            } else if i % 2 == 1 {
                NSColor.labelColor.withAlphaComponent(0.03).setFill()
                row.fill()
            }
            let tint = RedactVideoModel.tintColor(region.tint)
            // Row label: colour dot + number + style glyph.
            let dot = NSRect(x: 8, y: row.midY - 4, width: 8, height: 8)
            tint.setFill()
            NSBezierPath(ovalIn: dot).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                        .foregroundColor: NSColor.labelColor]
            ("\(i + 1)" as NSString).draw(at: NSPoint(x: 19, y: row.minY + 4), withAttributes: attrs)

            let bar = barRect(region, row: i)
            let path = NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4)
            tint.withAlphaComponent(selected ? 0.95 : 0.7).setFill()
            path.fill()
            if selected {
                NSColor.white.withAlphaComponent(0.9).setStroke()
                path.lineWidth = 1.5
                path.stroke()
                NSColor.white.setFill()
                for hx in [bar.minX + 3, bar.maxX - 5] where bar.width > 12 {
                    NSBezierPath(roundedRect: NSRect(x: hx, y: bar.minY + 3, width: 2, height: bar.height - 6),
                                 xRadius: 1, yRadius: 1).fill()
                }
            }
            let label = Self.styleLabel(region) as NSString
            let lattrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                         .foregroundColor: NSColor.white]
            let lsize = label.size(withAttributes: lattrs)
            if bar.width > lsize.width + 16 {
                label.draw(at: NSPoint(x: bar.minX + 9, y: bar.midY - lsize.height / 2), withAttributes: lattrs)
            }
        }

        // Playhead.
        let px = x(for: model.currentTime).rounded() + 0.5
        KQTheme.accentNS.setFill()
        NSRect(x: px - 1, y: Self.rulerHeight - 2, width: 2, height: bounds.height - Self.rulerHeight + 2).fill()
        let knob = NSBezierPath()
        knob.move(to: NSPoint(x: px - 6, y: Self.rulerHeight - 8))
        knob.line(to: NSPoint(x: px + 6, y: Self.rulerHeight - 8))
        knob.line(to: NSPoint(x: px, y: Self.rulerHeight))
        knob.close()
        knob.fill()
    }

    static func styleLabel(_ r: RedactVideoRegion) -> String {
        switch r.style {
        case .blur: return L("Blur")
        case .pixelate: return L("Pixelate")
        case .solid: return L("Solid")
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard model.isLoaded else { return }
        let p = convert(event.locationInWindow, from: nil)
        drag = .none
        if p.y < Self.topArea {
            drag = .scrub
            model.seek(to: time(for: p.x))
            return
        }
        let row = Int((p.y - Self.topArea) / Self.rowHeight)
        guard row >= 0, row < model.regions.count else {
            model.select(nil)
            return
        }
        let region = model.regions[row]
        let bar = barRect(region, row: row)
        model.select(region.id)
        if bar.insetBy(dx: -5, dy: -2).contains(p) {
            model.beginChange()
            let range = region.range(duration: model.duration)
            if abs(p.x - bar.minX) <= 6 {
                drag = .resizeStart(id: region.id)
            } else if abs(p.x - bar.maxX) <= 6 {
                drag = .resizeEnd(id: region.id)
            } else {
                drag = .move(id: region.id, start: range.lowerBound, end: range.upperBound, anchor: time(for: p.x))
            }
            if !region.isVisible(at: model.currentTime, duration: model.duration) {
                model.seek(to: range.lowerBound)
            }
        } else {
            model.seek(to: time(for: p.x))
            drag = .scrub
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = min(max(time(for: p.x), 0), model.duration)
        let d = model.duration
        let minLen = min(0.1, d)
        switch drag {
        case .none:
            break
        case .scrub:
            model.seek(to: t)
        case .move(let id, let s, let e, let anchor):
            let len = e - s
            let ns = min(max(s + (t - anchor), 0), max(0, d - len))
            model.update(id) { $0.entireVideo = false; $0.start = ns; $0.end = ns + len }
            model.seek(to: ns)
        case .resizeStart(let id):
            model.update(id) { r in
                let range = r.range(duration: d)
                r.entireVideo = false
                r.end = range.upperBound
                r.start = min(t, r.end - minLen)
            }
            model.seek(to: model.regions.first { $0.id == id }?.start ?? t)
        case .resizeEnd(let id):
            model.update(id) { r in
                let range = r.range(duration: d)
                r.entireVideo = false
                r.start = range.lowerBound
                r.end = max(t, r.start + minLen)
            }
            model.seek(to: max(0, min(t, d) - 0.001))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .move, .resizeStart, .resizeEnd: model.commitChange()
        default: break
        }
        drag = .none
    }

    override func resetCursorRects() {
        for (i, r) in model.regions.enumerated() {
            let bar = barRect(r, row: i)
            addCursorRect(NSRect(x: bar.minX - 5, y: bar.minY, width: 10, height: bar.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bar.maxX - 5, y: bar.minY, width: 10, height: bar.height), cursor: .resizeLeftRight)
        }
    }
}

struct RedactVideoTimeline: NSViewRepresentable {
    @ObservedObject var model: RedactVideoModel

    func makeNSView(context: Context) -> RedactVideoTimelineView { RedactVideoTimelineView(model: model) }

    func updateNSView(_ v: RedactVideoTimelineView, context: Context) {
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
    }
}
