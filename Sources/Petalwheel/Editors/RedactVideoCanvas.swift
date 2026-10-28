import AppKit
import AVFoundation
import SwiftUI

/// Video area: AVPlayerLayer underneath, an overlay that draws the exact paused frame,
/// effect previews, rectangles and handles, and handles drawing / moving / resizing.
final class RedactVideoCanvasView: NSView {
    let model: RedactVideoModel
    private let playerHost = NSView()
    private let playerLayer = AVPlayerLayer()
    private let overlay: RedactVideoOverlayView

    init(model: RedactVideoModel) {
        self.model = model
        overlay = RedactVideoOverlayView(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerHost.layer = CALayer()
        playerHost.wantsLayer = true
        playerHost.layer?.addSublayer(playerLayer)
        addSubview(playerHost)
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        let rect = overlay.videoRect(in: bounds)
        playerHost.frame = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = playerHost.bounds
        CATransaction.commit()
        if playerLayer.player !== model.player { playerLayer.player = model.player }
        playerHost.isHidden = model.player == nil
        overlay.frame = bounds
        overlay.needsDisplay = true
    }
}

final class RedactVideoOverlayView: NSView {
    let model: RedactVideoModel

    private enum Drag {
        case none
        case create(origin: CGPoint, id: UUID?)
        case move(id: UUID, startRect: CGRect, startPoint: CGPoint)
        case resize(id: UUID, handle: Int, startRect: CGRect)
    }
    private var drag = Drag.none
    private var tracking: NSTrackingArea?

    init(model: RedactVideoModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    func videoRect(in b: NSRect) -> NSRect {
        let size = model.displaySize
        guard size.width > 0, size.height > 0, b.width > 0, b.height > 0 else { return .zero }
        let s = min(b.width / size.width, b.height / size.height)
        let w = (size.width * s).rounded(), h = (size.height * s).rounded()
        return NSRect(x: ((b.width - w) / 2).rounded(), y: ((b.height - h) / 2).rounded(), width: w, height: h)
    }

    private var scale: CGFloat {
        let v = videoRect(in: bounds)
        return model.displaySize.width > 0 ? v.width / model.displaySize.width : 1
    }

    /// Display pixels (top-left origin) → view coordinates (bottom-left origin).
    func viewRect(_ r: CGRect) -> NSRect {
        let v = videoRect(in: bounds), s = scale
        return NSRect(x: v.minX + r.minX * s, y: v.maxY - r.maxY * s, width: r.width * s, height: r.height * s)
    }

    func displayPoint(_ p: NSPoint, clamp: Bool = true) -> CGPoint {
        let v = videoRect(in: bounds), s = max(scale, 0.0001)
        var x = (p.x - v.minX) / s, y = (v.maxY - p.y) / s
        if clamp {
            x = min(max(x, 0), model.displaySize.width)
            y = min(max(y, 0), model.displaySize.height)
        }
        return CGPoint(x: x, y: y)
    }

    private func handlePoints(_ r: NSRect) -> [NSPoint] {
        // 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L (in display orientation: top = maxY in view).
        [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
         NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.midX, y: r.minY),
         NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.minX, y: r.midY)]
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let v = videoRect(in: bounds)
        if let err = model.loadError {
            drawCentered(err, color: .white)
            return
        }
        guard model.isLoaded else {
            drawCentered(L("Loading video…"), color: NSColor.white.withAlphaComponent(0.7))
            return
        }
        // The exact frame when paused (the player layer shows it too; this keeps previews in sync),
        // and every frame in the ffmpeg fallback.
        if let still = model.stillFrame, !model.isPlaying || model.usesFrameFallback {
            ctx.interpolationQuality = .high
            ctx.draw(still, in: v)
        }
        ctx.saveGState()
        ctx.clip(to: v)
        let visible = model.visibleRegions()
        for region in visible {
            let r = viewRect(region.rect)
            if region.style == .solid {
                region.color.nsColor.setFill()
                r.fill()
            } else if let patch = model.patch(for: region),
                      let p = RedactVideoExport.pixelRect(region.rect, frameWidth: Int(model.displaySize.width),
                                                           frameHeight: Int(model.displaySize.height)) {
                ctx.interpolationQuality = region.style == .pixelate ? .none : .high
                ctx.draw(patch, in: viewRect(CGRect(x: p.x, y: p.y, width: p.w, height: p.h)))
            }
        }
        for region in visible {
            let r = viewRect(region.rect)
            let tint = RedactVideoModel.tintColor(region.tint)
            let selected = region.id == model.selectedID
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = selected ? 2.5 : 1.5
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let shadow = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            shadow.lineWidth = 1
            shadow.stroke()
            tint.setStroke()
            path.stroke()
            drawBadge(index: (model.regions.firstIndex { $0.id == region.id } ?? 0) + 1, tint: tint, at: r)
            if selected {
                for hp in handlePoints(r) {
                    let h = NSRect(x: hp.x - 4.5, y: hp.y - 4.5, width: 9, height: 9)
                    NSColor.white.setFill()
                    let hpPath = NSBezierPath(roundedRect: h, xRadius: 2, yRadius: 2)
                    hpPath.fill()
                    tint.setStroke()
                    hpPath.lineWidth = 1.5
                    hpPath.stroke()
                }
            }
        }
        ctx.restoreGState()
    }

    private func drawBadge(index: Int, tint: NSColor, at r: NSRect) {
        let text = "\(index)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                    .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let badge = NSRect(x: r.minX, y: r.maxY - size.height - 4, width: size.width + 8, height: size.height + 4)
        tint.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        text.draw(at: NSPoint(x: badge.minX + 4, y: badge.minY + 2), withAttributes: attrs)
    }

    private func drawCentered(_ s: String, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                    .foregroundColor: color]
        let str = s as NSString
        let rect = bounds.insetBy(dx: 24, dy: 24)
        let size = str.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin], attributes: attrs).size
        str.draw(with: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width + 1, height: size.height + 1),
                 options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    // MARK: Hit testing

    private func hitHandle(_ p: NSPoint) -> (UUID, Int)? {
        guard let sel = model.selectedRegion, sel.isVisible(at: model.currentTime, duration: model.duration) else { return nil }
        for (i, hp) in handlePoints(viewRect(sel.rect)).enumerated() where abs(hp.x - p.x) <= 7 && abs(hp.y - p.y) <= 7 {
            return (sel.id, i)
        }
        return nil
    }

    private func hitRegion(_ p: NSPoint) -> RedactVideoRegion? {
        model.visibleRegions().reversed().first { viewRect($0.rect).insetBy(dx: -3, dy: -3).contains(p) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard model.isLoaded else { return }
        if model.isPlaying { model.pause() }
        let p = convert(event.locationInWindow, from: nil)
        model.beginChange()
        if let (id, handle) = hitHandle(p), let r = model.regions.first(where: { $0.id == id }) {
            drag = .resize(id: id, handle: handle, startRect: r.rect)
        } else if let r = hitRegion(p) {
            model.select(r.id)
            drag = .move(id: r.id, startRect: r.rect, startPoint: displayPoint(p, clamp: false))
        } else if videoRect(in: bounds).contains(p) {
            model.select(nil)
            drag = .create(origin: displayPoint(p), id: nil)
        } else {
            model.select(nil)
            drag = .none
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let size = model.displaySize
        let bounds = CGRect(origin: .zero, size: size)
        switch drag {
        case .none:
            break
        case .create(let origin, let id):
            let q = displayPoint(p)
            let r = CGRect(x: min(origin.x, q.x), y: min(origin.y, q.y),
                           width: abs(q.x - origin.x), height: abs(q.y - origin.y))
            if let id {
                model.update(id) { $0.rect = r }
            } else if r.width * scale > 4 || r.height * scale > 4 {
                drag = .create(origin: origin, id: model.addRegion(rect: r, recordUndo: false))
            }
        case .move(let id, let start, let sp):
            let q = displayPoint(p, clamp: false)
            var r = start.offsetBy(dx: q.x - sp.x, dy: q.y - sp.y)
            r.origin.x = min(max(r.minX, 0), max(0, size.width - r.width))
            r.origin.y = min(max(r.minY, 0), max(0, size.height - r.height))
            model.update(id) { $0.rect = r }
        case .resize(let id, let handle, let start):
            let q = displayPoint(p)
            var x0 = start.minX, y0 = start.minY, x1 = start.maxX, y1 = start.maxY
            switch handle {
            case 0: x0 = q.x; y0 = q.y
            case 1: y0 = q.y
            case 2: x1 = q.x; y0 = q.y
            case 3: x1 = q.x
            case 4: x1 = q.x; y1 = q.y
            case 5: y1 = q.y
            case 6: x0 = q.x; y1 = q.y
            default: x0 = q.x
            }
            let r = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
                .intersection(bounds)
            if !r.isNull { model.update(id) { $0.rect = r } }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .create(_, let id?) = drag, let r = model.regions.first(where: { $0.id == id }) {
            // Discard accidental tiny rectangles.
            if r.rect.width < 6 || r.rect.height < 6 {
                model.regions.removeAll { $0.id == id }
                model.select(nil)
            }
        }
        if case .resize(let id, _, _) = drag, let r = model.regions.first(where: { $0.id == id }),
           r.rect.width < 6 || r.rect.height < 6 {
            model.update(id) { reg in
                reg.rect.size.width = max(reg.rect.width, 8)
                reg.rect.size.height = max(reg.rect.height, 8)
            }
        }
        drag = .none
        model.commitChange()
        needsDisplay = true
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (_, handle) = hitHandle(p) {
            switch handle {
            case 1, 5: NSCursor.resizeUpDown.set()
            case 3, 7: NSCursor.resizeLeftRight.set()
            default: NSCursor.crosshair.set()
            }
        } else if hitRegion(p) != nil {
            NSCursor.openHand.set()
        } else if videoRect(in: bounds).contains(p) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}

struct RedactVideoCanvas: NSViewRepresentable {
    @ObservedObject var model: RedactVideoModel

    func makeNSView(context: Context) -> RedactVideoCanvasView {
        let v = RedactVideoCanvasView(model: model)
        model.onRedraw = { [weak v] in v?.refresh() }
        return v
    }

    func updateNSView(_ v: RedactVideoCanvasView, context: Context) {
        v.refresh()
    }
}
