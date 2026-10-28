import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Plan (immutable, sendable snapshot used by the export)

struct OrganizePDFSource {
    enum Kind { case pdf, image }
    let url: URL
    let kind: Kind

    static func kind(of url: URL) -> Kind? {
        guard let f = FileFormat.detect(url) else { return nil }
        if f == .pdf { return .pdf }
        if f.group == .images { return .image }
        return nil
    }
}

struct OrganizePDFPage: Identifiable, Equatable {
    let id: UUID
    /// Index into the source list.
    let source: Int
    let pageIndex: Int
    /// Extra rotation chosen in the editor (multiple of 90, 0…270), added to the page's own rotation.
    var rotation: Int

    init(source: Int, pageIndex: Int, rotation: Int = 0) {
        self.id = UUID()
        self.source = source
        self.pageIndex = pageIndex
        self.rotation = rotation
    }

    var originalNumber: Int { pageIndex + 1 }
    var thumbKey: String { "\(source):\(pageIndex)" }
}

struct OrganizePDFPlan {
    let sources: [OrganizePDFSource]
    let pages: [OrganizePDFPage]
    let sameWidth: Bool
    let output: URL
}

// MARK: - Export

enum OrganizePDFExporter {
    /// A page built from an image file: oriented, at most `maxSide` points on its long side.
    static func imagePage(_ url: URL, maxSide: CGFloat = 842) -> PDFPage? {
        guard let loaded = try? ImageCodec.load(url) else { return nil }
        let w = CGFloat(loaded.width), h = CGFloat(loaded.height)
        let s = min(1, maxSide / max(w, h))
        let image = NSImage(cgImage: ImageCodec.pdfFriendly(loaded.image), size: NSSize(width: w * s, height: h * s))
        return PDFPage(image: image)
    }

    /// Opens every source as a PDFDocument (an image becomes a one-page document).
    static func openSources(_ sources: [OrganizePDFSource]) throws -> [PDFDocument] {
        try sources.map { src in
            switch src.kind {
            case .pdf:
                return try PDFTools.open(src.url)
            case .image:
                guard let page = imagePage(src.url) else { throw PetalwheelError(l: "Could not read the image %@.", src.url.lastPathComponent) }
                let doc = PDFDocument()
                doc.insert(page, at: 0)
                return doc
            }
        }
    }

    /// Displayed size of a page (crop box with its rotation applied).
    static func displaySize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// The most common page width (rounded to whole points); ties go to the wider one.
    static func commonWidth(_ pages: [PDFPage]) -> CGFloat {
        var counts: [Int: Int] = [:]
        for p in pages { counts[Int(displaySize(p).width.rounded()), default: 0] += 1 }
        let best = counts.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }
        return CGFloat(best?.key ?? 612)
    }

    static func run(_ plan: OrganizePDFPlan, progress: @escaping ProgressHandler) throws -> URL {
        guard !plan.pages.isEmpty else { throw PetalwheelError(l: "There are no pages to save.") }
        let docs = try openSources(plan.sources)
        progress(0.1)
        var pages: [PDFPage] = []
        for (i, item) in plan.pages.enumerated() {
            try Task.checkCancellation()
            guard let original = docs[item.source].page(at: item.pageIndex),
                  let page = original.copy() as? PDFPage else {
                throw PetalwheelError(l: "Page %d of %@ is missing.", item.originalNumber, plan.sources[item.source].url.lastPathComponent)
            }
            page.rotation = ((original.rotation + item.rotation) % 360 + 360) % 360
            pages.append(page)
            progress(0.1 + 0.5 * Double(i + 1) / Double(plan.pages.count))
        }

        let dest = plan.output
        let out = PDFDocument()
        for page in pages { out.insert(page, at: out.pageCount) }
        if plan.sameWidth {
            try writeScaled(pages, width: commonWidth(pages), to: dest)
        } else {
            if let attrs = docs.first?.documentAttributes { out.documentAttributes = attrs }
            guard out.write(to: dest) else { throw PetalwheelError(l: "Could not write %@.", dest.lastPathComponent) }
        }
        progress(0.9)

        // Verify the result before reporting success.
        guard let check = PDFDocument(url: dest), check.pageCount == plan.pages.count else {
            try? FileManager.default.removeItem(at: dest)
            throw PetalwheelError(l: "The organized PDF could not be verified.")
        }
        progress(1)
        return dest
    }

    /// Redraws every page (vector, rotation baked in) scaled to a common width. Pages must belong to a document.
    static func writeScaled(_ pages: [PDFPage], width: CGFloat, to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw PetalwheelError(l: "Could not create %@.", url.lastPathComponent)
        }
        for page in pages {
            try Task.checkCancellation()
            let size = displaySize(page)
            let s = size.width > 0 ? width / size.width : 1
            var box = CGRect(x: 0, y: 0, width: width, height: (size.height * s).rounded())
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            ctx.saveGState()
            ctx.scaleBy(x: s, y: s)
            page.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func makeExport(_ plan: OrganizePDFPlan) -> EditorExport {
        { progress in
            let url = try await Task.detached(priority: .userInitiated) {
                try run(plan, progress: progress)
            }.value
            return [url]
        }
    }
}

// MARK: - Editor model

/// Hands a PDFPage to the thumbnail queue (each page is only rendered there once).
struct OrganizePDFPageRef: @unchecked Sendable {
    let page: PDFPage
}

@MainActor
final class OrganizePDFModel: ObservableObject {
    static let tagColors: [Color] = [
        KQTheme.accent, KQTheme.extract, KQTheme.optimize, KQTheme.combine,
        KQTheme.share, KQTheme.edit, KQTheme.presets,
    ]

    let inputs: [URL]
    private(set) var sources: [OrganizePDFSource] = []
    private(set) var docs: [PDFDocument] = []

    @Published private(set) var pages: [OrganizePDFPage] = []
    @Published var selection: Set<UUID> = []
    @Published var sameWidth = false
    @Published var thumbSize: CGFloat = 150
    @Published var previewID: UUID?
    @Published var dropIndex: Int?
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published var message: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var anchor: UUID?
    /// The page most recently clicked or reached with the arrow keys.
    private var cursor: UUID?
    private(set) var draggingIDs: [UUID] = []
    private var undoStack: [[OrganizePDFPage]] = []
    private var redoStack: [[OrganizePDFPage]] = []
    private var requested: Set<String> = []
    /// Pages as opened, to tell whether anything was changed.
    private var initialPages: [OrganizePDFPage] = []
    private let thumbQueue = DispatchQueue(label: "petalwheel.organize.thumbs", qos: .userInitiated)

    init(inputs: [URL]) {
        self.inputs = inputs
        var failed: [String] = []
        for url in inputs {
            if let new = addSource(url) { pages += new } else { failed.append(url.lastPathComponent) }
        }
        if !failed.isEmpty { message = L("Skipped: %@", failed.joined(separator: ", ")) }
        initialPages = pages
    }

    /// Pages reordered, rotated, removed or added, or the same-width option turned on.
    var hasUnsavedChanges: Bool { pages != initialPages || sameWidth }

    var hasMultipleSources: Bool { sources.count > 1 }

    func tagColor(_ source: Int) -> Color { Self.tagColors[source % Self.tagColors.count] }

    func index(of id: UUID) -> Int? { pages.firstIndex { $0.id == id } }

    var selectedIndices: [Int] { pages.indices.filter { selection.contains(pages[$0].id) } }

    // MARK: Sources

    /// Opens `url` as a new source and returns its pages (nil if unreadable).
    private func addSource(_ url: URL) -> [OrganizePDFPage]? {
        guard let kind = OrganizePDFSource.kind(of: url) else { return nil }
        let src = OrganizePDFSource(url: url, kind: kind)
        guard let doc = try? OrganizePDFExporter.openSources([src]).first, doc.pageCount > 0 else { return nil }
        let index = sources.count
        sources.append(src)
        docs.append(doc)
        return (0..<doc.pageCount).map { OrganizePDFPage(source: index, pageIndex: $0) }
    }

    func insertFiles(_ urls: [URL], at position: Int?) {
        var new: [OrganizePDFPage] = []
        var failed: [String] = []
        for url in urls {
            if let p = addSource(url) { new += p } else { failed.append(url.lastPathComponent) }
        }
        message = failed.isEmpty ? nil : L("Couldn't add: %@", failed.joined(separator: ", "))
        guard !new.isEmpty else { return }
        var next = pages
        next.insert(contentsOf: new, at: min(max(position ?? next.count, 0), next.count))
        commit(next)
        selection = Set(new.map(\.id))
        anchor = new.first?.id
    }

    func addFilesWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = L("Choose PDFs or images to add")
        guard panel.runModal() == .OK else { return }
        let insertAt = selectedIndices.last.map { $0 + 1 }
        insertFiles(panel.urls, at: insertAt)
    }

    // MARK: Thumbnails

    func requestThumbnail(_ item: OrganizePDFPage) {
        let key = item.thumbKey
        guard !requested.contains(key), let page = docs[item.source].page(at: item.pageIndex) else { return }
        requested.insert(key)
        let ref = OrganizePDFPageRef(page: page)
        thumbQueue.async { [weak self] in
            let img = ref.page.thumbnail(of: NSSize(width: 360, height: 360), for: .cropBox)
            DispatchQueue.main.async { self?.thumbnails[key] = img }
        }
    }

    /// Display aspect (w/h) of a page including its rotation.
    func aspect(_ item: OrganizePDFPage) -> CGFloat {
        guard let page = docs[item.source].page(at: item.pageIndex) else { return 0.77 }
        let s = OrganizePDFExporter.displaySize(page)
        let a = s.height > 0 ? s.width / s.height : 0.77
        return item.rotation % 180 == 0 ? a : 1 / a
    }

    // MARK: Selection

    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        cursor = id
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if modifiers.contains(.shift), let a = anchor, let i = index(of: a), let j = index(of: id) {
            selection = Set(pages[min(i, j)...max(i, j)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    func selectAll() { selection = Set(pages.map(\.id)) }

    func moveSelection(by delta: Int, extend: Bool) {
        guard !pages.isEmpty else { return }
        let current = (cursor ?? anchor).flatMap(index(of:)) ?? (delta > 0 ? -1 : pages.count)
        let next = min(max(current + delta, 0), pages.count - 1)
        let id = pages[next].id
        if extend && anchor != nil && previewID == nil {
            click(id, modifiers: .shift)
        } else {
            selection = [id]
            anchor = id
            cursor = id
        }
        if previewID != nil { previewID = id }
    }

    // MARK: Editing

    private func commit(_ next: [OrganizePDFPage]) {
        guard next != pages else { return }
        undoStack.append(pages)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        pages = next
        updateUndoState()
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(pages)
        pages = prev
        selection = selection.filter { id in prev.contains { $0.id == id } }
        updateUndoState()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pages)
        pages = next
        selection = selection.filter { id in next.contains { $0.id == id } }
        updateUndoState()
    }

    func rotateSelected(by degrees: Int) {
        guard !selection.isEmpty else { return }
        commit(pages.map { p in
            guard selection.contains(p.id) else { return p }
            var q = p
            q.rotation = ((q.rotation + degrees) % 360 + 360) % 360
            return q
        })
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        let firstIndex = selectedIndices.first ?? 0
        let next = pages.filter { !selection.contains($0.id) }
        commit(next)
        if previewID.map({ selection.contains($0) }) == true { previewID = nil }
        selection = next.isEmpty ? [] : [next[min(firstIndex, next.count - 1)].id]
        anchor = selection.first
    }

    func duplicateSelected() {
        guard !selection.isEmpty else { return }
        var next: [OrganizePDFPage] = []
        var copies: [UUID] = []
        for p in pages {
            next.append(p)
            if selection.contains(p.id) {
                let c = OrganizePDFPage(source: p.source, pageIndex: p.pageIndex, rotation: p.rotation)
                next.append(c)
                copies.append(c.id)
            }
        }
        commit(next)
        selection = Set(copies)
        anchor = copies.last
    }

    /// Moves `ids` (kept in their current order) so they land before the page now at `target`.
    func move(_ ids: [UUID], to target: Int) {
        let set = Set(ids)
        let moving = pages.filter { set.contains($0.id) }
        guard !moving.isEmpty else { return }
        var rest = pages.filter { !set.contains($0.id) }
        let before = pages[..<min(max(target, 0), pages.count)].filter { !set.contains($0.id) }.count
        rest.insert(contentsOf: moving, at: before)
        commit(rest)
    }

    // MARK: Drag & drop

    func beginDrag(_ id: UUID) {
        if !selection.contains(id) { selection = [id]; anchor = id }
        draggingIDs = pages.filter { selection.contains($0.id) }.map(\.id)
    }

    func endDrag() {
        draggingIDs = []
        dropIndex = nil
    }

    /// Handles a drop at insertion index `target`: internal page moves, or PDF/image files from Finder.
    func performDrop(_ info: DropInfo, at target: Int) -> Bool {
        defer { dropIndex = nil }
        let fileProviders = info.itemProviders(for: [.fileURL])
        if !fileProviders.isEmpty {
            draggingIDs = []
            loadURLs(fileProviders) { [weak self] urls in self?.insertFiles(urls, at: target) }
            return true
        }
        guard !draggingIDs.isEmpty else { return false }
        move(draggingIDs, to: target)
        draggingIDs = []
        return true
    }

    private func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    urls[i] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(urls.compactMap { $0 }) }
    }

    // MARK: Export

    func plan() -> OrganizePDFPlan {
        let first = inputs.first ?? sources[0].url
        return OrganizePDFPlan(sources: sources, pages: pages, sameWidth: sameWidth,
                               output: OutputNaming.url(for: first, ext: "pdf", suffix: "organized"))
    }

    /// A single-page document for the zoomable preview (rotation applied).
    func previewDocument(_ id: UUID) -> PDFDocument? {
        guard let item = pages.first(where: { $0.id == id }),
              let original = docs[item.source].page(at: item.pageIndex),
              let page = original.copy() as? PDFPage else { return nil }
        page.rotation = ((original.rotation + item.rotation) % 360 + 360) % 360
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return doc
    }
}
