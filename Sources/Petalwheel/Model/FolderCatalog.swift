import Foundation

// Folders as first-class inputs: scanning the dropped folders and building the wheel's petals for them.
//
// Design of the Convert category for folders: category-level targets ("Images → JPG", "Video → MP4", …).
// A folder usually mixes kinds, so per-format petals ("HEIC → JPG", "PNG → JPG") would explode, and the
// intersection of all files' targets is usually empty. Instead every format group present inside the
// folders gets a short curated list of targets, and a petal converts all files of its own group:
// "Images → JPG" turns every HEIC/PNG/TIFF/… into JPG (JPGs are copied as is) and leaves videos alone.
// Groups are ordered by how many files they have, and petals are shared round-robin so the dominant
// kind gets the most targets while the wheel stays at one ring (`maxConvertPetals`).

/// One file found inside the selection.
struct FolderEntry {
    let url: URL
    /// The dropped folder this file was found in; nil for a loose file dropped next to folders.
    let root: URL?
    /// Path of the containing folder relative to `root` ("" at the top level).
    let relativeDir: String
    let format: FileFormat?
    let size: Int64
    /// An opaque bundle (.app, .photoslibrary, .rtfd…): handled as one item, never entered.
    let isPackage: Bool

    var relativePath: String {
        relativeDir.isEmpty ? url.lastPathComponent : relativeDir + "/" + url.lastPathComponent
    }
}

/// Everything found in a selection of folders (and loose files).
struct FolderScan {
    var roots: [URL] = []
    var entries: [FolderEntry] = []
    /// Subfolders seen (not counting the roots).
    var folderCount = 0
    var hiddenSkipped = 0
    var symlinksSkipped = 0
    /// More than `FolderCatalog.maxFiles` files: the scan stopped early.
    var truncated = false

    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    func count(_ group: FormatGroup) -> Int { entries.filter { $0.format?.group == group }.count }
}

enum FolderCatalog {
    /// Safety cap on the number of files a folder operation will touch.
    static let maxFiles = 10_000
    static let maxConvertPetals = 8

    // MARK: Detection

    /// A real folder: a directory that is neither a package (.app, .photoslibrary) nor a document bundle
    /// with a known format (.rtfd, .pages, .key).
    static func isFolder(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard let v = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              v.isDirectory == true else { return false }
        if v.isPackage == true { return false }
        return FileFormat.detect(resolved) == nil
    }

    static func containsFolder(_ urls: [URL]) -> Bool { urls.contains(where: isFolder) }

    // MARK: Scanning

    private static let lock = NSLock()
    private static var cache: (key: String, date: Date, scan: FolderScan)?

    /// Scan for the wheel: cached briefly because the wheel asks once per category.
    static func cachedScan(_ urls: [URL]) -> FolderScan {
        let key = urls.map(\.path).joined(separator: "\n")
        lock.lock()
        if let c = cache, c.key == key, Date().timeIntervalSince(c.date) < 3 { lock.unlock(); return c.scan }
        lock.unlock()
        let s = scan(urls)
        lock.lock()
        cache = (key, Date(), s)
        lock.unlock()
        return s
    }

    /// Lists the files inside `urls` recursively. Skips hidden items, never enters packages, never follows
    /// symbolic links (so nothing outside the folders is reached), and stops after `maxFiles` files.
    static func scan(_ urls: [URL], isCancelled: () -> Bool = { false }) -> FolderScan {
        var result = FolderScan()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey,
                                      .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        let fm = FileManager.default
        for input in urls {
            if result.truncated || isCancelled() { break }
            guard isFolder(input) else {
                // A loose file (or a package) dropped next to folders.
                let v = try? input.resourceValues(forKeys: Set(keys))
                result.entries.append(FolderEntry(url: input, root: nil, relativeDir: "",
                                                  format: FileFormat.detect(input),
                                                  size: Int64(v?.fileSize ?? 0), isPackage: v?.isPackage ?? false))
                continue
            }
            let root = input.resolvingSymlinksInPath().standardizedFileURL
            result.roots.append(root)
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                        options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in e {
                if isCancelled() { break }
                let v = try? url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent
                if v?.isHidden == true || name.hasPrefix(".") {
                    result.hiddenSkipped += 1
                    if v?.isDirectory == true { e.skipDescendants() }
                    continue
                }
                if v?.isSymbolicLink == true {
                    result.symlinksSkipped += 1
                    continue
                }
                let path = url.standardizedFileURL.path
                let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : name
                let relativeDir = (relative as NSString).deletingLastPathComponent
                let isPackage = v?.isPackage == true || (v?.isDirectory == true && FileFormat.detect(url) != nil)
                if v?.isDirectory == true && !isPackage {
                    result.folderCount += 1
                    continue
                }
                if v?.isDirectory != true && v?.isRegularFile != true { continue }   // sockets, devices…
                if result.entries.count >= maxFiles {
                    result.truncated = true
                    break
                }
                if isPackage { e.skipDescendants() }
                let size = isPackage ? packageSize(url) : Int64(v?.fileSize ?? 0)
                result.entries.append(FolderEntry(url: url, root: root, relativeDir: relativeDir,
                                                  format: FileFormat.detect(url), size: size, isPackage: isPackage))
            }
        }
        return result
    }

    /// Allocated size of a package, counted without following links. Bounded so huge bundles stay cheap.
    private static func packageSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey],
                                                     options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var n = 0
        for case let f as URL in e {
            n += 1
            if n > 20_000 { break }
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Convert targets

    /// Curated targets per group, most useful first. Each target belongs to its own group, so a target
    /// alone tells which files it converts.
    private static let curatedTargets: [FormatGroup: [FileFormat]] = [
        .images: [.jpg, .png, .heic, .webp, .avif, .tiff],
        .video: [.mp4, .mov, .webm, .gif, .mkv],
        .audio: [.mp3, .m4a, .wav, .flac],
        .documents: [.pdf, .docx, .txt, .md],
        .spreadsheets: [.xlsx, .csv],
        .subtitles: [.srt, .vtt],
    ]

    private static let groupSymbols: [FormatGroup: String] = [
        .images: "photo", .video: "film", .audio: "music.note", .documents: "doc.text",
        .spreadsheets: "tablecells", .subtitles: "captions.bubble", .archives: "archivebox",
    ]

    /// Short petal title such as "Images → JPG".
    static func convertTitle(_ group: FormatGroup, _ target: FileFormat) -> String {
        switch group.rawValue {
        case "images": return L("Images → %@", target.title)
        case "video": return L("Video → %@", target.title)
        case "audio": return L("Audio → %@", target.title)
        case "documents": return L("Documents → %@", target.title)
        case "spreadsheets": return L("Spreadsheets → %@", target.title)
        case "subtitles": return L("Subtitles → %@", target.title)
        default: return group.title + " → " + target.title
        }
    }

    /// Whether `entry` is a source for converting to `target` (files already in `target` are copied).
    static func isConvertible(_ entry: FolderEntry, to target: FileFormat) -> Bool {
        guard let f = entry.format, !entry.isPackage || f.group == .documents else { return false }
        return f != target && ConversionCatalog.outputs(from: f).contains(target)
    }

    /// Files that converting the selection to `target` touches. Normally the files of the target's own
    /// group ("Images → JPG" takes every image); when none of those can convert (CLI: `--convert mp3`
    /// on a folder of videos) every file that can produce `target` is used instead.
    static func convertSources(_ scan: FolderScan, to target: FileFormat) -> [FolderEntry] {
        let own = scan.entries.filter { $0.format?.group == target.group && (isConvertible($0, to: target) || $0.format == target) }
        if own.contains(where: { isConvertible($0, to: target) }) { return own }
        return scan.entries.filter { isConvertible($0, to: target) }
    }

    /// Category-level targets for a scan: (group, target) pairs in display order.
    static func convertTargets(_ scan: FolderScan) -> [(FormatGroup, FileFormat)] {
        var counts: [FormatGroup: Int] = [:]
        for e in scan.entries { if let g = e.format?.group { counts[g, default: 0] += 1 } }
        let groups = FormatGroup.allCases.filter { (counts[$0] ?? 0) > 0 && $0 != .archives }
            .sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
        var claimed = Set<FileFormat>()
        var lists: [(FormatGroup, [FileFormat])] = []
        for g in groups.prefix(4) {
            let members = scan.entries.filter { $0.format?.group == g }
            var candidates = curatedTargets[g] ?? []
            if candidates.isEmpty, let dominant = dominantFormat(members) {
                candidates = Array(ConversionCatalog.outputs(from: dominant).filter { $0.group == g }.prefix(3))
            }
            let valid = candidates.filter { t in
                !claimed.contains(t) && members.contains { isConvertible($0, to: t) }
            }
            claimed.formUnion(valid)
            if !valid.isEmpty { lists.append((g, valid)) }
        }
        // Share the petals round-robin, then show them grouped.
        var quota = Array(repeating: 0, count: lists.count)
        var left = maxConvertPetals
        var progressed = true
        while left > 0 && progressed {
            progressed = false
            for i in lists.indices where left > 0 && quota[i] < lists[i].1.count {
                quota[i] += 1
                left -= 1
                progressed = true
            }
        }
        return lists.enumerated().flatMap { i, pair in pair.1.prefix(quota[i]).map { (pair.0, $0) } }
    }

    private static func dominantFormat(_ entries: [FolderEntry]) -> FileFormat? {
        var counts: [FileFormat: Int] = [:]
        for e in entries { if let f = e.format { counts[f, default: 0] += 1 } }
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: Tools

    /// Tools that work on the contents of folders, by category.
    static let categoryTools: [FanCategory: [FileTool]] = [
        .optimize: [.compress, .removeMetadata],
        .combine: [.createPDF, .createCollage, .flattenFolder],
        .extract: [.recognizeText, .folderReport],
    ]

    /// Tools that only make sense for folders (kept out of presets and file selections).
    static let folderOnlyTools: Set<FileTool> = [.flattenFolder, .folderReport]

    /// Folder tools implemented by `FolderToolsModule`.
    static let folderTools: Set<FileTool> = [.compress, .removeMetadata, .createPDF, .createCollage,
                                             .recognizeText, .flattenFolder, .folderReport]

    /// Files inside the scan that `tool` processes.
    static func toolInputs(_ tool: FileTool, scan: FolderScan) -> [FolderEntry] {
        let files = scan.entries.filter { !$0.isPackage }
        switch tool {
        case .compress:
            return files.filter { e in e.format.map { tool.accepts($0) && $0.group != .audio } ?? false }
        case .removeMetadata:
            return files.filter { e in e.format.map(tool.accepts) ?? false }
        case .createPDF, .createCollage:
            return files.filter { $0.format?.isRasterImage == true }
        case .recognizeText:
            return files.filter { $0.format?.isRasterImage == true || $0.format == .pdf }
        case .flattenFolder, .folderReport:
            return scan.entries
        default:
            return []
        }
    }

    static func isAvailable(_ tool: FileTool, scan: FolderScan) -> Bool {
        let inputs = toolInputs(tool, scan: scan)
        switch tool {
        case .createCollage: return inputs.count >= 2
        case .flattenFolder: return inputs.contains { $0.root != nil && !$0.relativeDir.isEmpty }
        case .folderReport: return !scan.roots.isEmpty
        default: return !inputs.isEmpty
        }
    }

    /// What the options panel should show for a folder tool: the files it will process.
    static func panelInputs(_ tool: FileTool, urls: [URL]) -> [URL] {
        let inputs = toolInputs(tool, scan: cachedScan(urls)).map(\.url)
        return inputs.isEmpty ? urls : inputs
    }

    /// HUD line for a folder job, e.g. "Photos – 120 files".
    static func displayName(_ urls: [URL]) -> String {
        let scan = cachedScan(urls)
        let name = urls.count == 1 ? urls[0].lastPathComponent : Lp("%d items", urls.count)
        return name + " – " + Lp("%d files", scan.entries.count)
    }

    // MARK: Wheel

    /// All tool petals for a selection with folders (flat tools mode); nil when it has none.
    static func toolItems(urls: [URL]) -> [FanItem]? {
        guard containsFolder(urls) else { return nil }
        return FanCategory.allCases.filter { $0 != .convert && $0 != .share && $0 != .favorites }
            .flatMap { items(in: $0, urls: urls) ?? [] }
    }

    /// Items for `category` when the selection contains folders; nil when it doesn't.
    static func items(in category: FanCategory, urls: [URL]) -> [FanItem]? {
        guard containsFolder(urls) else { return nil }
        let scan = cachedScan(urls)
        switch category {
        case .convert:
            return convertTargets(scan).map { group, target in
                FanItem(kind: .format(target), title: convertTitle(group, target), symbol: groupSymbols[group] ?? "doc")
            }
        case .share:
            return nil   // actions work on folders as they are
        case .favorites:
            return []
        default:
            // Folder tools first, then whatever the regular catalog allows for folders (e.g. archiving).
            let ours = (categoryTools[category] ?? []).filter { isAvailable($0, scan: scan) }
            let generic = Set(FileTool.available(for: urls))
            let theirs = category.tools.filter { generic.contains($0) && !ours.contains($0) && !folderTools.contains($0) }
            return (ours + theirs).map { FanItem(kind: .tool($0), title: $0.title, symbol: $0.symbol) }
        }
    }
}
