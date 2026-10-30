import Foundation

/// One item of an archive listing.
struct ArchiveEntry {
    var path: String
    var size: Int64
    var isDirectory: Bool
    /// Hard-link target (another entry of the archive). Symlinks are checked after extraction instead.
    var linkTarget: String?
}

/// Password outcomes that the callers turn into a prompt or a message.
enum ArchiveFailure: Error {
    case passwordRequired, wrongPassword, unsupportedEncryption
}

/// Shared archive machinery for ArchiveEngine and ArchiveToolsModule, built on the system libarchive
/// (/usr/bin/bsdtar) plus hdiutil for disk images.
///
/// Reads: zip (incl. AES / ZipCrypto with a password, CP866 / CP1251 names), 7z, rar / rar5 (incl. volumes),
/// tar with gz / bz2 / xz / lzma / lzip / Z (zst and lz4 need the zstd / lz4 tools), iso, cab, xar / pkg,
/// cpio, lha / lzh, ar / deb, dmg, and single-file gz / bz2 / xz / zst.
/// Writes: zip, 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst, iso, dmg.
/// RAR is never written: creating RAR archives is restricted by the RAR license (only WinRAR may do it).
enum ArchiveSupport {
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    /// The macOS libarchive has no built-in zstd / lz4: bsdtar runs these tools when they're installed.
    static let zstd = ExternalTools.find("zstd")
    static let lz4 = ExternalTools.find("lz4")

    /// Size limits of the zip-bomb guard: both must be exceeded to ask.
    static let bombRatio: Int64 = 20
    static let bombMinimum: Int64 = 2 << 30

    /// bsdtar's environment: UTF-8 names in listings and a PATH that finds zstd / lz4.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        var dirs: [String] = []
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("Tools").path) }
        for tool in [zstd, lz4].compactMap({ $0 }) { dirs.append(tool.deletingLastPathComponent().path) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        env["PATH"] = dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        return env
    }()

    /// Archive formats NurTo can write (conversion targets and "Make Archive" choices).
    static var conversionTargets: [FileFormat] {
        var r: [FileFormat] = [.zip, .sevenZ, .tar, .tgz, .tbz2, .txz]
        if zstd != nil { r.append(.tzst) }
        return r + [.iso, .dmg]
    }

    static var createFormats: [FileFormat] { conversionTargets }

    static func missingTool(_ name: String) -> NurToError {
        NurToError(l: "%@ is not installed. Install it with: brew install %@", name, name)
    }

    // MARK: - Files

    /// Junk that should never end up in a repacked archive.
    static func isJunk(_ name: String) -> Bool {
        name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix("._")
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

    /// Read-only trees (ISO images, some tars) can't be moved or deleted: give the owner write access.
    static func makeOwnerWritable(_ root: URL) {
        let fm = FileManager.default
        func fix(_ path: String) {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) != .typeSymbolicLink,
                  let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue, perm & 0o200 == 0 else { return }
            try? fm.setAttributes([.posixPermissions: perm | 0o200], ofItemAtPath: path)
        }
        fix(root.path)
        guard let e = fm.enumerator(atPath: root.path) else { return }
        while let rel = e.nextObject() as? String { fix(root.appendingPathComponent(rel).path) }
    }

    /// Removes a temporary tree, read-only parts included.
    static func removeTree(_ url: URL) {
        makeOwnerWritable(url)
        try? FileManager.default.removeItem(at: url)
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

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Total size of regular files under `url` (for progress estimates).
    static func totalSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        if !isDirectory(url) { return fileSize(url) }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += fileSize(f) }
        }
        return total
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `photos.tar.xz` → `photos`, `movie.part1.rar` → `movie`, `backup.7z.001` → `backup`.
    static func baseName(of url: URL) -> String {
        var name = url.lastPathComponent
        let patterns = [#"\.part\d+\.rar$"#, #"\.(7z|zip)\.\d{3}$"#, #"\.[rz]\d\d$"#,
                        #"\.tar\.(gz|bz2|bz|xz|zst|zstd|lz4|lzma|lz|z)$"#]
        for p in patterns {
            if let r = name.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                name = String(name[..<r.lowerBound])
                return name.isEmpty ? "Archive" : name
            }
        }
        name = (name as NSString).deletingPathExtension
        if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        return name.isEmpty ? "Archive" : name
    }

    /// Output URL for an archive, handling two-part extensions ("tar.gz") when picking a unique name.
    static func outputURL(for source: URL, format: FileFormat, baseName: String? = nil, in directory: URL? = nil) -> URL {
        let dir = directory ?? source.deletingLastPathComponent()
        let base = baseName ?? Self.baseName(of: source)
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

    /// NUL-separated name list for `bsdtar --null -T` (names starting with "@" or "-" are taken literally).
    static func nameList(_ names: [String], near: URL) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("petalwheel-names-\(UUID().uuidString)")
        var data = Data()
        for n in names { data.append(Data(n.utf8)); data.append(0) }
        try data.write(to: url)
        return url
    }

    // MARK: - Opening

    /// An archive ready for bsdtar: volumes resolved, zip inspected, byte-split parts joined.
    struct Prepared {
        let url: URL
        let format: FileFormat
        let volumes: ArchiveVolumeSet
        let zip: ZipInspection?
        let readURL: URL
        let joinedTemp: URL?
        var streamed: Bool { volumes.kind == .streamed }
        var packedSize: Int64 { volumes.totalSize }

        func cleanup() {
            if let joinedTemp { ArchiveSupport.removeTree(joinedTemp) }
        }

        /// bsdtar arguments that select the input (plus charset / passphrase options).
        func readArguments(password: String?) -> (args: [String], input: ArchiveProcess.Input) {
            var args: [String] = []
            if let cs = zip?.nameCharset { args += ["--options", "hdrcharset=\(cs)"] }
            // Always passed: without it bsdtar would ask on the terminal for encrypted entries.
            args += ["--passphrase", password ?? "-"]
            if streamed { return (args + ["-f", "-"], .files(volumes.volumes)) }
            return (args + ["-f", readURL.path], .none)
        }
    }

    static func prepare(_ url: URL, format: FileFormat) async throws -> Prepared {
        let set = try ArchiveVolumeSet.resolve(url)
        var readURL = set.volumes.first ?? url
        var joined: URL?
        if set.kind == .joined {
            let temp = try OutputNaming.tempDirectory()
            let target = temp.appendingPathComponent("joined." + (format == .sevenZ ? "7z" : "zip"))
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            do {
                for part in set.volumes {
                    try Task.checkCancellation()
                    let h = try FileHandle(forReadingFrom: part)
                    defer { try? h.close() }
                    while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
            readURL = target
            joined = temp
        }
        let zip = (format == .zip && set.kind != .streamed) ? ArchiveInspector.inspectZip(readURL) : nil
        return Prepared(url: url, format: format, volumes: set, zip: zip, readURL: readURL, joinedTemp: joined)
    }

    // MARK: - Listing

    static func list(_ p: Prepared, password: String?) async throws -> [ArchiveEntry] {
        let (args, input) = p.readArguments(password: password)
        do {
            let out = try await ArchiveProcess.run(bsdtar, ["-t", "-v"] + args, environment: environment, input: input).stdout
            return parseListing(out)
        } catch let e as ProcessError {
            throw translate(e, archive: p.url)
        }
    }

    private static let listingLine = try! NSRegularExpression(
        pattern: #"^(\S{10})\S*\s+\d+\s+(.+?)\s+(.+?)\s+(\d+|\d+,\s*\d+)\s+(\w{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.*)$"#)

    /// Parses `bsdtar -tv` lines: mode links owner group size month day time|year name [-> target | link to target].
    static func parseListing(_ text: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            let r = NSRange(s.startIndex..., in: s)
            guard let m = listingLine.firstMatch(in: s, range: r),
                  let modeR = Range(m.range(at: 1), in: s), let sizeR = Range(m.range(at: 4), in: s),
                  let nameR = Range(m.range(at: 8), in: s) else { continue }
            let mode = s[modeR]
            var name = String(s[nameR])
            var target: String?
            if mode.hasPrefix("l"), let arrow = name.range(of: " -> ", options: .backwards) {
                name = String(name[..<arrow.lowerBound])
            } else if let link = name.range(of: " link to ", options: .backwards) {
                target = unescape(String(name[link.upperBound...]))
                name = String(name[..<link.lowerBound])
            }
            let path = unescape(name)
            if path == "." || path == "./" { continue }
            entries.append(ArchiveEntry(path: path, size: Int64(s[sizeR]) ?? 0,
                                        isDirectory: mode.hasPrefix("d"), linkTarget: target))
        }
        return entries
    }

    /// Undoes bsdtar's escaping of names (`\ooo` octal bytes, `\\`, `\n`…).
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == 0x5C, i + 1 < u.count {
                let n = u[i + 1]
                if i + 3 < u.count, (0x30...0x37).contains(n), (0x30...0x37).contains(u[i + 2]), (0x30...0x37).contains(u[i + 3]) {
                    bytes.append(UInt8(truncatingIfNeeded: Int(n - 0x30) * 64 + Int(u[i + 2] - 0x30) * 8 + Int(u[i + 3] - 0x30)))
                    i += 4
                    continue
                }
                let map: [UInt8: UInt8] = [0x5C: 0x5C, 0x6E: 0x0A, 0x74: 0x09, 0x72: 0x0D, 0x61: 0x07, 0x62: 0x08, 0x66: 0x0C, 0x76: 0x0B]
                if let c = map[n] { bytes.append(c); i += 2; continue }
            }
            bytes.append(u[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Safety

    static func isSafeEntry(_ entry: String) -> Bool {
        if entry.hasPrefix("/") || entry.hasPrefix("\\") || entry.hasPrefix("~") { return false }
        let components = entry.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if let first = components.first, first.count == 2, first.last == ":" { return false }   // C:\…
        return !components.contains("..")
    }

    /// Refuses archives with absolute paths or `..` anywhere (names and hard-link targets).
    static func checkSafety(_ entries: [ArchiveEntry], archive: URL) throws {
        for e in entries {
            if !isSafeEntry(e.path) {
                throw NurToError(l: "“%@” contains an unsafe path (%@). Extraction was stopped.", archive.lastPathComponent, e.path)
            }
            if let t = e.linkTarget, !isSafeEntry(t) {
                throw NurToError(l: "“%@” contains an unsafe path (%@). Extraction was stopped.", archive.lastPathComponent, e.path + " → " + t)
            }
        }
    }

    /// Zip-bomb guard: asks (or, without UI, refuses) when the declared size is huge relative to the archive.
    static func checkBomb(unpacked: Int64, packed: Int64, archive: URL) async throws {
        guard unpacked > bombMinimum, unpacked > packed * bombRatio else { return }
        if await ArchivePrompts.confirmLargeExtraction(archive: archive, packed: packed, unpacked: unpacked) { return }
        throw NurToError(l: "“%@” would unpack to %@, %d times its own size. It looks like a zip bomb, so nothing was extracted.",
                              archive.lastPathComponent, formatSize(unpacked), Int(unpacked / max(packed, 1)))
    }

    /// Defense in depth: no symlink inside the extracted tree may point outside of it.
    static func verifyContained(_ root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            let target = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : parent.appendingPathComponent(dest)
            let resolved = target.standardizedFileURL.path
            if !(resolved == rootPath || resolved.hasPrefix(rootPath + "/")) {
                // Neutralize instead of failing: outward links are removed.
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Errors

    /// Turns bsdtar's stderr into a password outcome or a readable message.
    static func translate(_ e: ProcessError, archive: URL) -> Error {
        let text = e.stderr
        let lower = text.lowercased()
        let name = archive.lastPathComponent
        if lower.contains("incorrect passphrase") || lower.contains("too many incorrect passphrases") {
            return ArchiveFailure.wrongPassword
        }
        if lower.contains("passphrase required") { return ArchiveFailure.passwordRequired }
        if lower.contains("ncrypt") || lower.contains("passphrase") { return ArchiveFailure.unsupportedEncryption }
        if let r = text.range(of: #"(?:program|external program:?) "?([a-z0-9]+)"#, options: .regularExpression),
           lower.contains("can't launch") || lower.contains("unable to run") {
            let tool = String(text[r]).components(separatedBy: CharacterSet(charactersIn: " \":")).last { !$0.isEmpty } ?? "zstd"
            return missingTool(tool)
        }
        // With -v, an error is appended to the entry's "x name" line.
        let lines = text.split(separator: "\n").map { line -> String in
            var l = line.replacingOccurrences(of: "bsdtar: ", with: "")
            if l.hasPrefix("x ") || l.hasPrefix("a ") { l.removeFirst(2) }
            return l.replacingOccurrences(of: ": Inappropriate file type or format", with: "")
        }.filter { !$0.isEmpty && !$0.contains("Error exit delayed") }
        let detail = lines.first { $0.contains(": ") } ?? lines.first ?? ""
        if lower.contains("unrecognized archive format") {
            return NurToError(l: "“%@” isn't an archive NurTo can read, or it is damaged.", name)
        }
        if lower.contains("unsupported") {
            return NurToError(l: "“%@” uses a compression method NurTo can't read yet: %@", name, detail)
        }
        if ["truncated", "premature end", "damaged", "crc", "checksum", "corrupt", "invalid", "bad ", "unexpected end"]
            .contains(where: lower.contains) {
            return NurToError(l: "“%@” is damaged or incomplete: %@", name, detail)
        }
        return NurToError(l: "Couldn't read “%@”: %@", name, detail.isEmpty ? e.localizedDescription : detail)
    }

    /// Runs `body` with the archive password: asks for it (UI) when the archive is known to be encrypted
    /// or turns out to be, and again after a wrong one. CLI mode uses `--password` only.
    static func withPassword<T>(_ archive: URL, needsPassword: Bool, options: ToolOptions, tool: FileTool,
                                _ body: (String?) async throws -> T) async throws -> T {
        var password = options.archivePassword
        if needsPassword && password == nil {
            password = await ArchivePrompts.askPassword(tool: tool, archive: archive, previous: nil)
            if password == nil {
                if await ArchivePrompts.isInteractive { throw CancellationError() }
                throw NurToError(l: "“%@” is password-protected. Pass the password with --password.", archive.lastPathComponent)
            }
        }
        var attempts = 0
        while true {
            do {
                return try await body(password)
            } catch ArchiveFailure.unsupportedEncryption {
                throw NurToError(l: "This archive is password-protected in a way NurTo can't open yet.")
            } catch let failure as ArchiveFailure {
                attempts += 1
                let interactive = await ArchivePrompts.isInteractive
                if !interactive || attempts >= 4 {
                    if password == nil || failure == .passwordRequired && !interactive {
                        throw NurToError(l: "“%@” is password-protected. Pass the password with --password.", archive.lastPathComponent)
                    }
                    throw NurToError(l: "The password for “%@” is wrong.", archive.lastPathComponent)
                }
                guard let next = await ArchivePrompts.askPassword(tool: tool, archive: archive, previous: password ?? "") else {
                    throw CancellationError()
                }
                password = next
            }
        }
    }

    // MARK: - Extract

    /// Extracts `archive` into the (existing, empty) directory `destination`. Refuses archives with entries that
    /// would escape it (zip-slip), asks before zip bombs, neutralizes outward symlinks and drops Mac junk.
    static func extract(_ archive: URL, format: FileFormat, into destination: URL,
                        options: ToolOptions = ToolOptions(), tool: FileTool = .extractArchive,
                        progress: @escaping ProgressHandler = { _ in }) async throws {
        switch format {
        case .dmg:
            let encrypted = await ArchiveDiskImage.isEncrypted(archive)
            try await withPassword(archive, needsPassword: encrypted, options: options, tool: tool) { pw in
                try await ArchiveDiskImage.extract(archive, password: encrypted ? pw : nil, into: destination, progress: progress)
            }
        case .gz, .bz2, .xz, .zst:
            progress(0.1)
            try await ArchiveSingleFile.decompress(archive, format: format, into: destination)
        default:
            guard format.group == .archives else { throw NurToError(l: "%@ isn't an archive format.", format.title) }
            let p = try await prepare(archive, format: format)
            defer { p.cleanup() }
            // Zip names aren't encrypted, so listing works before the password is known.
            let entries = try await withPassword(archive, needsPassword: false, options: options, tool: tool) { pw in
                try await list(p, password: pw)
            }
            try checkSafety(entries, archive: archive)
            let declared = max(entries.reduce(0) { $0 + $1.size }, p.zip?.totalUncompressed ?? 0)
            try await checkBomb(unpacked: declared, packed: p.packedSize, archive: archive)
            progress(0.1)
            let total = Double(max(entries.count, 1))
            try await withPassword(archive, needsPassword: p.zip?.encrypted == true, options: options, tool: tool) { pw in
                let (args, input) = p.readArguments(password: pw)
                let counter = ArchiveLineCounter { n in progress(0.1 + 0.9 * min(1, Double(n) / total)) }
                do {
                    try await ArchiveProcess.run(bsdtar, ["-x", "-v", "--no-same-owner", "-C", destination.path] + args,
                                                 environment: environment, input: input, onStderr: { counter.consume($0) })
                } catch let e as ProcessError {
                    throw translate(e, archive: archive)
                }
            }
        }
        makeOwnerWritable(destination)
        try removeJunk(in: destination)
        try verifyContained(destination)
        progress(1)
    }

    /// Reads every byte of every entry (CRCs, decryption) without writing anything.
    static func test(_ archive: URL, format: FileFormat, options: ToolOptions,
                     progress: @escaping ProgressHandler) async throws -> (files: Int, bytes: Int64) {
        switch format {
        case .dmg:
            try await ArchiveDiskImage.verify(archive)
            return (0, fileSize(archive))
        case .gz, .bz2, .xz, .zst:
            try await ArchiveSingleFile.test(archive, format: format)
            return (1, fileSize(archive))
        default:
            let p = try await prepare(archive, format: format)
            defer { p.cleanup() }
            let entries = try await withPassword(archive, needsPassword: false, options: options, tool: .testArchive) { pw in
                try await list(p, password: pw)
            }
            progress(0.2)
            try await withPassword(archive, needsPassword: p.zip?.encrypted == true, options: options, tool: .testArchive) { pw in
                let (args, input) = p.readArguments(password: pw)
                do {
                    // No -v: then every stderr line is an error.
                    try await ArchiveProcess.run(bsdtar, ["-x", "-O"] + args, environment: environment, input: input,
                                                 stdoutTo: FileHandle.nullDevice)
                } catch let e as ProcessError {
                    // libarchive's RAR5 reader refuses to "decompress" directory entries to stdout: not damage.
                    let real = e.stderr.split(separator: "\n").filter {
                        !$0.contains("Error exit delayed") && !$0.contains("entry marked as a directory")
                    }
                    if real.isEmpty { return }
                    throw translate(ProcessError(tool: e.tool, status: e.status, stderr: real.joined(separator: "\n")), archive: archive)
                }
            }
            let files = entries.filter { !$0.isDirectory }
            return (files.count, files.reduce(0) { $0 + $1.size })
        }
    }

    /// Lists without extracting (disk images are mounted read-only).
    static func entries(_ archive: URL, format: FileFormat, options: ToolOptions) async throws -> [ArchiveEntry] {
        switch format {
        case .dmg:
            let encrypted = await ArchiveDiskImage.isEncrypted(archive)
            return try await withPassword(archive, needsPassword: encrypted, options: options, tool: .listArchive) { pw in
                try await ArchiveDiskImage.list(archive, password: encrypted ? pw : nil)
            }
        case .gz, .bz2, .xz, .zst:
            return [ArchiveEntry(path: ArchiveSingleFile.decompressedName(archive), size: -1, isDirectory: false, linkTarget: nil)]
        default:
            let p = try await prepare(archive, format: format)
            defer { p.cleanup() }
            return try await withPassword(archive, needsPassword: false, options: options, tool: .listArchive) { pw in
                try await list(p, password: pw)
            }
        }
    }

    // MARK: - Pack

    /// Packs `names` (items directly inside `dir`) into `output`, which must not exist yet.
    /// `level` 1...9 applies to zip and 7z; `password` to zip only (AES-256).
    static func pack(_ names: [String], in dir: URL, format: FileFormat, to output: URL,
                     level: Int = 6, password: String? = nil, volumeName: String? = nil,
                     progress: @escaping ProgressHandler = { _ in }) async throws {
        guard !names.isEmpty else { throw NurToError(l: "The archive is empty.") }
        let label = volumeName ?? output.deletingPathExtension().lastPathComponent
        if format == .dmg {
            // hdiutil images a whole folder: stage the items unless `dir` holds exactly them.
            let all = try topLevelItems(dir).map(\.lastPathComponent)
            if Set(all) == Set(names) {
                try await ArchiveDiskImage.create(from: dir, volumeName: label, to: output, progress: progress)
            } else {
                let temp = try OutputNaming.tempDirectory()
                defer { try? FileManager.default.removeItem(at: temp) }
                for n in names { try FileManager.default.copyItem(at: dir.appendingPathComponent(n), to: temp.appendingPathComponent(n)) }
                try await ArchiveDiskImage.create(from: temp, volumeName: label, to: output, progress: progress)
            }
            return
        }
        let level = min(max(level, 1), 9)
        var args = ["-c", "-v", "-f", output.path, "--no-mac-metadata",
                    "--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX"]
        switch format {
        case .zip:
            var opts = "zip:compression-level=\(level),zip:hdrcharset=UTF-8"
            if password != nil { opts += ",zip:encryption=aes256" }
            args += ["--format", "zip", "--options", opts]
            if let password { args += ["--passphrase", password] }
        case .sevenZ:
            args += ["--format", "7zip", "--options", "7zip:compression=lzma2,7zip:compression-level=\(level)"]
        case .tar: break
        case .tgz: args.append("--gzip")
        case .tbz2: args.append("--bzip2")
        case .txz: args.append("--xz")
        case .tzst:
            guard zstd != nil else { throw missingTool("zstd") }
            args.append("--zstd")
        case .iso:
            args += ["--format", "iso9660", "--options", "iso9660:volume-id=\(isoVolumeID(label)),iso9660:joliet=long"]
        default:
            throw NurToError(l: "NurTo can't create %@ archives.", format.title)
        }
        let list = try nameList(names, near: output)
        defer { try? FileManager.default.removeItem(at: list) }
        var total = 0
        for n in names {
            let u = dir.appendingPathComponent(n)
            total += 1
            if isDirectory(u), let e = FileManager.default.enumerator(atPath: u.path) { while e.nextObject() != nil { total += 1 } }
        }
        let counter = ArchiveLineCounter { n in progress(min(1, Double(n) / Double(max(total, 1)))) }
        do {
            try await ArchiveProcess.run(bsdtar, args + ["-C", dir.path, "--null", "-T", list.path],
                                         environment: environment, onStderr: { counter.consume($0) })
        } catch {
            try? FileManager.default.removeItem(at: output)
            if let e = error as? ProcessError {
                if e.stderr.contains("external program") || e.stderr.contains("unable to run program") {
                    throw translate(e, archive: output)
                }
                throw NurToError(l: "Couldn't create %@: %@", format.title, e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw error
        }
        progress(1)
    }

    /// Packs the *contents* of `dir` into `output`.
    static func pack(contentsOf dir: URL, format: FileFormat, to output: URL, volumeName: String? = nil,
                     progress: @escaping ProgressHandler = { _ in }) async throws {
        let names = try topLevelItems(dir).map(\.lastPathComponent)
        try await pack(names, in: dir, format: format, to: output, volumeName: volumeName, progress: progress)
    }

    /// ISO 9660 volume IDs: up to 32 of A-Z 0-9 _.
    private static func isoVolumeID(_ name: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let id = String(name.uppercased().map { allowed.contains($0) ? $0 : "_" }.prefix(32))
        return id.trimmingCharacters(in: CharacterSet(charactersIn: "_")).isEmpty ? "ARCHIVE" : id
    }
}
