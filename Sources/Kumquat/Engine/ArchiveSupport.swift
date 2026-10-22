import Foundation

/// Shared helpers for ArchiveEngine and ArchiveToolsModule: safe extraction and packing with
/// the system's ditto / tar / gzip.
enum ArchiveSupport {
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")

    /// Junk that should never end up in a repacked archive.
    static func isJunk(_ name: String) -> Bool {
        name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix("._")
    }

    /// Extracts `archive` into the (existing, empty) directory `destination`.
    /// Rejects archives with entries that would escape the destination (zip-slip).
    static func extract(_ archive: URL, format: FileFormat, into destination: URL) async throws {
        let entries = try await listEntries(archive, format: format)
        for entry in entries where !isSafeEntry(entry) {
            throw KumquatError(l: "“%@” contains an unsafe path (%@). Extraction was stopped.", archive.lastPathComponent, entry)
        }
        switch format {
        case .zip:
            do {
                try await ProcessRunner.run(ditto, ["-x", "-k", archive.path, destination.path])
            } catch let e as ProcessError {
                throw KumquatError(l: "Couldn't extract “%@”: %@", archive.lastPathComponent, e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .tar, .tgz:
            if format == .tgz, entries.isEmpty, try await isPlainGzip(archive) {
                // A bare .gz (not a tarball): decompress the single file.
                var name = archive.deletingPathExtension().lastPathComponent
                if name.isEmpty { name = "file" }
                let copy = destination.appendingPathComponent(name + ".gz")
                try FileManager.default.copyItem(at: archive, to: copy)
                try await ProcessRunner.run(gzip, ["-d", "-f", copy.path])
                return
            }
            do {
                try await ProcessRunner.run(tar, ["-x", "-f", archive.path, "-C", destination.path])
            } catch let e as ProcessError {
                throw KumquatError(l: "Couldn't extract “%@”: %@", archive.lastPathComponent, e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        default:
            throw KumquatError(l: "%@ isn't an archive format.", format.title)
        }
        try removeJunk(in: destination)
        try verifyContained(destination)
    }

    private static func isPlainGzip(_ url: URL) async throws -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let magic = (try? h.read(upToCount: 2)) ?? Data()
        return magic == Data([0x1F, 0x8B])
    }

    static func listEntries(_ archive: URL, format: FileFormat) async throws -> [String] {
        switch format {
        case .zip:
            do {
                let out = try await ProcessRunner.run(unzip, ["-Z1", archive.path]).stdout
                return out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            } catch {
                throw KumquatError(l: "“%@” isn't a valid zip archive.", archive.lastPathComponent)
            }
        case .tar, .tgz:
            do {
                let out = try await ProcessRunner.run(tar, ["-t", "-f", archive.path]).stdout
                return out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            } catch {
                if format == .tgz, try await isPlainGzip(archive) { return [] }
                throw KumquatError(l: "“%@” isn't a valid %@ archive.", archive.lastPathComponent, format.title)
            }
        default:
            return []
        }
    }

    static func isSafeEntry(_ entry: String) -> Bool {
        if entry.hasPrefix("/") || entry.hasPrefix("\\") { return false }
        let components = entry.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !components.contains("..")
    }

    /// Defense in depth: no symlink inside the extracted tree may point outside of it.
    static func verifyContained(_ root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
            let target = dest.hasPrefix("/") ? URL(fileURLWithPath: dest)
                : url.deletingLastPathComponent().appendingPathComponent(dest)
            let resolved = target.standardizedFileURL.path
            if !(resolved == rootPath || resolved.hasPrefix(rootPath + "/")) {
                // Neutralize instead of failing: dangling outward links are removed.
                try? fm.removeItem(at: url)
            }
        }
    }

    static func removeJunk(in dir: URL) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: []) else { return }
        var toRemove: [URL] = []
        for case let url as URL in e where isJunk(url.lastPathComponent) {
            toRemove.append(url)
            e.skipDescendants()
        }
        for url in toRemove { try? fm.removeItem(at: url) }
    }

    /// Visible top-level items of a directory.
    static func topLevelItems(_ dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            .filter { !isJunk($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Packs the *contents* of `dir` into `output`.
    static func pack(contentsOf dir: URL, format: FileFormat, to output: URL) async throws {
        let items = try topLevelItems(dir)
        switch format {
        case .zip:
            try await ProcessRunner.run(ditto, ["-c", "-k", "--sequesterRsrc", dir.path, output.path])
        case .tar, .tgz:
            guard !items.isEmpty else { throw KumquatError(l: "The archive is empty.") }
            var args = [format == .tgz ? "-czf" : "-cf", output.path, "--no-mac-metadata", "--exclude", ".DS_Store", "-C", dir.path]
            args += items.map(\.lastPathComponent)
            try await ProcessRunner.run(tar, args)
        default:
            throw KumquatError(l: "%@ isn't an archive format.", format.title)
        }
    }

    /// Output URL for an archive, handling the two-part "tar.gz" extension when picking a unique name.
    static func outputURL(for source: URL, format: FileFormat, baseName: String? = nil, in directory: URL? = nil) -> URL {
        let dir = directory ?? source.deletingLastPathComponent()
        var base = baseName ?? source.deletingPathExtension().lastPathComponent
        if baseName == nil, base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let ext = format.fileExtension
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(i).\(ext)")
            i += 1
        }
        return candidate
    }

    /// Total size of regular files under `url` (for progress estimates).
    static func totalSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        if !isDirectory(url) { return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }
}
