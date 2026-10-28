import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Page organizer: reorder, rotate, delete, duplicate and merge pages of one or more PDFs.
@MainActor
enum OrganizePDFEditor {
    /// Opens the editor window for `inputs`. Calls `completion` exactly once (nil = cancelled).
    static func present(inputs: [URL], completion: @escaping EditorCompletion) {
        let model = OrganizePDFModel(inputs: inputs)
        guard !model.pages.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("No pages to organize")
            alert.informativeText = model.message ?? L("The files could not be opened as PDFs.")
            KQWindowing.activate()
            alert.runModal()
            completion(nil)
            return
        }
        OrganizePDFSession(model: model, completion: completion).show()
    }
}

// MARK: - Root view

struct OrganizePDFView: View {
    @ObservedObject var model: OrganizePDFModel
    let host: EditorWindowHost

    var body: some View {
        VStack(spacing: 0) {
            OrganizePDFToolbar(model: model)
            Divider()
            ZStack {
                OrganizePDFGrid(model: model)
                if let id = model.previewID {
                    OrganizePDFLargePreview(model: model, id: id)
                }
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(shortcuts)
    }

    /// Invisible buttons that carry keyboard shortcuts without a visible control.
    private var shortcuts: some View {
        ZStack {
            Button("Select All") { model.selectAll() }.keyboardShortcut("a", modifiers: .command)
            Button("Preview") { togglePreview() }.keyboardShortcut(.space, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private func togglePreview() {
        if model.previewID != nil { model.previewID = nil }
        else if let i = model.selectedIndices.first { model.previewID = model.pages[i].id }
    }

    private var bottomBar: some View {
        EditorFooter(host: host, saveTitle: "Save PDF", canSave: !model.pages.isEmpty) {
            EditorFileInfo(name: fileName, detail: detail)
        } accessory: {
            if model.hasMultipleSources {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(model.sources.enumerated()), id: \.offset) { i, src in
                            HStack(spacing: 5) {
                                Circle().fill(model.tagColor(i)).frame(width: 8, height: 8)
                                Text(src.url.lastPathComponent)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 180, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.trailing, 12)
            }
        }
    }

    private var fileName: String {
        let n = model.inputs.count
        return n > 1 ? Lp("%d files", n) : (model.inputs.first?.lastPathComponent ?? "PDF")
    }

    private var detail: Text {
        if let msg = model.message {
            return Text(Image(systemName: "exclamationmark.triangle")) + Text(" ") + Text(msg)
        }
        return Text("Drag to reorder · drop PDFs or images to insert · double-click to zoom")
    }
}

// MARK: - Toolbar

struct OrganizePDFToolbar: View {
    @ObservedObject var model: OrganizePDFModel

    var body: some View {
        HStack(spacing: 6) {
            tool("plus.rectangle.on.rectangle", "Add PDFs or Images…") { model.addFilesWithPanel() }
            separator
            tool("rotate.left", "Rotate Left (⌘L)", disabled: model.selection.isEmpty) { model.rotateSelected(by: -90) }
                .keyboardShortcut("l", modifiers: .command)
            tool("rotate.right", "Rotate Right (⌘R)", disabled: model.selection.isEmpty) { model.rotateSelected(by: 90) }
                .keyboardShortcut("r", modifiers: .command)
            tool("plus.square.on.square", "Duplicate (⌘D)", disabled: model.selection.isEmpty) { model.duplicateSelected() }
                .keyboardShortcut("d", modifiers: .command)
            tool("trash", "Delete (⌫)", disabled: model.selection.isEmpty) { model.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
            separator
            tool("arrow.uturn.backward", "Undo (⌘Z)", disabled: !model.canUndo) { model.undo() }
            tool("arrow.uturn.forward", "Redo (⇧⌘Z)", disabled: !model.canRedo) { model.redo() }
            separator
            Toggle(isOn: $model.sameWidth) {
                Text("Make all pages the same width").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .tint(KQTheme.accent)
            .help("Scales every page to the most common page width when saving")
            Spacer(minLength: 8)
            Text(countText)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: $model.thumbSize, in: 90...260)
                .controlSize(.mini)
                .frame(width: 90)
                .tint(KQTheme.accent)
            Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.top, 2)
    }

    private var countText: String {
        let n = model.pages.count
        let base = Lp("%d pages", n)
        return model.selection.isEmpty ? base : base + " · " + L("%d selected", model.selection.count)
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 4)
    }

    private func tool(_ symbol: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.primary)
        .disabled(disabled)
        .help(L(help))
    }
}

// MARK: - Grid

struct OrganizePDFGrid: View {
    @ObservedObject var model: OrganizePDFModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbSize, maximum: model.thumbSize + 40), spacing: 14)],
                      spacing: 16) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { i, item in
                    OrganizePDFCell(model: model, item: item, position: i)
                        .onDrag {
                            model.beginDrag(item.id)
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        }
                        .onDrop(of: [.fileURL, .plainText],
                                delegate: OrganizePDFCellDrop(model: model, position: i, width: model.thumbSize))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.primary.opacity(0.03))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [] }
        .onDrop(of: [.fileURL, .plainText], delegate: OrganizePDFCellDrop(model: model, position: nil, width: 0))
    }
}

/// Drop target for a cell (insert before/after it) or for the grid background (append).
struct OrganizePDFCellDrop: DropDelegate {
    let model: OrganizePDFModel
    let position: Int?
    let width: CGFloat

    private func target(_ info: DropInfo) -> Int {
        guard let position else { return model.pages.count }
        return info.location.x > width / 2 ? position + 1 : position
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) || !model.draggingIDs.isEmpty
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let t = target(info)
        if model.dropIndex != t { model.dropIndex = t }
        return DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        if model.dropIndex == target(info) { model.dropIndex = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        model.performDrop(info, at: target(info))
    }
}

struct OrganizePDFCell: View {
    @ObservedObject var model: OrganizePDFModel
    let item: OrganizePDFPage
    let position: Int

    private var selected: Bool { model.selection.contains(item.id) }

    var body: some View {
        let side = model.thumbSize
        VStack(spacing: 6) {
            ZStack {
                thumbnail
                    .frame(width: side, height: side * 1.2)
            }
            .overlay(alignment: .leading) { insertionMarker(before: true) }
            .overlay(alignment: .trailing) { insertionMarker(before: false) }
            HStack(spacing: 4) {
                Text(verbatim: "\(position + 1)")
                    .font(.system(size: 11, weight: selected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? KQTheme.accentText : Color.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.selection = [item.id]
            model.previewID = item.id
        }
        .simultaneousGesture(TapGesture().onEnded {
            model.click(item.id, modifiers: NSEvent.modifierFlags)
        })
        .onAppear { model.requestThumbnail(item) }
        .help(L("Page %d of %@", item.originalNumber, model.sources[item.source].url.lastPathComponent))
    }

    private var thumbnail: some View {
        let side = model.thumbSize
        let aspect = max(0.2, min(5, model.aspect(item)))
        // Fit the rotated page inside side × 1.2·side.
        let boxW = min(side, side * 1.2 * aspect)
        let boxH = boxW / aspect
        let rotated = item.rotation % 180 != 0
        return ZStack {
            Group {
                if let img = model.thumbnails[item.thumbKey] {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.white)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: rotated ? boxH : boxW, height: rotated ? boxW : boxH)
            .rotationEffect(.degrees(Double(item.rotation)))
            .frame(width: boxW, height: boxH)
            .background(Color.white)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(selected ? KQTheme.accent : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 0.5)
                    .padding(selected ? -4 : 0)
            )
            .overlay(alignment: .bottom) {
                if model.hasMultipleSources {
                    Rectangle().fill(model.tagColor(item.source).opacity(0.85)).frame(height: 3)
                }
            }
            .overlay(alignment: .topTrailing) { badge }
        }
        .animation(.easeInOut(duration: 0.15), value: item.rotation)
    }

    private var badge: some View {
        let tint = model.hasMultipleSources ? model.tagColor(item.source) : Color.black.opacity(0.55)
        return Text(L("p%d", item.originalNumber))
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(model.hasMultipleSources ? KQTheme.textOnFill : Color.white)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(tint))
            .padding(4)
    }

    @ViewBuilder
    private func insertionMarker(before: Bool) -> some View {
        let show = before ? model.dropIndex == position : model.dropIndex == position + 1
        if show {
            Capsule().fill(KQTheme.accent).frame(width: 4).padding(.vertical, 4)
                .offset(x: before ? -9 : 9)
        }
    }
}

// MARK: - Large preview

/// PDFView holder so SwiftUI buttons can zoom it.
final class OrganizePDFPreviewZoom: ObservableObject {
    weak var view: PDFView?
    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func fit() { view?.autoScales = true }
}

struct OrganizePDFKitView: NSViewRepresentable {
    let document: PDFDocument?
    let zoom: OrganizePDFPreviewZoom

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.displayMode = .singlePage
        v.displaysPageBreaks = false
        v.backgroundColor = NSColor(white: 0.12, alpha: 1)
        v.autoScales = true
        v.document = document
        zoom.view = v
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document !== document {
            v.document = document
            v.autoScales = true
        }
        zoom.view = v
    }
}

struct OrganizePDFLargePreview: View {
    @ObservedObject var model: OrganizePDFModel
    let id: UUID
    @StateObject private var zoom = OrganizePDFPreviewZoom()
    @StateObject private var cache = OrganizePDFPreviewCache()

    var body: some View {
        let position = model.index(of: id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let position, position < model.pages.count {
                    let item = model.pages[position]
                    Text(L("Page %d of %d", position + 1, model.pages.count))
                        .font(.system(size: 12, weight: .semibold))
                    Text("· " + L("p%d of %@", item.originalNumber, model.sources[item.source].url.lastPathComponent))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { model.moveSelection(by: -1, extend: false) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(KQSecondaryButtonStyle())
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.moveSelection(by: 1, extend: false) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(KQSecondaryButtonStyle())
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button { zoom.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(KQSecondaryButtonStyle())
                    .keyboardShortcut("-", modifiers: .command)
                Button { zoom.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(KQSecondaryButtonStyle())
                    .keyboardShortcut("=", modifiers: .command)
                Button("Fit") { zoom.fit() }
                    .buttonStyle(KQSecondaryButtonStyle())
                    .keyboardShortcut("0", modifiers: .command)
                Button("Done") { model.previewID = nil }
                    .buttonStyle(KQProminentButtonStyle())
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(VisualEffectBackground(material: .headerView, blending: .withinWindow))
            OrganizePDFKitView(document: cache.document(for: id, rotation: position.map { model.pages[$0].rotation } ?? 0, model: model),
                               zoom: zoom)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Keeps one preview document per (page, rotation) so SwiftUI updates don't reset the zoom.
final class OrganizePDFPreviewCache: ObservableObject {
    private var key: String?
    private var doc: PDFDocument?

    @MainActor
    func document(for id: UUID, rotation: Int, model: OrganizePDFModel) -> PDFDocument? {
        let k = "\(id)-\(rotation)"
        if k != key {
            key = k
            doc = model.previewDocument(id)
        }
        return doc
    }
}

// MARK: - Window

@MainActor
final class OrganizePDFSession {
    let model: OrganizePDFModel
    let host: EditorWindowHost

    init(model: OrganizePDFModel, completion: @escaping EditorCompletion) {
        self.model = model
        let first = model.inputs.first?.lastPathComponent ?? "PDF"
        host = EditorWindowHost(title: model.inputs.count > 1 ? Lp("Organize %d PDFs", model.inputs.count) : L("Organize – %@", first),
                                minSize: NSSize(width: 760, height: 520), completion: completion)
        host.hasUnsavedChanges = { model.hasUnsavedChanges }
        host.canSave = { !model.pages.isEmpty }
        host.makeExport = { OrganizePDFExporter.makeExport(model.plan()) }
        host.undo = { model.undo() }
        host.redo = { model.redo() }
        // Esc first closes the large preview.
        host.escapeHandler = {
            guard model.previewID != nil else { return false }
            model.previewID = nil
            return true
        }
        // Arrow keys move the selection in the grid (the preview has its own arrow buttons).
        host.keyHandler = { event in
            guard model.previewID == nil, EditorKeys.isPlain(event) else { return false }
            let extend = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case EditorKeys.left: model.moveSelection(by: -1, extend: extend); return true
            case EditorKeys.right: model.moveSelection(by: 1, extend: extend); return true
            case EditorKeys.forwardDelete: model.deleteSelected(); return true
            default: return false
            }
        }
        host.owner = self
    }

    func show() {
        host.show(OrganizePDFView(model: model, host: host))
    }
}
