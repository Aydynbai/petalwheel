import Foundation

/// Tools: Extract (any zip / tar / tar.gz) and Zip (files and folders → one zip).
struct ArchiveToolsModule: ToolModule {
    init() {}

    func canRun(_ tool: FileTool, format: FileFormat?) -> Bool {
        switch tool {
        case .extractArchive: return format?.group == .archives
        case .createArchive: return true
        default: return false
        }
    }

    func run(_ tool: FileTool, inputs: [URL], options: ToolOptions,
             progress: @escaping ProgressHandler) async throws -> ToolResult {
        guard !inputs.isEmpty else { throw PetalwheelError(l: "Nothing to process.") }
        switch tool {
        case .extractArchive:
            var result = ToolResult()
            for (i, archive) in inputs.enumerated() {
                try Task.checkCancellation()
                let base = Double(i) / Double(inputs.count)
                let out = try await extract(archive) { p in progress(base + p / Double(inputs.count)) }
                result.outputs.append(out)
            }
            progress(1)
            return result
        case .createArchive:
            let out = try await createZip(inputs, progress: progress)
            progress(1)
            return ToolResult(outputs: [out])
        default:
            throw PetalwheelError(l: "%@ isn't an archive tool.", tool.title)
        }
    }

    // MARK: - Extract

    private func extract(_ archive: URL, progress: @escaping ProgressHandler) async throws -> URL {
        guard let format = FileFormat.detect(archive), format.group == .archives else {
            throw PetalwheelError(l: "“%@” isn't a supported archive.", archive.lastPathComponent)
        }
        let parent = archive.deletingLastPathComponent()
        let fm = FileManager.default
        // Stage next to the archive so the final move is a cheap rename on the same volume.
        var staging = parent.appendingPathComponent(".petalwheel-extract-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            staging = try OutputNaming.tempDirectory()
        }
        defer { try? fm.removeItem(at: staging) }

        progress(0.1)
        try await ArchiveSupport.extract(archive, format: format, into: staging)
        progress(0.85)

        var base = archive.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let items = try ArchiveSupport.topLevelItems(staging)
        if items.isEmpty { throw PetalwheelError(l: "“%@” is empty.", archive.lastPathComponent) }

        // A single top-level folder is extracted as-is, without wrapping it in another folder.
        if items.count == 1, ArchiveSupport.isDirectory(items[0]) {
            let destination = OutputNaming.unique(parent.appendingPathComponent(items[0].lastPathComponent, isDirectory: true))
            try fm.moveItem(at: items[0], to: destination)
            return destination
        }
        // A single file (e.g. a plain .gz) goes straight next to the archive.
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

    // MARK: - Create

    private func createZip(_ inputs: [URL], progress: @escaping ProgressHandler) async throws -> URL {
        let fm = FileManager.default
        for url in inputs where !fm.fileExists(atPath: url.path) {
            throw PetalwheelError(l: "“%@” no longer exists.", url.lastPathComponent)
        }
        let first = inputs[0]
        let directory = first.deletingLastPathComponent()
        progress(0.05)

        if inputs.count == 1 {
            let base = ArchiveSupport.isDirectory(first) ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
            let output = ArchiveSupport.outputURL(for: first, format: .zip, baseName: base.isEmpty ? first.lastPathComponent : base, in: directory)
            try await zip(["-c", "-k", "--sequesterRsrc", "--keepParent", first.path], output: output)
            return output
        }

        // Several items: stage clones (APFS copy-on-write, cheap) in a hidden folder next to the
        // first item, then zip the staging folder's contents.
        var staging = directory.appendingPathComponent(".petalwheel-zip-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: staging, withIntermediateDirectories: true) }
        catch { staging = try OutputNaming.tempDirectory() }
        defer { try? fm.removeItem(at: staging) }

        var used = Set<String>()
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
            try fm.copyItem(at: url, to: staging.appendingPathComponent(name))
            progress(0.05 + 0.45 * Double(i + 1) / Double(inputs.count))
        }
        let output = ArchiveSupport.outputURL(for: first, format: .zip, baseName: "Archive", in: directory)
        try await zip(["-c", "-k", "--sequesterRsrc", staging.path], output: output)
        return output
    }

    private func zip(_ args: [String], output: URL) async throws {
        // Write to a temporary name first so a cancelled run never leaves a truncated zip behind.
        let partial = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try await ProcessRunner.run(ArchiveSupport.ditto, args + [partial.path])
            try FileManager.default.moveItem(at: partial, to: output)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if let e = error as? ProcessError {
                throw PetalwheelError(l: "Couldn't create the zip: %@", e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw error
        }
    }
}
