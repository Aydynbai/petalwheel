import Foundation
import Combine

/// How to run a history entry again.
struct HistoryRerun: Codable, Equatable {
    /// The conversion target or tool that ran.
    var action: PresetAction?
    /// Set when the operation came from a user preset (re-runs the preset as it is now, if it still exists).
    var presetID: UUID?
    var conversion: CodableConversionOptions?
    var tool: CodableToolOptions?
    var downmixToMono: Bool?
}

/// One finished operation.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
    var inputs: [URL]
    var outputs: [URL]
    var succeeded: Bool
    var cancelled = false
    /// First problem, already translated for people.
    var problem: String?
    var rerun: HistoryRerun?

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    var existingOutputs: [URL] { outputs.filter(Self.exists) }
    var existingInputs: [URL] { inputs.filter(Self.exists) }

    /// Entries whose files are all gone are hidden from the menu.
    var isVisible: Bool { !existingOutputs.isEmpty || (outputs.isEmpty && !existingInputs.isEmpty) }

    /// Run Again needs every original input and a re-runnable action.
    var canRunAgain: Bool {
        guard let rerun, rerun.action?.isValid == true || rerun.presetID != nil else { return false }
        return !inputs.isEmpty && existingInputs.count == inputs.count
    }
}

/// The last `limit` operations, persisted as Application Support/Kumquat/history.json.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let fileName = "history.json"
    static let limit = 30

    @Published private(set) var entries: [HistoryEntry] = []

    private struct FileV1: Codable {
        var version = 1
        var entries: [HistoryEntry]
    }

    init() { reload() }

    func reload() {
        entries = KQSupportDirectory.readJSON(FileV1.self, from: Self.fileName)?.entries ?? []
    }

    /// Newest first.
    func record(_ entry: HistoryEntry) {
        guard JobSettings.shared.keepHistory else { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Entries that still have files on disk.
    var visibleEntries: [HistoryEntry] { entries.filter(\.isVisible) }

    private func save() {
        do {
            try KQSupportDirectory.writeJSON(FileV1(entries: entries), to: Self.fileName)
        } catch {
            NSLog("Kumquat: couldn't save history: \(error.localizedDescription)")
        }
    }
}
