import AppKit

/// Builds the status menu's "Recent" submenu from `HistoryStore`.
@MainActor
final class HistoryMenuBuilder: NSObject {
    /// Called by "Run Again".
    var onRunAgain: ((HistoryEntry) -> Void)?
    private let store: HistoryStore
    private let maxItems: Int

    init(store: HistoryStore = .shared, maxItems: Int = 15) {
        self.store = store
        self.maxItems = maxItems
    }

    /// The "Recent" item with its submenu (always present; disabled entries when empty).
    func makeRecentItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("Recent"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        item.submenu = makeSubmenu()
        return item
    }

    func makeSubmenu() -> NSMenu {
        let menu = NSMenu(title: L("Recent"))
        menu.autoenablesItems = false
        let entries = Array(store.visibleEntries.prefix(maxItems))
        if entries.isEmpty {
            let empty = NSMenuItem(title: L("No Recent Operations"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in entries {
            menu.addItem(makeEntryItem(entry))
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("Clear History"), action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !store.entries.isEmpty
        menu.addItem(clear)
        return menu
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func entryTitle(_ entry: HistoryEntry) -> String {
        let first = entry.inputs.first?.lastPathComponent ?? ""
        let more = entry.inputs.count > 1 ? " +\(entry.inputs.count - 1)" : ""
        return first.isEmpty ? entry.title : "\(entry.title) — \(first)\(more)"
    }

    private func makeEntryItem(_ entry: HistoryEntry) -> NSMenuItem {
        let item = NSMenuItem(title: Self.entryTitle(entry), action: nil, keyEquivalent: "")
        let symbol = entry.cancelled ? "xmark.circle" : (entry.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let sub = NSMenu(title: entry.title)
        sub.autoenablesItems = false

        let info = NSMenuItem(title: Self.dateFormatter.string(from: entry.date) + statusSuffix(entry), action: nil, keyEquivalent: "")
        info.isEnabled = false
        sub.addItem(info)
        if let problem = entry.problem {
            let p = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            p.isEnabled = false
            sub.addItem(p)
        }
        sub.addItem(.separator())

        let outputs = entry.existingOutputs
        let reveal = NSMenuItem(title: outputs.isEmpty ? L("Show Originals in Finder") : L("Show in Finder"),
                                action: #selector(showInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = outputs.isEmpty ? entry.existingInputs : outputs
        reveal.isEnabled = !(outputs.isEmpty && entry.existingInputs.isEmpty)
        sub.addItem(reveal)

        let open = NSMenuItem(title: outputs.count > 1 ? Lp("Open %d Files", outputs.count) : L("Open"),
                              action: #selector(openFiles(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = outputs
        open.isEnabled = !outputs.isEmpty
        sub.addItem(open)

        let again = NSMenuItem(title: L("Run Again"), action: #selector(runAgain(_:)), keyEquivalent: "")
        again.target = self
        again.representedObject = entry.id
        again.isEnabled = entry.canRunAgain && onRunAgain != nil
        sub.addItem(again)

        sub.addItem(.separator())
        let remove = NSMenuItem(title: L("Remove from History"), action: #selector(removeEntry(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = entry.id
        sub.addItem(remove)

        item.submenu = sub
        return item
    }

    private func statusSuffix(_ entry: HistoryEntry) -> String {
        if entry.cancelled { return " · " + L("Cancelled") }
        if !entry.succeeded { return " · " + L("Failed") }
        let n = entry.outputs.count
        return n == 0 ? "" : " · " + Lp("%d files", n)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func openFiles(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    @objc private func runAgain(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = store.entries.first(where: { $0.id == id }) else { return }
        onRunAgain?(entry)
    }

    @objc private func removeEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.remove(id)
    }

    @objc private func clearHistory() { store.clear() }
}
