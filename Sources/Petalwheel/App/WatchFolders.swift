import AppKit
import Combine

// MARK: - Model

/// What a watch folder does with new files: a conversion target or a non-interactive tool.
enum WatchAction: Hashable, Identifiable {
    case format(FileFormat)
    case tool(FileTool)

    var id: String { storageValue }

    /// "format:jpg" / "tool:removeMetadata" (the JSON representation).
    var storageValue: String {
        switch self {
        case .format(let f): return "format:\(f.rawValue)"
        case .tool(let t): return "tool:\(t.rawValue)"
        }
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "format": guard let f = FileFormat(rawValue: parts[1].lowercased()) else { return nil }; self = .format(f)
        case "tool": guard let t = FileTool(rawValue: parts[1]), Self.allowedTools.contains(t) else { return nil }; self = .tool(t)
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .format(let f): return L("Convert to %@", f.title)
        case .tool(let t): return t.title
        }
    }

    var fanItem: FanItem {
        switch self {
        case .format(let f): return FanItem(kind: .format(f), title: f.title, symbol: nil)
        case .tool(let t): return FanItem(kind: .tool(t), title: t.title, symbol: t.symbol)
        }
    }

    /// Whether a new file of `format` should be processed (otherwise it is skipped silently).
    func applies(to format: FileFormat?) -> Bool {
        guard let format else { return false }
        switch self {
        case .format(let target): return format != target && ConversionCatalog.outputs(from: format).contains(target)
        case .tool(let tool): return tool.accepts(format)
        }
    }

    /// Tools that run headlessly on a single file and write files next to it:
    /// no editor window, no options panel, no text-only results.
    static let allowedTools: [FileTool] = [.removeMetadata, .removeBackground, .splitPDF, .muteVideo,
                                           .audioToVideo, .extractArchive]

    /// Every action offered in Settings.
    static var all: [WatchAction] {
        var targets: [FileFormat] = []
        for f in FileFormat.allCases {
            for t in ConversionCatalog.outputs(from: f) where !targets.contains(t) { targets.append(t) }
        }
        let ordered = FileFormat.allCases.filter(targets.contains)
        return ordered.map { .format($0) } + allowedTools.map { .tool($0) }
    }
}

/// What happens to the original after a successful run.
enum OriginalsPolicy: String, Codable, CaseIterable, Identifiable {
    case keep, moveToSubfolder, trash
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: return L("Keep originals")
        case .moveToSubfolder: return L("Move originals to “%@”", WatchFolder.originalsFolderName)
        case .trash: return L("Move originals to Trash")
        }
    }
}

struct WatchFolder: Codable, Identifiable, Equatable {
    static let originalsFolderName = "Originals"

    var id: UUID
    var path: String
    var action: WatchAction
    var originals: OriginalsPolicy
    var enabled: Bool

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }

    init(id: UUID = UUID(), path: String, action: WatchAction, originals: OriginalsPolicy = .keep, enabled: Bool = true) {
        self.id = id
        self.path = path
        self.action = action
        self.originals = originals
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, path, action, originals, enabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = (try c.decode(String.self, forKey: .path) as NSString).expandingTildeInPath
        let raw = try c.decode(String.self, forKey: .action)
        guard let action = WatchAction(storageValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "Unknown action \(raw)")
        }
        self.action = action
        // Accept "delete" as an alias for trash (originals always go to the Trash, never hard-deleted).
        let policy = try c.decodeIfPresent(String.self, forKey: .originals) ?? "keep"
        originals = policy == "delete" ? .trash : OriginalsPolicy(rawValue: policy) ?? .keep
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(action.storageValue, forKey: .action)
        try c.encode(originals, forKey: .originals)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// Live per-folder status shown in Settings.
struct WatchFolderStatus: Equatable {
    var missing = false
    var processed = 0
    var lastMessage: String?
    var lastDate: Date?
}

// MARK: - Store

/// Persists watch folders to ~/Library/Application Support/NurTo/watch-folders.json and drives the monitor.
@MainActor
final class WatchFolderStore: ObservableObject {
    static let shared = WatchFolderStore()

    @Published private(set) var folders: [WatchFolder] = []
    @Published private(set) var status: [UUID: WatchFolderStatus] = [:]
    @Published private(set) var loadError: String?

    private var monitor: WatchFolderMonitor?

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NurTo", isDirectory: true).appendingPathComponent("watch-folders.json")
    }

    private struct FileContents: Codable {
        var version = 1
        var folders: [WatchFolder]
    }

    private init() { load() }

    /// Starts monitoring; `run` executes an action through the JobCoordinator.
    func start(run: @escaping (FanItem, [URL]) -> Void) {
        guard monitor == nil else { return }
        let monitor = WatchFolderMonitor(run: run)
        monitor.onStatus = { [weak self] id, update in
            guard let self else { return }
            var s = self.status[id] ?? WatchFolderStatus()
            update(&s)
            if s != self.status[id] { self.status[id] = s }
        }
        self.monitor = monitor
        monitor.configure(folders)
        NSLog("NurTo: watching %ld folder(s) from %@", folders.filter(\.enabled).count, Self.fileURL.path)
    }

    // MARK: Editing

    func add(_ url: URL, action: WatchAction = .format(.jpg)) {
        let path = url.standardizedFileURL.path
        guard !folders.contains(where: { $0.path == path }) else { return }
        folders.append(WatchFolder(path: path, action: action))
        changed()
    }

    func remove(_ id: UUID) {
        folders.removeAll { $0.id == id }
        status[id] = nil
        changed()
    }

    func update(_ folder: WatchFolder) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }), folders[i] != folder else { return }
        folders[i] = folder
        changed()
    }

    /// Shows an open panel and adds the chosen folders.
    func chooseAndAdd() {
        KQWindowing.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Watch")
        panel.message = L("Choose folders. New files dropped into them are processed automatically.")
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { add($0) }
    }

    func reveal(_ folder: WatchFolder) {
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }

    // MARK: Persistence

    private func changed() {
        save()
        monitor?.configure(folders)
    }

    func load() {
        loadError = nil
        guard let data = try? Data(contentsOf: Self.fileURL) else { folders = []; return }
        do {
            folders = try JSONDecoder().decode(FileContents.self, from: data).folders
        } catch {
            loadError = L("Couldn't read watch-folders.json: %@", error.localizedDescription)
            NSLog("NurTo: %@", loadError ?? "")
        }
    }

    private func save() {
        do {
            let dir = Self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(FileContents(folders: folders)).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("NurTo: saving watch folders failed: %@", error.localizedDescription)
        }
    }
}
