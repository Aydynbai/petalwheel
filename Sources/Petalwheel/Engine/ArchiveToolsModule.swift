import Foundation

/// Archive tools: Extract, List Contents, Test Archive (any readable archive), Make Archive (files and
/// folders → zip / 7z / tar.* / iso / dmg, optional AES-256 zip password) and Compress File (gz / bz2 / xz / zst).
struct ArchiveToolsModule: ToolModule {
    init() {}

    func canRun(_ tool: FileTool, format: FileFormat?) -> Bool {
        switch tool {
        case .extractArchive, .listArchive, .testArchive: return format?.group == .archives
        case .createArchive, .compressSingle: return true
        default: return false
        }
    }

    func run(_ tool: FileTool, inputs: [URL], options: ToolOptions,
             progress: @escaping ProgressHandler) async throws -> ToolResult {
        guard !inputs.isEmpty else { throw PetalwheelError(l: "Nothing to process.") }
        switch tool {
        case .extractArchive, .listArchive, .testArchive, .compressSingle:
            var result = ToolResult()
            for (i, input) in inputs.enumerated() {
                try Task.checkCancellation()
                let base = Double(i) / Double(inputs.count)
                let p: ProgressHandler = { progress(base + $0 / Double(inputs.count)) }
                switch tool {
                case .extractArchive:
                    if let out = try await extract(input, options: options, progress: p) { result.outputs.append(out) }
                case .listArchive:
                    result.messages.append(try await list(input, options: options))
                case .testArchive:
                    if let message = try await test(input, options: options, progress: p) { result.messages.append(message) }
                default:
                    result.outputs.append(try await compressSingle(input, options: options, progress: p))
                }
            }
            progress(1)
            return result
        case .createArchive:
            let out = try await create(inputs, options: options, progress: progress)
            progress(1)
            return ToolResult(outputs: [out])
        default:
            throw PetalwheelError(l: "%@ isn't an archive tool.", tool.title)
        }
    }

    private func archiveFormat(_ url: URL) throws -> FileFormat {
        guard let format = FileFormat.detect(url), format.group == .archives else {
            throw PetalwheelError(l: "“%@” isn't a supported archive.", url.lastPathComponent)
        }
        return format
    }

    // MARK: - Extract

    /// nil when another job is already extracting the same multi-volume set.
    private func extract(_ archive: URL, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> URL? {
        let format = try archiveFormat(archive)
        let set = try ArchiveVolumeSet.resolve(archive)
        guard await ArchiveVolumeClaims.shared.claim(set.key) else { return nil }
        defer { Task { await ArchiveVolumeClaims.shared.release(set.key) } }

        let parent = archive.deletingLastPathComponent()
        let fm = FileManager.default
        // Stage next to the archive so the final move is a cheap rename on the same volume.
        var staging = parent.appendingPathComponent(".petalwheel-extract-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            staging = try OutputNaming.tempDirectory()
        }
        defer { ArchiveSupport.removeTree(staging) }

        try await ArchiveSupport.extract(archive, format: format, into: staging, options: options,
                                         tool: .extractArchive) { progress($0 * 0.95) }

        let base = ArchiveSupport.baseName(of: archive)
        let items = try ArchiveSupport.topLevelItems(staging)
        if items.isEmpty { throw PetalwheelError(l: "“%@” is empty.", archive.lastPathComponent) }

        // A single top-level item (a folder, or the file of a plain .gz) goes next to the archive as-is.
        if items.count == 1 {
            let destination = OutputNaming.unique(parent.appendingPathComponent(items[0].lastPathComponent))
            try fm.moveItem(at: items[0], to: destination)
            return destination
        }
        let destination = OutputNaming.unique(parent.appendingPathComponent(base, isDirectory: true))
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        for item in items {
            try fm.moveItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
        return destination
    }

    // MARK: - List

    private static let listLimit = 2000

    private func list(_ archive: URL, options: ToolOptions) async throws -> String {
        let format = try archiveFormat(archive)
        let entries = try await ArchiveSupport.entries(archive, format: format, options: options)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let files = entries.filter { !$0.isDirectory }
        let total = files.reduce(Int64(0)) { $0 + max($1.size, 0) }
        var lines: [String] = []
        if format.isSingleFileCompressor {
            lines.append(L("“%@” holds one compressed file:", archive.lastPathComponent))
        } else {
            lines.append(L("“%@”: %@, %@ unpacked", archive.lastPathComponent, Lp("%d files", files.count),
                           ArchiveSupport.formatSize(total)))
        }
        lines.append("")
        for e in entries.prefix(Self.listLimit) {
            let size = e.isDirectory || e.size < 0 ? "" : ArchiveSupport.formatSize(e.size)
            lines.append(size.padding(toLength: max(size.count, 10), withPad: " ", startingAt: 0) + "  " + e.path)
        }
        if entries.count > Self.listLimit {
            lines.append(L("…and %d more", entries.count - Self.listLimit))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Test

    private func test(_ archive: URL, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> String? {
        let format = try archiveFormat(archive)
        let set = try ArchiveVolumeSet.resolve(archive)
        guard await ArchiveVolumeClaims.shared.claim(set.key) else { return nil }
        defer { Task { await ArchiveVolumeClaims.shared.release(set.key) } }
        let (files, bytes) = try await ArchiveSupport.test(archive, format: format, options: options, progress: progress)
        if format == .dmg || format.isSingleFileCompressor {
            return L("“%@” is OK: no errors found.", archive.lastPathComponent)
        }
        return L("“%@” is OK: %@, %@, no errors found.", archive.lastPathComponent, Lp("%d files", files),
                 ArchiveSupport.formatSize(bytes))
    }

    // MARK: - Compress one file

    private func compressSingle(_ file: URL, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> URL {
        guard FileManager.default.fileExists(atPath: file.path), !ArchiveSupport.isDirectory(file) else {
            throw PetalwheelError(l: "“%@” isn't a file.", file.lastPathComponent)
        }
        let format = ArchiveSingleFile.writableFormats.contains(options.archiveFormat) ? options.archiveFormat : .gz
        progress(0.05)
        let output = OutputNaming.unique(file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + "." + format.fileExtension))
        let partial = partialURL(for: output)
        do {
            try await ArchiveSingleFile.compress(file, format: format, to: partial)
            try FileManager.default.moveItem(at: partial, to: output)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return output
    }

    // MARK: - Create

    private func create(_ inputs: [URL], options: ToolOptions, progress: @escaping ProgressHandler) async throws -> URL {
        let fm = FileManager.default
        for url in inputs where !fm.fileExists(atPath: url.path) {
            throw PetalwheelError(l: "“%@” no longer exists.", url.lastPathComponent)
        }
        let format = ArchiveSupport.createFormats.contains(options.archiveFormat) ? options.archiveFormat : .zip
        let password = format == .zip ? options.archivePassword.flatMap { $0.isEmpty ? nil : $0 } : nil
        let first = inputs[0]
        let directory = first.deletingLastPathComponent()
        progress(0.05)

        if inputs.count == 1 {
            let base = ArchiveSupport.isDirectory(first) ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
            let name = base.isEmpty ? first.lastPathComponent : base
            let output = ArchiveSupport.outputURL(for: first, format: format, baseName: name, in: directory)
            try await pack([first.lastPathComponent], in: directory, format: format, to: output, options: options,
                           password: password, volumeName: name) { progress(0.05 + $0 * 0.95) }
            return output
        }

        // Several items: stage clones (APFS copy-on-write, cheap) in a hidden folder next to the
        // first item, then pack the staging folder's contents.
        var staging = directory.appendingPathComponent(".petalwheel-zip-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: staging, withIntermediateDirectories: true) }
        catch { staging = try OutputNaming.tempDirectory() }
        defer { try? fm.removeItem(at: staging) }

        var used = Set<String>()
        var names: [String] = []
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            var name = url.lastPathComponent
            var n = 2
            while used.contains(name.lowercased()) {
                let ext = url.pathExtension
                let stem = url.deletingPathExtension().lastPathComponent
                name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                n += 1
            }
            used.insert(name.lowercased())
            names.append(name)
            try fm.copyItem(at: url, to: staging.appendingPathComponent(name))
            progress(0.05 + 0.25 * Double(i + 1) / Double(inputs.count))
        }
        let output = ArchiveSupport.outputURL(for: first, format: format, baseName: "Archive", in: directory)
        try await pack(names, in: staging, format: format, to: output, options: options,
                       password: password, volumeName: "Archive") { progress(0.3 + $0 * 0.7) }
        return output
    }

    /// Writes to a hidden temporary name first so a cancelled run never leaves a truncated archive behind.
    private func pack(_ names: [String], in dir: URL, format: FileFormat, to output: URL, options: ToolOptions,
                      password: String?, volumeName: String, progress: @escaping ProgressHandler) async throws {
        let partial = partialURL(for: output)
        do {
            try await ArchiveSupport.pack(names, in: dir, format: format, to: partial, level: options.archiveLevel,
                                          password: password, volumeName: volumeName, progress: progress)
            try FileManager.default.moveItem(at: partial, to: output)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Hidden sibling with the same extension (hdiutil insists on ".dmg").
    private func partialURL(for output: URL) -> URL {
        output.deletingLastPathComponent()
            .appendingPathComponent(".partial-\(UUID().uuidString)-\(output.lastPathComponent)")
    }
}

extension FileFormat {
    /// gz / bz2 / xz / zst: one compressed file, not a container.
    var isSingleFileCompressor: Bool { ArchiveSingleFile.formats.contains(self) }
}
