import AppKit
import SwiftUI

// Annotate editor: tools, items and the edit model (the renderer is in AnnotateRenderer.swift).
// All geometry is in IMAGE pixel coordinates with a top-left origin.

enum AnnotateTool: String, CaseIterable, Identifiable {
    case select, arrow, pen, rectangle, ellipse, highlighter, text, step, magnifier, sticker
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .magnifier: return "plus.magnifyingglass"
        case .sticker: return "photo.on.rectangle"
        }
    }

    var title: String {
        switch self {
        case .select: return L("Select & Move (V)")
        case .arrow: return L("Arrow (A)")
        case .pen: return L("Pen (P)")
        case .rectangle: return L("Rectangle (R)")
        case .ellipse: return L("Ellipse (O)")
        case .highlighter: return L("Highlighter (H)")
        case .text: return L("Text (T)")
        case .step: return L("Numbered Step (N)")
        case .magnifier: return L("Magnifier (M)")
        case .sticker: return L("Image Sticker (⌘V to paste)")
        }
    }

    var shortcut: String? {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .pen: return "p"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .highlighter: return "h"
        case .text: return "t"
        case .step: return "n"
        case .magnifier: return "m"
        case .sticker: return nil
        }
    }
}

enum AnnotateFontFamily: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("System")
        case .rounded: return L("Rounded")
        case .serif: return L("Serif")
        case .mono: return L("Mono")
        }
    }

    func font(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let design: NSFontDescriptor.SystemDesign
        switch self {
        case .system: return base
        case .rounded: design = .rounded
        case .serif: design = .serif
        case .mono: design = .monospaced
        }
        guard let d = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}

struct AnnotateText {
    var origin: CGPoint
    var width: CGFloat
    var string: String
    var fontSize: CGFloat
    var family: AnnotateFontFamily
}

struct AnnotateItem: Identifiable {
    enum Shape {
        case arrow(CGPoint, CGPoint)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case rectangle(CGRect)
        case ellipse(CGRect)
        case text(AnnotateText)
        case step(center: CGPoint, number: Int, radius: CGFloat)
        case magnifier(center: CGPoint, radius: CGFloat, zoom: CGFloat)
        case sticker(rect: CGRect, image: CGImage)
    }

    let id: UUID
    var shape: Shape
    var color: ImageCanvasRGBA
    var lineWidth: CGFloat

    init(id: UUID = UUID(), shape: Shape, color: ImageCanvasRGBA, lineWidth: CGFloat) {
        self.id = id; self.shape = shape; self.color = color; self.lineWidth = lineWidth
    }

    var isText: Bool { if case .text = shape { return true }; return false }

    func offset(by d: CGPoint) -> AnnotateItem {
        var c = self
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        switch shape {
        case let .arrow(a, b): c.shape = .arrow(m(a), m(b))
        case let .pen(ps): c.shape = .pen(ps.map(m))
        case let .highlighter(ps): c.shape = .highlighter(ps.map(m))
        case let .rectangle(r): c.shape = .rectangle(r.offsetBy(dx: d.x, dy: d.y))
        case let .ellipse(r): c.shape = .ellipse(r.offsetBy(dx: d.x, dy: d.y))
        case var .text(t): t.origin = m(t.origin); c.shape = .text(t)
        case let .step(p, n, r): c.shape = .step(center: m(p), number: n, radius: r)
        case let .magnifier(p, r, z): c.shape = .magnifier(center: m(p), radius: r, zoom: z)
        case let .sticker(r, img): c.shape = .sticker(rect: r.offsetBy(dx: d.x, dy: d.y), image: img)
        }
        return c
    }
}

// MARK: - Model

@MainActor
final class AnnotateModel: ObservableObject {
    let sourceURL: URL
    let fullImage: CGImage
    let preview: CGImage
    let properties: [CFString: Any]
    let ignoredCount: Int
    /// Image pixels per "UI point" so default sizes look the same on small and huge images.
    let unit: CGFloat
    var imageSize: CGSize { CGSize(width: fullImage.width, height: fullImage.height) }

    @Published var items: [AnnotateItem] = []
    @Published var selectedID: UUID?
    @Published var editingTextID: UUID?
    @Published var tool: AnnotateTool = .arrow
    @Published private(set) var color: ImageCanvasRGBA = .red
    @Published private(set) var widthLevel: Double = 4
    @Published private(set) var fontSize: Double = 32
    @Published private(set) var fontFamily: AnnotateFontFamily = .system
    @Published private(set) var magnifierZoom: Double = 2
    @Published var zoomPercent = 100
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [[AnnotateItem]] = []
    private var redoStack: [[AnnotateItem]] = []
    private var lastCoalesceKey: String?

    init(url: URL, image: LoadedImage, preview: CGImage, ignoredCount: Int) {
        sourceURL = url
        fullImage = image.image
        self.preview = preview
        properties = image.properties
        self.ignoredCount = ignoredCount
        unit = max(1, CGFloat(max(image.width, image.height)) / 1200)
    }

    var lineWidth: CGFloat { CGFloat(widthLevel) * unit }
    var fontPixelSize: CGFloat { CGFloat(fontSize) * unit }
    var stepRadius: CGFloat { (8 + CGFloat(widthLevel) * 2) * unit }
    var defaultMagnifierRadius: CGFloat { 90 * unit }

    var selectedItem: AnnotateItem? { items.first { $0.id == selectedID } }
    func item(_ id: UUID) -> AnnotateItem? { items.first { $0.id == id } }

    var nextStepNumber: Int {
        items.reduce(0) { m, it in
            if case let .step(_, n, _) = it.shape { return max(m, n) }
            return m
        } + 1
    }

    // MARK: Undo

    /// Snapshot before a mutation. Consecutive pushes with the same coalesce key collapse into one step.
    func pushUndo(coalesce key: String? = nil) {
        if let key, key == lastCoalesceKey { return }
        lastCoalesceKey = key
        undoStack.append(items)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndoFlags()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(items)
        items = prev
        afterHistoryJump()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        afterHistoryJump()
    }

    private func afterHistoryJump() {
        lastCoalesceKey = nil
        if let s = selectedID, item(s) == nil { selectedID = nil }
        refreshUndoFlags()
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Mutations

    func add(_ item: AnnotateItem) {
        pushUndo()
        items.append(item)
        selectedID = item.id
    }

    func update(_ id: UUID, _ change: (inout AnnotateItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items[i]
        change(&it)
        items[i] = it
    }

    func replace(_ item: AnnotateItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
    }

    func remove(_ id: UUID, recordUndo: Bool = true) {
        guard items.contains(where: { $0.id == id }) else { return }
        if recordUndo { pushUndo() }
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        remove(id)
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        pushUndo()
        items.removeAll()
        selectedID = nil
    }

    func bringSelectedToFront() {
        guard let id = selectedID, let i = items.firstIndex(where: { $0.id == id }), i != items.count - 1 else { return }
        pushUndo()
        let it = items.remove(at: i)
        items.append(it)
    }

    func select(_ id: UUID?) {
        selectedID = id
        guard let id, let it = item(id) else { return }
        // Reflect the item's style in the toolbar without modifying it.
        color = it.color
        switch it.shape {
        case let .text(t):
            fontSize = Double(t.fontSize / unit)
            fontFamily = t.family
        case let .magnifier(_, _, z):
            magnifierZoom = Double(z)
        case let .step(_, _, r):
            widthLevel = max(1, min(20, Double((r / unit - 8) / 2)))
        case .sticker:
            break
        default:
            widthLevel = max(1, min(20, Double(it.lineWidth / unit)))
        }
        lastCoalesceKey = nil
    }

    // MARK: Style (applies to the selection too)

    func applyColor(_ c: ImageCanvasRGBA) {
        color = c
        guard let id = selectedID else { return }
        pushUndo(coalesce: "color-\(id)")
        update(id) { $0.color = c }
    }

    func applyWidth(_ level: Double) {
        widthLevel = level
        guard let id = selectedID, let it = item(id) else { return }
        pushUndo(coalesce: "width-\(id)")
        switch it.shape {
        case let .step(c, n, _): update(id) { $0.shape = .step(center: c, number: n, radius: self.stepRadius) }
        case .text, .sticker: break
        default: update(id) { $0.lineWidth = self.lineWidth }
        }
    }

    func applyFontSize(_ size: Double) {
        fontSize = size
        guard let id = selectedID, case var .text(t) = item(id)?.shape else { return }
        pushUndo(coalesce: "font-\(id)")
        t.fontSize = fontPixelSize
        update(id) { $0.shape = .text(t) }
    }

    func applyFontFamily(_ family: AnnotateFontFamily) {
        fontFamily = family
        guard let id = selectedID, case var .text(t) = item(id)?.shape else { return }
        pushUndo(coalesce: "family-\(id)")
        t.family = family
        update(id) { $0.shape = .text(t) }
    }

    func applyMagnifierZoom(_ z: Double) {
        magnifierZoom = z
        guard let id = selectedID, case let .magnifier(c, r, _) = item(id)?.shape else { return }
        pushUndo(coalesce: "mag-\(id)")
        update(id) { $0.shape = .magnifier(center: c, radius: r, zoom: CGFloat(z)) }
    }

    /// Which contextual controls the toolbar shows.
    var styleContext: AnnotateTool {
        if let it = selectedItem {
            switch it.shape {
            case .text: return .text
            case .magnifier: return .magnifier
            case .sticker: return .sticker
            case .step: return .step
            default: return .pen
            }
        }
        return tool
    }

    // MARK: Stickers

    func addSticker(_ image: CGImage, center: CGPoint) {
        let maxW = imageSize.width * 0.4, maxH = imageSize.height * 0.4
        let s = min(1, maxW / CGFloat(image.width), maxH / CGFloat(image.height))
        let w = max(8, CGFloat(image.width) * s), h = max(8, CGFloat(image.height) * s)
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        add(AnnotateItem(shape: .sticker(rect: rect, image: image), color: color, lineWidth: 0))
        tool = .select
    }

    // MARK: Export

    /// Items that end up in the saved image (empty text boxes are dropped).
    private var exportedItems: [AnnotateItem] {
        items.filter { item in
            if case let .text(t) = item.shape { return !t.string.isEmpty }
            return true
        }
    }

    /// Anything drawn that Save would flatten into the image.
    var hasUnsavedChanges: Bool { !exportedItems.isEmpty }

    /// Immutable snapshot of the edit state → self-contained export.
    func makeExport() -> EditorExport? {
        let items = exportedItems
        let image = fullImage, url = sourceURL, props = properties
        return { progress in
            try await Task.detached(priority: .userInitiated) { () throws -> [URL] in
                progress(0.05)
                let flattened = try AnnotateRenderer.renderFlattened(image: image, items: items)
                progress(0.6)
                let meta = ImageCodec.carriedMetadata(props, width: flattened.width, height: flattened.height)
                let out = try ImageCanvasIO.write(flattened, nextTo: url, suffix: "annotated", metadata: meta)
                progress(1)
                return [out]
            }.value
        }
    }
}
