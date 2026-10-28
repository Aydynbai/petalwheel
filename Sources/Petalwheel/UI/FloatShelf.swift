import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

final class FloatShelfModel: ObservableObject {
    @Published var items: [ShelfItem] = []
    @Published var selection: Set<UUID> = []
    @Published var thumbnails: [URL: NSImage] = [:]
    @Published var isTargeted = false

    func add(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL })
        var seen = existing
        for url in urls {
            let u = url.standardizedFileURL
            guard u.isFileURL, !seen.contains(u) else { continue }
            seen.insert(u)
            items.append(ShelfItem(url: u))
            Thumbnails.load(u, size: CGSize(width: 128, height: 128)) { [weak self] image in
                self?.thumbnails[u] = image
            }
        }
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func clear() {
        items.removeAll()
        selection.removeAll()
    }

    /// Drops items whose files were moved away or deleted.
    func pruneMissing() {
        let fm = FileManager.default
        let gone = Set(items.filter { !fm.fileExists(atPath: $0.url.path) }.map(\.id))
        if !gone.isEmpty { remove(gone) }
    }

    /// URLs to drag when the drag starts on `item`: the whole selection if it includes the item.
    func dragURLs(startingAt item: ShelfItem) -> [URL] {
        if selection.contains(item.id) {
            return items.filter { selection.contains($0.id) }.map(\.url)
        }
        return [item.url]
    }

    func click(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if modifiers.contains(.shift), let anchor = items.firstIndex(where: { selection.contains($0.id) }),
                  let idx = items.firstIndex(of: item) {
            let range = min(anchor, idx)...max(anchor, idx)
            selection = Set(items[range].map(\.id))
        } else {
            selection = [item.id]
        }
    }
}

/// Tiny observable flag (SwiftUI's @State is a macro that Command Line Tools can't expand).
final class HoverFlag: ObservableObject {
    @Published var value = false
}

// MARK: - Controller

/// Floating "shelf" that holds files temporarily (like Dropover / Yoink).
@MainActor
final class FloatShelfController: NSObject, NSWindowDelegate {
    static let shared = FloatShelfController()

    let model = FloatShelfModel()
    private var panel: KQPanel?

    /// Adds files to the floating shelf and shows it.
    func add(_ urls: [URL]) {
        model.add(urls)
        show()
    }

    func show() {
        let firstShow = panel == nil || panel?.isVisible == false
        let p = ensurePanel()
        if firstShow {
            p.setFrame(KQWindowing.frameNearMouse(size: p.frame.size, offset: NSPoint(x: 0, y: 40)), display: false)
        }
        model.pruneMissing()
        p.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        model.clear()
    }

    private func ensurePanel() -> KQPanel {
        if let panel { return panel }
        let size = NSSize(width: 312, height: 340)
        let p = KQPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless, .resizable],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.minSize = NSSize(width: 220, height: 220)
        p.delegate = self
        let view = FloatShelfView(model: model, onClose: { [weak self] in self?.close() })
        p.contentView = NSHostingView(rootView: view)
        panel = p
        return p
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated { model.pruneMissing() }
    }
}

// MARK: - Views

struct FloatShelfView: View {
    @ObservedObject var model: FloatShelfModel
    var onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            footer
        }
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(model.isTargeted ? KQTheme.accent : Color.primary.opacity(0.1),
                              lineWidth: model.isTargeted ? 2.5 : 1)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isTargeted) { providers in
            loadURLs(from: providers)
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Close shelf")
            Image(systemName: "tray.full.fill").foregroundStyle(KQTheme.accentText)
            Text("Shelf").font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            Text(Lp("%d items", model.items.count))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if model.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(model.isTargeted ? KQTheme.accent : .secondary)
                Text("Drop files here").font(.system(size: 13, weight: .medium))
                Text("Keep them handy, then drag them out\nwherever you need them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.items) { item in
                        ShelfTile(model: model, item: item)
                    }
                }
                .padding(10)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection.removeAll() }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.selection.isEmpty {
                Button {
                    model.remove(model.selection)
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
                .buttonStyle(KQSecondaryButtonStyle())
                .font(.system(size: 11))
                Text(L("%d selected", model.selection.count)).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !model.items.isEmpty {
                Text("Drag items out · ⌘-click to select several")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Clear") { model.clear() }
                .buttonStyle(KQSecondaryButtonStyle())
                .font(.system(size: 11))
                .disabled(model.items.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func loadURLs(from providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.add([url]) }
            }
        }
    }
}

struct ShelfTile: View {
    @ObservedObject var model: FloatShelfModel
    let item: ShelfItem
    @StateObject private var hover = HoverFlag()
    private var hovering: Bool { hover.value }

    private var selected: Bool { model.selection.contains(item.id) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let img = model.thumbnails[item.url] {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().scaledToFit()
                }
            }
            .frame(width: 60, height: 60)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            Text(item.url.lastPathComponent)
                .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? KQTheme.onAccentProminent : Color.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? KQTheme.accentProminentFill : Color.clear))
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? KQTheme.accent.opacity(0.18) : (hovering ? Color.primary.opacity(0.06) : Color.clear)))
        .overlay(ShelfDragSource(model: model, item: item))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    model.remove([item.id])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Remove from shelf")
                .padding(2)
            }
        }
        .onHover { hover.value = $0 }
        .help(item.url.path)
    }
}

/// AppKit overlay that handles click selection, double-click to open, and multi-file drag-out.
struct ShelfDragSource: NSViewRepresentable {
    let model: FloatShelfModel
    let item: ShelfItem

    func makeNSView(context: Context) -> ShelfDragView {
        let v = ShelfDragView()
        v.model = model
        v.item = item
        return v
    }

    func updateNSView(_ v: ShelfDragView, context: Context) {
        v.model = model
        v.item = item
    }
}

final class ShelfDragView: NSView, NSDraggingSource {
    weak var model: FloatShelfModel?
    var item: ShelfItem?
    private var mouseDownEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        guard let model, let item else { return }
        if event.clickCount == 2 {
            NSWorkspace.shared.open(item.url)
            return
        }
        // Keep an existing multi-selection intact so it can be dragged as a group.
        if !(model.selection.contains(item.id) && event.modifierFlags.intersection([.command, .shift]).isEmpty) {
            model.click(item, modifiers: event.modifierFlags)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model, let item, let down = mouseDownEvent, down.clickCount == 1 else { return }
        if model.selection.contains(item.id), model.selection.count > 1,
           event.modifierFlags.intersection([.command, .shift]).isEmpty {
            model.selection = [item.id]
        }
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let item, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        mouseDownEvent = nil

        let urls = model.dragURLs(startingAt: item)
        let origin = convert(down.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.enumerated().map { index, url in
            let di = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = model.thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path)
            let side: CGFloat = 56
            let offset = CGFloat(min(index, 4)) * 6
            di.setDraggingFrame(NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset,
                                       width: side, height: side), contents: icon)
            return di
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // If Finder moved the files away, remove them from the shelf.
        DispatchQueue.main.async { [weak self] in self?.model?.pruneMissing() }
    }
}
