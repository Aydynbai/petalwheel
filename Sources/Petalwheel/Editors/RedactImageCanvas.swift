import AppKit
import Combine
import CoreImage
import Vision

// Redact Image editor: model, renderer (shared by the live preview and the export) and canvas.
// Regions are stored in IMAGE pixel coordinates with a top-left origin.

struct RedactImageRegion: Identifiable, Equatable {
    let id: UUID
    var rect: CGRect
    var style: RedactionStyle
    /// 0…1, used by blur and pixelate.
    var strength: Double
    /// Fill of the solid style.
    var color: ImageCanvasRGBA

    init(id: UUID = UUID(), rect: CGRect, style: RedactionStyle, strength: Double, color: ImageCanvasRGBA) {
        self.id = id; self.rect = rect; self.style = style; self.strength = strength; self.color = color
    }
}

enum RedactImageRenderer {
    static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               .cacheIntermediates: false])

    /// Effect sizes are relative to the long side of the image, so preview and export match.
    static func blurSigma(strength: Double, longSide: CGFloat) -> Double {
        Double(longSide) * (0.002 + 0.02 * strength)
    }

    static func pixelScale(strength: Double, longSide: CGFloat) -> Double {
        max(2, Double(longSide) * (0.006 + 0.04 * strength))
    }

    /// The whole image with one effect applied (clamped first so edges never pull in transparent black, then cropped).
    static func effectImage(_ base: CIImage, style: RedactionStyle, strength: Double, longSide: CGFloat) -> CIImage {
        let extent = base.extent
        switch style {
        case .blur:
            return base.clampedToExtent()
                .applyingGaussianBlur(sigma: blurSigma(strength: strength, longSide: longSide))
                .cropped(to: extent)
        case .pixelate:
            return base.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: pixelScale(strength: strength, longSide: longSide),
                                                            kCIInputCenterKey: CIVector(x: extent.minX, y: extent.minY)])
                .cropped(to: extent)
        case .solid:
            return base
        }
    }

    /// Renders a preview-sized effect layer for the canvas.
    static func previewEffect(_ preview: CGImage, style: RedactionStyle, strength: Double) -> CGImage? {
        guard style != .solid else { return nil }
        let ci = CIImage(cgImage: preview)
        let out = effectImage(ci, style: style, strength: strength, longSide: CGFloat(max(preview.width, preview.height)))
        return ciContext.createCGImage(out, from: ci.extent, format: .RGBA8, colorSpace: ImageCanvasIO.colorSpace(of: preview))
    }

    /// Full-resolution redaction. `regions` are in top-left image coordinates.
    static func render(image: CGImage, regions: [RedactImageRegion]) throws -> CGImage {
        let base = CIImage(cgImage: image)
        let extent = base.extent
        let h = extent.height
        let longSide = max(extent.width, extent.height)
        var result = base
        var cache: [String: CIImage] = [:]
        for r in regions {
            // Top-left → CoreImage's bottom-left coordinates.
            let ciRect = CGRect(x: r.rect.minX, y: h - r.rect.maxY, width: r.rect.width, height: r.rect.height)
                .integral.intersection(extent)
            guard !ciRect.isNull, ciRect.width > 0, ciRect.height > 0 else { continue }
            let layer: CIImage
            if r.style == .solid {
                layer = CIImage(color: CIColor(cgColor: r.color.cgColor))
            } else {
                let key = "\(r.style.rawValue)-\(r.strength)"
                if let c = cache[key] { layer = c } else {
                    layer = effectImage(base, style: r.style, strength: r.strength, longSide: longSide)
                    cache[key] = layer
                }
            }
            result = layer.cropped(to: ciRect).composited(over: result)
        }
        let opaque = !ImageCodec.hasAlpha(image)
        if opaque { result = result.settingAlphaOne(in: extent) }
        guard let cg = ciContext.createCGImage(result, from: extent, format: .RGBA8,
                                               colorSpace: ImageCanvasIO.colorSpace(of: image)) else {
            throw NurToError(l: "Could not render the redacted image.")
        }
        return cg
    }
}

// MARK: - Model

@MainActor
final class RedactImageModel: ObservableObject {
    let sourceURL: URL
    let fullImage: CGImage
    let preview: CGImage
    let ignoredCount: Int
    var imageSize: CGSize { CGSize(width: fullImage.width, height: fullImage.height) }
    let unit: CGFloat

    @Published var regions: [RedactImageRegion] = []
    @Published var selectedID: UUID?
    @Published private(set) var style: RedactionStyle = .blur
    @Published private(set) var strength: Double = 0.5
    @Published private(set) var solidColor: ImageCanvasRGBA = .black
    @Published var zoomPercent = 100
    @Published var busy: String?
    @Published var status: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [[RedactImageRegion]] = []
    private var redoStack: [[RedactImageRegion]] = []
    private var lastCoalesceKey: String?
    private var effectCache: [String: CGImage] = [:]

    init(url: URL, image: CGImage, preview: CGImage, ignoredCount: Int) {
        sourceURL = url
        fullImage = image
        self.preview = preview
        self.ignoredCount = ignoredCount
        unit = max(1, CGFloat(max(image.width, image.height)) / 1200)
    }

    var selected: RedactImageRegion? { regions.first { $0.id == selectedID } }

    /// Preview-resolution effect layer for a style/strength (cached).
    func previewEffect(style: RedactionStyle, strength: Double) -> CGImage? {
        guard style != .solid else { return nil }
        let key = "\(style.rawValue)-\(strength)"
        if let c = effectCache[key] { return c }
        guard let img = RedactImageRenderer.previewEffect(preview, style: style, strength: strength) else { return nil }
        if effectCache.count > 12 { effectCache.removeAll() }
        effectCache[key] = img
        return img
    }

    // MARK: Undo

    func pushUndo(coalesce key: String? = nil) {
        if let key, key == lastCoalesceKey { return }
        lastCoalesceKey = key
        undoStack.append(regions)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        refresh()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(regions)
        regions = prev
        lastCoalesceKey = nil
        if let s = selectedID, !regions.contains(where: { $0.id == s }) { selectedID = nil }
        refresh()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(regions)
        regions = next
        lastCoalesceKey = nil
        if let s = selectedID, !regions.contains(where: { $0.id == s }) { selectedID = nil }
        refresh()
    }

    private func refresh() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Mutations

    func newRegion(_ rect: CGRect) -> RedactImageRegion {
        RedactImageRegion(rect: rect, style: style, strength: strength, color: solidColor)
    }

    func add(_ rs: [RedactImageRegion]) {
        guard !rs.isEmpty else { return }
        pushUndo()
        regions.append(contentsOf: rs)
        selectedID = rs.count == 1 ? rs[0].id : nil
    }

    func replace(_ r: RedactImageRegion) {
        guard let i = regions.firstIndex(where: { $0.id == r.id }) else { return }
        regions[i] = r
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        regions.removeAll { $0.id == id }
        selectedID = nil
    }

    func clearAll() {
        guard !regions.isEmpty else { return }
        pushUndo()
        regions.removeAll()
        selectedID = nil
    }

    func select(_ id: UUID?) {
        selectedID = id
        lastCoalesceKey = nil
        guard let r = selected else { return }
        style = r.style
        strength = r.strength
        solidColor = r.color
    }

    func applyStyle(_ s: RedactionStyle) {
        style = s
        guard let id = selectedID else { return }
        pushUndo(coalesce: "style-\(id)")
        if let i = regions.firstIndex(where: { $0.id == id }) { regions[i].style = s }
    }

    func applyStrength(_ v: Double) {
        // Quantised so the preview cache stays small while dragging the slider.
        let q = (v * 20).rounded() / 20
        strength = q
        guard let id = selectedID else { return }
        pushUndo(coalesce: "strength-\(id)")
        if let i = regions.firstIndex(where: { $0.id == id }) { regions[i].strength = q }
    }

    func applyColor(_ c: ImageCanvasRGBA) {
        solidColor = c
        guard let id = selectedID else { return }
        pushUndo(coalesce: "color-\(id)")
        if let i = regions.firstIndex(where: { $0.id == id }) { regions[i].color = c; regions[i].style = .solid }
        style = .solid
    }

    /// Applies the current style to every region.
    func applyStyleToAll() {
        guard !regions.isEmpty else { return }
        pushUndo()
        for i in regions.indices {
            regions[i].style = style
            regions[i].strength = strength
            regions[i].color = solidColor
        }
    }

    // MARK: Detection

    /// Adds regions that don't substantially overlap existing ones.
    private func addDetected(_ rects: [CGRect]) -> Int {
        let bounds = CGRect(origin: .zero, size: imageSize)
        var fresh: [RedactImageRegion] = []
        for r in rects {
            let r = r.intersection(bounds)
            guard !r.isNull, r.width > 2, r.height > 2 else { continue }
            let dup = (regions + fresh).contains { existing in
                let inter = existing.rect.intersection(r)
                guard !inter.isNull else { return false }
                return inter.width * inter.height > 0.6 * min(r.width * r.height, existing.rect.width * existing.rect.height)
            }
            if !dup { fresh.append(newRegion(r)) }
        }
        add(fresh)
        return fresh.count
    }

    func detectFaces() {
        guard busy == nil else { return }
        busy = L("Detecting faces…")
        status = nil
        let image = fullImage
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[CGRect], Error> in
                Result { try RedactImageModel.faceRects(in: image) }
            }.value
            guard let self else { return }
            self.busy = nil
            switch result {
            case .success(let rects):
                let n = self.addDetected(rects)
                self.status = rects.isEmpty ? L("No faces found") : Lp("Added %d face regions", n)
            case .failure(let e):
                self.status = L("Face detection failed: %@", e.localizedDescription)
            }
        }
    }

    func detectText() {
        guard busy == nil else { return }
        busy = L("Detecting text…")
        status = nil
        let image = fullImage
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[CGRect], Error> in
                Result { try RedactImageModel.textRects(in: image) }
            }.value
            guard let self else { return }
            self.busy = nil
            switch result {
            case .success(let rects):
                let n = self.addDetected(rects)
                self.status = rects.isEmpty ? L("No text found") : Lp("Added %d text regions", n)
            case .failure(let e):
                self.status = L("Text detection failed: %@", e.localizedDescription)
            }
        }
    }

    /// Face boxes (top-left coords), expanded to cover hair, chin and ears.
    nonisolated static func faceRects(in image: CGImage) throws -> [CGRect] {
        let h = CGFloat(image.height)
        return try VisionTools.faceRects(in: image).map { f in
            let r = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
            return CGRect(x: r.minX - r.width * 0.18, y: r.minY - r.height * 0.32,
                          width: r.width * 1.36, height: r.height * 1.5)
        }
    }

    /// Text line boxes (top-left coords), slightly padded.
    nonisolated static func textRects(in image: CGImage) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).map { o in
            let b = o.boundingBox
            let r = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            let pad = r.height * 0.18
            return r.insetBy(dx: -pad, dy: -pad)
        }
    }

    // MARK: Export

    /// Any region drawn or detected.
    var hasUnsavedChanges: Bool { !regions.isEmpty }

    func makeExport() -> EditorExport? {
        let regions = self.regions, image = fullImage, url = sourceURL
        return { progress in
            try await Task.detached(priority: .userInitiated) { () throws -> [URL] in
                progress(0.05)
                let out = try RedactImageRenderer.render(image: image, regions: regions)
                progress(0.7)
                // Location / camera metadata of a redacted image is deliberately not carried over.
                let file = try ImageCanvasIO.write(out, nextTo: url, suffix: "redacted", metadata: nil)
                progress(1)
                return [file]
            }.value
        }
    }
}

// MARK: - Canvas

final class RedactImageCanvasView: ImageCanvasView {
    private let model: RedactImageModel
    private var observers: Set<AnyCancellable> = []

    private enum Drag {
        case none
        case creating(start: CGPoint)
        case moving(original: RedactImageRegion, start: CGPoint)
        case resizing(original: RedactImageRegion, handle: Int)
    }
    private var drag: Drag = .none
    private var draftRect: CGRect?
    private var didPushDragUndo = false

    init(model: RedactImageModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        showsCheckerboard = ImageCodec.hasAlpha(model.fullImage)
        imageSize = model.imageSize
        onZoomChange = { [weak self] z in self?.model.zoomPercent = Int((z * 100).rounded()) }
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &observers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Drawing

    override func drawContent(_ ctx: CGContext) {
        let full = CGRect(origin: .zero, size: model.imageSize)
        ImageCanvasIO.drawImage(model.preview, in: full, ctx: ctx)
        var regions = model.regions
        if let d = draftRect { regions.append(model.newRegion(d)) }
        for r in regions {
            ctx.saveGState()
            ctx.clip(to: r.rect)
            if r.style == .solid {
                ctx.setFillColor(r.color.cgColor)
                ctx.fill(r.rect)
            } else if let effect = model.previewEffect(style: r.style, strength: r.strength) {
                ImageCanvasIO.drawImage(effect, in: full, ctx: ctx)
            }
            ctx.restoreGState()
        }
    }

    override func drawOverlay(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        for r in model.regions where r.id != model.selectedID {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.stroke(toView(r.rect).insetBy(dx: 0.5, dy: 0.5))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.setLineDash(phase: 4.5, lengths: [5, 4])
            ctx.stroke(toView(r.rect).insetBy(dx: 0.5, dy: 0.5))
        }
        ctx.restoreGState()
        if let d = draftRect { Self.drawSelectionBox(ctx, toView(d)) }
        if let sel = model.selected {
            let vr = toView(sel.rect)
            ctx.saveGState()
            ctx.setStrokeColor(KQTheme.accentNS.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(vr)
            ctx.restoreGState()
            for h in ImageCanvasGeometry.handlePoints(of: sel.rect) { Self.drawHandle(ctx, at: toView(h)) }
        }
    }

    // MARK: Mouse

    private func hitRegion(at p: CGPoint) -> RedactImageRegion? {
        let tol = 3 / zoom
        return model.regions.reversed().first { $0.rect.insetBy(dx: -tol, dy: -tol).contains(p) }
    }

    private func clampedToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(model.imageSize.width, p.x)), y: max(0, min(model.imageSize.height, p.y)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        didPushDragUndo = false
        let vp = viewPoint(event)
        let p = toImage(vp)
        if let sel = model.selected, let h = handleIndex(at: vp, handles: ImageCanvasGeometry.handlePoints(of: sel.rect)) {
            drag = .resizing(original: sel, handle: h)
            return
        }
        if let hit = hitRegion(at: p) {
            model.select(hit.id)
            drag = .moving(original: hit, start: p)
            return
        }
        model.select(nil)
        drag = .creating(start: clampedToImage(p))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        switch drag {
        case .none: return
        case let .creating(start):
            draftRect = ImageCanvasGeometry.rect(start, clampedToImage(p), square: event.modifierFlags.contains(.shift))
        case let .moving(original, start):
            if !didPushDragUndo { model.pushUndo(); didPushDragUndo = true }
            var r = original
            r.rect = original.rect.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            model.replace(r)
        case let .resizing(original, handle):
            if !didPushDragUndo { model.pushUndo(); didPushDragUndo = true }
            var r = original
            r.rect = ImageCanvasGeometry.resize(original.rect, handle: handle, to: clampedToImage(p),
                                                keepAspect: event.modifierFlags.contains(.shift), minSize: 4 * model.unit)
            model.replace(r)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none; draftRect = nil; needsDisplay = true }
        guard case .creating = drag, let d = draftRect, d.width * zoom > 4, d.height * zoom > 4 else { return }
        model.add([model.newRegion(d)])
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .crosshair)
    }

    func nudgeSelection(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        guard var r = model.selected else { return false }
        model.pushUndo(coalesce: "nudge-\(r.id)")
        r.rect = r.rect.offsetBy(dx: dx * model.unit, dy: dy * model.unit)
        model.replace(r)
        return true
    }
}
