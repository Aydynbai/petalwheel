import AppKit
import Combine
import UniformTypeIdentifiers

/// Interactive canvas of the Annotate editor.
final class AnnotateCanvasView: ImageCanvasView, NSTextViewDelegate {
    private let model: AnnotateModel
    private var observers: Set<AnyCancellable> = []

    private enum Drag {
        case none
        case creating(AnnotateItem, start: CGPoint)
        case moving(original: AnnotateItem, start: CGPoint)
        case resizing(original: AnnotateItem, handle: Int)
        case panning(start: CGPoint)
    }
    private var drag: Drag = .none
    private var draft: AnnotateItem?
    private var textEditor: NSTextView?
    /// Undo is recorded lazily on the first real drag movement so plain clicks don't add empty steps.
    private var didPushDragUndo = false

    init(model: AnnotateModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        showsCheckerboard = ImageCodec.hasAlpha(model.fullImage)
        imageSize = model.imageSize
        onZoomChange = { [weak self] z in self?.model.zoomPercent = Int((z * 100).rounded()) }
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.modelChanged() }
            .store(in: &observers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func modelChanged() {
        needsDisplay = true
        if let tv = textEditor, let id = model.editingTextID, case let .text(t)? = model.item(id)?.shape {
            styleEditor(tv, text: t, color: model.item(id)!.color)
        } else if textEditor != nil, model.editingTextID == nil || model.item(model.editingTextID!) == nil {
            endTextEditing()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    override func drawContent(_ ctx: CGContext) {
        let size = model.imageSize
        ImageCanvasIO.drawImage(model.preview, in: CGRect(origin: .zero, size: size), ctx: ctx)
        var items = model.items
        if let d = draft { items.append(d) }
        AnnotateRenderer.draw(items, base: model.preview, imageSize: size, in: ctx, skipping: model.editingTextID)
    }

    override func drawOverlay(_ ctx: CGContext) {
        if let id = model.editingTextID, let it = model.item(id) {
            Self.drawSelectionBox(ctx, toView(AnnotateRenderer.bounds(it)).insetBy(dx: -3, dy: -3))
            return
        }
        guard let it = model.selectedItem else { return }
        switch it.shape {
        case .arrow: break
        case .rectangle, .ellipse: break
        default: Self.drawSelectionBox(ctx, toView(AnnotateRenderer.bounds(it)).insetBy(dx: -3, dy: -3))
        }
        for h in handles(for: it) { Self.drawHandle(ctx, at: toView(h)) }
    }

    // MARK: Handles

    private func handles(for it: AnnotateItem) -> [CGPoint] {
        switch it.shape {
        case let .arrow(a, b): return [a, b]
        case let .rectangle(r), let .ellipse(r), let .sticker(r, _): return ImageCanvasGeometry.corners(of: r)
        case let .text(t):
            let r = AnnotateRenderer.textRect(t)
            return [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
        case let .magnifier(c, r, _):
            return [CGPoint(x: c.x + r * 0.7071, y: c.y + r * 0.7071)]
        default: return []
        }
    }

    private func resized(_ it: AnnotateItem, handle: Int, to p: CGPoint, shift: Bool) -> AnnotateItem {
        var c = it
        let minSize = 4 * model.unit
        switch it.shape {
        case let .arrow(a, b):
            if handle == 0 { c.shape = .arrow(shift ? ImageCanvasGeometry.snap45(from: b, to: p) : p, b) }
            else { c.shape = .arrow(a, shift ? ImageCanvasGeometry.snap45(from: a, to: p) : p) }
        case let .rectangle(r):
            c.shape = .rectangle(ImageCanvasGeometry.resize(r, handle: handle, to: p, keepAspect: shift, minSize: minSize))
        case let .ellipse(r):
            c.shape = .ellipse(ImageCanvasGeometry.resize(r, handle: handle, to: p, keepAspect: shift, minSize: minSize))
        case let .sticker(r, img):
            c.shape = .sticker(rect: ImageCanvasGeometry.resize(r, handle: handle, to: p, keepAspect: !shift, minSize: minSize), image: img)
        case var .text(t):
            let minW = max(t.fontSize, 24 * model.unit)
            if handle == 0 {
                let right = t.origin.x + t.width
                let x = min(p.x, right - minW)
                t.origin.x = x
                t.width = right - x
            } else {
                t.width = max(minW, p.x - t.origin.x)
            }
            c.shape = .text(t)
        case let .magnifier(center, _, z):
            c.shape = .magnifier(center: center, radius: max(12 * model.unit, ImageCanvasGeometry.distance(center, p)), zoom: z)
        default: break
        }
        return c
    }

    private func hitItem(at p: CGPoint) -> AnnotateItem? {
        let tol = 5 / zoom
        return model.items.reversed().first { AnnotateRenderer.hitTest($0, p, tolerance: tol) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if textEditor != nil { endTextEditing() }
        window?.makeFirstResponder(self)
        let vp = viewPoint(event)
        let p = toImage(vp)
        didPushDragUndo = false

        // 1. Handles of the selected item win in every tool.
        if let sel = model.selectedItem, let h = handleIndex(at: vp, handles: handles(for: sel)) {
            drag = .resizing(original: sel, handle: h)
            return
        }

        let tool = model.tool
        switch tool {
        case .select, .sticker:
            if let hit = hitItem(at: p) {
                model.select(hit.id)
                if event.clickCount == 2, hit.isText { beginTextEditing(hit.id); return }
                drag = .moving(original: hit, start: p)
            } else {
                model.select(nil)
                drag = .panning(start: vp)
            }

        case .text:
            if let hit = hitItem(at: p), hit.isText {
                // Click on an existing text with the text tool edits it (see mouseUp); a drag moves it.
                model.select(hit.id)
                drag = .moving(original: hit, start: p)
                return
            }
            let width = min(max(model.imageSize.width - p.x, 80 * model.unit), 420 * model.unit)
            let t = AnnotateText(origin: CGPoint(x: p.x, y: p.y - model.fontPixelSize * 0.6), width: width, string: "",
                                 fontSize: model.fontPixelSize, family: model.fontFamily)
            let item = AnnotateItem(shape: .text(t), color: model.color, lineWidth: model.lineWidth)
            model.add(item)
            beginTextEditing(item.id)

        case .step:
            if let hit = hitItem(at: p), case .step = hit.shape {
                model.select(hit.id)
                drag = .moving(original: hit, start: p)
                return
            }
            let item = AnnotateItem(shape: .step(center: p, number: model.nextStepNumber, radius: model.stepRadius),
                                    color: model.color, lineWidth: model.lineWidth)
            model.add(item)
            didPushDragUndo = true
            drag = .moving(original: item, start: p)

        case .magnifier:
            if let hit = hitItem(at: p), case .magnifier = hit.shape {
                model.select(hit.id)
                drag = .moving(original: hit, start: p)
                return
            }
            let item = AnnotateItem(shape: .magnifier(center: p, radius: model.defaultMagnifierRadius, zoom: CGFloat(model.magnifierZoom)),
                                    color: model.color, lineWidth: model.lineWidth)
            draft = item
            drag = .creating(item, start: p)

        case .arrow, .pen, .highlighter, .rectangle, .ellipse:
            let shape: AnnotateItem.Shape
            switch tool {
            case .arrow: shape = .arrow(p, p)
            case .pen: shape = .pen([p])
            case .highlighter: shape = .highlighter([p])
            case .rectangle: shape = .rectangle(CGRect(origin: p, size: .zero))
            default: shape = .ellipse(CGRect(origin: p, size: .zero))
            }
            let item = AnnotateItem(shape: shape, color: model.color, lineWidth: model.lineWidth)
            model.select(nil)
            draft = item
            drag = .creating(item, start: p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let vp = viewPoint(event)
        let p = toImage(vp)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none: return
        case let .panning(start):
            panBy(vp.x - start.x, vp.y - start.y)
            drag = .panning(start: vp)
        case let .moving(original, start):
            if !didPushDragUndo { model.pushUndo(); didPushDragUndo = true }
            model.replace(original.offset(by: CGPoint(x: p.x - start.x, y: p.y - start.y)))
        case let .resizing(original, handle):
            if !didPushDragUndo { model.pushUndo(); didPushDragUndo = true }
            model.replace(resized(original, handle: handle, to: p, shift: shift))
        case let .creating(item, start):
            var d = draft ?? item
            switch item.shape {
            case .arrow: d.shape = .arrow(start, shift ? ImageCanvasGeometry.snap45(from: start, to: p) : p)
            case .rectangle: d.shape = .rectangle(ImageCanvasGeometry.rect(start, p, square: shift))
            case .ellipse: d.shape = .ellipse(ImageCanvasGeometry.rect(start, p, square: shift))
            case let .pen(ps):
                if let last = ps.last, ImageCanvasGeometry.distance(last, p) < 1.5 / zoom { return }
                d.shape = .pen(ps + [shift ? CGPoint(x: p.x, y: ps[0].y) : p])
            case let .highlighter(ps):
                if let last = ps.last, ImageCanvasGeometry.distance(last, p) < 1.5 / zoom { return }
                // Shift keeps the marker on a straight horizontal line.
                d.shape = .highlighter(shift ? [ps[0], CGPoint(x: p.x, y: ps[0].y)] : ps + [p])
            case let .magnifier(c, _, z):
                let r = ImageCanvasGeometry.distance(c, p)
                d.shape = .magnifier(center: c, radius: r < 8 * model.unit ? model.defaultMagnifierRadius : r, zoom: z)
            default: break
            }
            draft = d
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none; draft = nil; needsDisplay = true }
        guard case .creating = drag, var d = draft else {
            // A click (no drag) on a text with the text tool starts editing it.
            if case let .moving(original, _) = drag, model.tool == .text, original.isText, !didPushDragUndo {
                beginTextEditing(original.id)
            }
            return
        }
        let minLen = 3 / zoom
        switch d.shape {
        case let .arrow(a, b): guard ImageCanvasGeometry.distance(a, b) > max(minLen, d.lineWidth) else { return }
        case let .rectangle(r), let .ellipse(r): guard r.width > minLen, r.height > minLen else { return }
        case let .pen(ps): d.shape = .pen(AnnotateRenderer.smoothed(ps))
        case let .highlighter(ps): d.shape = .highlighter(AnnotateRenderer.smoothed(ps))
        default: break
        }
        model.add(d)
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = imagePoint(event)
        guard let hit = hitItem(at: p) else { return }
        model.select(hit.id)
        let menu = NSMenu()
        menu.addItem(withTitle: L("Bring to Front"), action: #selector(menuFront), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Delete"), action: #selector(menuDelete), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuFront() { model.bringSelectedToFront() }
    @objc private func menuDelete() { model.deleteSelected() }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool {
        case .select, .sticker: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    func toolChanged() {
        endTextEditing()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Keyboard helpers

    func nudgeSelection(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        guard let it = model.selectedItem, textEditor == nil else { return false }
        model.pushUndo(coalesce: "nudge-\(it.id)")
        model.replace(it.offset(by: CGPoint(x: dx * model.unit, y: dy * model.unit)))
        return true
    }

    func pasteSticker() {
        let pb = NSPasteboard.general
        var image: CGImage?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let u = urls.first {
            image = try? ImageCodec.load(u).image
        }
        if image == nil, let ns = NSImage(pasteboard: pb) {
            image = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let img = image else { NSSound.beep(); return }
        model.addSticker(img, center: visibleImageCenter)
    }

    func chooseSticker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("Choose an image to place as a sticker")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let u = panel.url, let self else { return }
            guard let img = try? ImageCodec.load(u).image else { NSSound.beep(); return }
            self.model.addSticker(img, center: self.visibleImageCenter)
        }
    }

    // MARK: Inline text editing

    func beginTextEditing(_ id: UUID) {
        guard case let .text(t)? = model.item(id)?.shape, let color = model.item(id)?.color else { return }
        endTextEditing()
        model.select(id)
        model.editingTextID = id
        let tv = NSTextView(frame: .zero)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.string = t.string
        tv.delegate = self
        styleEditor(tv, text: t, color: color)
        addSubview(tv)
        textEditor = tv
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        needsDisplay = true
    }

    private func styleEditor(_ tv: NSTextView, text t: AnnotateText, color: ImageCanvasRGBA) {
        let font = t.family.font(size: t.fontSize * zoom)
        if tv.font != font { tv.font = font }
        tv.textColor = color.nsColor
        tv.insertionPointColor = color.luminance > 0.85 ? KQTheme.accentNS : color.nsColor
        tv.typingAttributes = [.font: font, .foregroundColor: color.nsColor]
        let origin = toView(t.origin)
        let h = AnnotateRenderer.textHeight(t) * zoom
        let f = CGRect(x: origin.x, y: origin.y, width: max(10, t.width * zoom), height: h + 4)
        if tv.frame != f { tv.frame = f }
    }

    func endTextEditing() {
        guard let tv = textEditor else { return }
        textEditor = nil
        let id = model.editingTextID
        model.editingTextID = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        if let id, case let .text(t)? = model.item(id)?.shape, t.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.remove(id, recordUndo: false)
        }
        if window?.firstResponder == nil || window?.firstResponder === tv { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textEditor, let id = model.editingTextID else { return }
        model.update(id) { item in
            if case var .text(t) = item.shape { t.string = tv.string; item.shape = .text(t) }
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        // Focus moved elsewhere (e.g. a toolbar control): keep the editor until the canvas is clicked,
        // unless the text view is gone from the hierarchy.
    }

    override func zoomDidChange() {
        super.zoomDidChange()
        if let tv = textEditor, let id = model.editingTextID, let it = model.item(id), case let .text(t) = it.shape {
            styleEditor(tv, text: t, color: it.color)
        }
    }
}
