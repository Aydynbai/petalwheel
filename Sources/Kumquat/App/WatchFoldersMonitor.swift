import AppKit
import CoreServices

/// Watches folders with FSEvents and runs each folder's action on new, stable files.
///
/// Rules:
/// - Only files that appear after watching starts are processed (top level only, no subfolders).
/// - A file is ready when its size and modification date haven't changed for `stableInterval`,
///   and it isn't a partial download (.download, .crdownload, .part, …) or hidden.
/// - Kumquat's own outputs are ignored: names with a "(compressed)"-style suffix, and anything
///   named after a file this folder processed recently ("photo.png" → "photo.jpg", "photo-1.png", "photo part 2.mp4").
/// - Files the action can't handle (e.g. a JPG in a "Convert to JPG" folder) are skipped.
@MainActor
final class WatchFolderMonitor {
    typealias StatusUpdate = (inout WatchFolderStatus) -> Void

    var onStatus: ((UUID, StatusUpdate) -> Void)?

    static let stableInterval: TimeInterval = 2
    static let outputWindow: TimeInterval = 30 * 60
    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload", "tmp", "temp"]

    private let run: (FanItem, [URL]) -> Void
    private var folders: [WatchFolder] = []
    private var states: [UUID: FolderState] = [:]
    private var stream: FSEventStreamRef?
    private var timer: Timer?
    private var lastHeartbeat = Date.distantPast

    private struct Candidate { var size: Int64; var modified: Date; var since: Date }
    private struct Processed { var base: String; var original: URL; var at: Date }

    private final class FolderState {
        var resolvedPath: String
        var known: Set<String>? = nil          // nil = not snapshotted yet
        var candidates: [String: Candidate] = [:]
        var processed: [Processed] = []
        /// Outputs waiting to become stable before the original is moved/trashed.
        var pendingOutputs: [String: (candidate: Candidate, original: URL)] = [:]
        var disposed: Set<URL> = []
        var missing = false
        init(resolvedPath: String) { self.resolvedPath = resolvedPath }
    }

    init(run: @escaping (FanItem, [URL]) -> Void) {
        self.run = run
    }

    // MARK: Configuration

    func configure(_ folders: [WatchFolder]) {
        let active = folders.filter(\.enabled)
        let oldStates = states
        self.folders = active
        states = [:]
        for f in active {
            let resolved = f.url.resolvingSymlinksInPath().standardizedFileURL.path
            if let s = oldStates[f.id], s.resolvedPath == resolved {
                states[f.id] = s
            } else {
                states[f.id] = FolderState(resolvedPath: resolved)
            }
        }
        for f in folders where !f.enabled { onStatus?(f.id) { $0.lastMessage = L("Paused") } }
        for f in active { scan(f) }
        restartStream()
        if timer == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    // MARK: FSEvents

    private func restartStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        // Watch the parent too so a folder that is deleted / re-created is noticed.
        var paths = Set<String>()
        for s in states.values {
            paths.insert(s.resolvedPath)
            paths.insert((s.resolvedPath as NSString).deletingLastPathComponent)
        }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<WatchFolderMonitor>.fromOpaque(info).takeUnretainedValue()
            let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let paths = (0..<count).map { String(cString: cPaths[$0]) }
            MainActor.assumeIsolated { monitor.handleEvents(paths) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, Array(existing) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            NSLog("Kumquat: FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    private func handleEvents(_ paths: [String]) {
        for f in folders {
            guard let state = states[f.id] else { continue }
            let root = state.resolvedPath
            let hit = paths.contains { p in
                let p = p.hasSuffix("/") ? String(p.dropLast()) : p
                return p == root || (p as NSString).deletingLastPathComponent == root
            }
            if hit { scan(f) }
        }
    }

    // MARK: Polling (stability + missing folders)

    func tick() {
        let now = Date()
        let heartbeat = now.timeIntervalSince(lastHeartbeat) >= 3
        if heartbeat { lastHeartbeat = now }
        var needsStream = false
        for f in folders {
            guard let s = states[f.id] else { continue }
            let wasMissing = s.missing
            if heartbeat || !s.candidates.isEmpty || !s.pendingOutputs.isEmpty {
                scan(f)
            }
            if wasMissing != s.missing { needsStream = true }
        }
        if needsStream { restartStream() }
    }

    // MARK: Scanning

    private func scan(_ folder: WatchFolder) {
        guard let state = states[folder.id] else { return }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: state.resolvedPath, isDirectory: &isDir), isDir.boolValue else {
            if !state.missing {
                state.missing = true
                state.known = nil
                state.candidates = [:]
                state.pendingOutputs = [:]
                onStatus?(folder.id) { $0.missing = true; $0.lastMessage = L("Folder is missing") }
                NSLog("Kumquat: watch folder missing: %@", folder.path)
            }
            return
        }
        if state.missing {
            state.missing = false
            onStatus?(folder.id) { $0.missing = false; $0.lastMessage = L("Watching") }
        }

        let dirURL = URL(fileURLWithPath: state.resolvedPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var files: [String: (size: Int64, modified: Date)] = [:]
        for url in entries {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files[url.lastPathComponent] = (Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }

        // First sight: everything already there is "known" and left alone.
        guard var known = state.known else {
            state.known = Set(files.keys)
            onStatus?(folder.id) { $0.missing = false; if $0.lastMessage == nil || $0.lastMessage == L("Folder is missing") { $0.lastMessage = L("Watching") } }
            return
        }
        known.formIntersection(files.keys)          // forget deleted files, so re-adding a name is processed again
        state.candidates = state.candidates.filter { files[$0.key] != nil }
        state.pendingOutputs = state.pendingOutputs.filter { files[$0.key] != nil }
        let now = Date()
        state.processed.removeAll { now.timeIntervalSince($0.at) > Self.outputWindow }

        var ready: [URL] = []
        for (name, info) in files where !known.contains(name) {
            let ext = (name as NSString).pathExtension.lowercased()
            if Self.partialExtensions.contains(ext) { continue }   // wait for the rename

            if let source = originalProducing(name, in: state) {
                known.insert(name)
                state.candidates[name] = nil
                if folder.originals != .keep, !state.disposed.contains(source) {
                    state.pendingOutputs[name] = (Candidate(size: info.size, modified: info.modified, since: now), source)
                }
                continue
            }
            if Self.hasKumquatSuffix(name) { known.insert(name); continue }

            // Stability: same size + mtime for `stableInterval`.
            if let c = state.candidates[name], c.size == info.size, c.modified == info.modified {
                if now.timeIntervalSince(c.since) >= Self.stableInterval, info.size > 0 {
                    known.insert(name)
                    state.candidates[name] = nil
                    let url = dirURL.appendingPathComponent(name)
                    if folder.action.applies(to: FileFormat.detect(url)) {
                        ready.append(url)
                    } else {
                        onStatus?(folder.id) { $0.lastMessage = L("Skipped %@", name); $0.lastDate = now }
                    }
                } else if info.size == 0, now.timeIntervalSince(c.since) >= 30 {
                    known.insert(name)                  // empty placeholder that never filled up
                    state.candidates[name] = nil
                }
            } else {
                state.candidates[name] = Candidate(size: info.size, modified: info.modified, since: now)
            }
        }

        // Outputs that settled → the job succeeded → move/trash the original.
        for (name, pending) in state.pendingOutputs {
            guard let info = files[name] else { continue }
            if info.size == pending.candidate.size, info.modified == pending.candidate.modified {
                guard now.timeIntervalSince(pending.candidate.since) >= Self.stableInterval, info.size > 0 else { continue }
                state.pendingOutputs[name] = nil
                dispose(pending.original, in: state, folder: folder)
            } else {
                state.pendingOutputs[name] = (Candidate(size: info.size, modified: info.modified, since: now), pending.original)
            }
        }
        state.known = known

        guard !ready.isEmpty else { return }
        ready.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in ready {
            state.processed.append(Processed(base: url.deletingPathExtension().lastPathComponent,
                                             original: url, at: now))
        }
        let names = ready.map(\.lastPathComponent).joined(separator: ", ")
        NSLog("Kumquat: watch folder %@ → %@: %@", folder.name, folder.action.storageValue, names)
        onStatus?(folder.id) {
            $0.processed += ready.count
            $0.lastMessage = "\(folder.action.title): \(ready.count == 1 ? ready[0].lastPathComponent : Lp("%d files", ready.count))"
            $0.lastDate = now
        }
        run(folder.action.fanItem, ready)
    }

    /// The recently processed original this file was generated from, if any.
    private func originalProducing(_ name: String, in state: FolderState) -> URL? {
        let base = (name as NSString).deletingPathExtension
        for p in state.processed.reversed() where name != p.original.lastPathComponent {
            if base == p.base || base.hasPrefix(p.base + " ") || base.hasPrefix(p.base + "-") || base.hasPrefix(p.base + "_") {
                return p.original
            }
        }
        return nil
    }

    /// "photo (compressed).jpg", "clip (muted) 2.mp4" …
    static func hasKumquatSuffix(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension
        return base.range(of: #" \([^()]+\)( \d+)?$"#, options: .regularExpression) != nil
    }

    private func dispose(_ original: URL, in state: FolderState, folder: WatchFolder) {
        guard !state.disposed.contains(original) else { return }
        state.disposed.insert(original)
        let fm = FileManager.default
        guard fm.fileExists(atPath: original.path) else { return }
        do {
            switch folder.originals {
            case .keep:
                return
            case .moveToSubfolder:
                let dir = original.deletingLastPathComponent().appendingPathComponent(WatchFolder.originalsFolderName, isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.moveItem(at: original, to: OutputNaming.unique(dir.appendingPathComponent(original.lastPathComponent)))
            case .trash:
                try fm.trashItem(at: original, resultingItemURL: nil)
            }
        } catch {
            NSLog("Kumquat: couldn't move original %@: %@", original.path, error.localizedDescription)
            onStatus?(folder.id) { $0.lastMessage = L("Couldn't move %@", original.lastPathComponent) }
        }
    }
}
