import Foundation

/// Disk images through /usr/bin/hdiutil: extract = attach read-only without Finder, copy, detach.
enum ArchiveDiskImage {
    static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    static func isEncrypted(_ dmg: URL) async -> Bool {
        guard let out = try? await ArchiveProcess.run(hdiutil, ["isencrypted", dmg.path]).stdout else { return false }
        return out.lowercased().contains("encrypted: yes")
    }

    /// Attaches `dmg`, runs `body` with the mount point and always detaches afterwards.
    static func withMounted<T>(_ dmg: URL, password: String?, _ body: (URL) async throws -> T) async throws -> T {
        let temp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let mount = temp.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        var args = ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mount.path]
        var input = ArchiveProcess.Input.none
        if let password {
            args.append("-stdinpass")
            input = .data(Data(password.utf8) + Data([0]))
        }
        do {
            try await ArchiveProcess.run(hdiutil, args + [dmg.path], input: input)
        } catch let e as ProcessError {
            let text = e.stderr.lowercased()
            if text.contains("authentication error") || text.contains("passphrase") {
                throw ArchiveFailure.wrongPassword
            }
            if text.contains("license") || text.contains("agree") {
                throw PetalwheelError(l: "“%@” shows a license agreement first. Open it in Finder once, then try again.", dmg.lastPathComponent)
            }
            throw PetalwheelError(l: "Couldn't open the disk image “%@”: %@", dmg.lastPathComponent,
                                  e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            let result = try await body(mount)
            await detach(mount)
            return result
        } catch {
            await detach(mount)
            throw error
        }
    }

    private static func detach(_ mount: URL) async {
        if (try? await ArchiveProcess.run(hdiutil, ["detach", mount.path, "-quiet"])) == nil {
            _ = try? await ArchiveProcess.run(hdiutil, ["detach", mount.path, "-force", "-quiet"])
        }
    }

    /// Visible top-level items of a mounted volume (no .Trashes, .fseventsd, .background…).
    static func visibleItems(_ mount: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil, options: [])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && !ArchiveSupport.isJunk($0.lastPathComponent) }
    }

    static func extract(_ dmg: URL, password: String?, into destination: URL, progress: @escaping ProgressHandler) async throws {
        try await withMounted(dmg, password: password) { mount in
            let items = visibleItems(mount)
            for (i, item) in items.enumerated() {
                try Task.checkCancellation()
                try await ArchiveProcess.run(ArchiveSupport.ditto, [item.path, destination.appendingPathComponent(item.lastPathComponent).path])
                progress(Double(i + 1) / Double(max(items.count, 1)))
            }
        }
    }

    static func list(_ dmg: URL, password: String?) async throws -> [ArchiveEntry] {
        try await withMounted(dmg, password: password) { mount in walk(mount) }
    }

    private static func walk(_ mount: URL) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let base = mount.standardizedFileURL.path
        for item in visibleItems(mount) {
            entries.append(entry(item, base: base))
            guard ArchiveSupport.isDirectory(item),
                  let e = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            for case let url as URL in e { entries.append(entry(url, base: base)) }
        }
        return entries
    }

    private static func entry(_ url: URL, base: String) -> ArchiveEntry {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
        var path = url.standardizedFileURL.path
        if path.hasPrefix(base + "/") { path = String(path.dropFirst(base.count + 1)) }
        let isDir = v?.isDirectory == true && v?.isSymbolicLink != true
        return ArchiveEntry(path: isDir ? path + "/" : path, size: Int64(v?.fileSize ?? 0), isDirectory: isDir, linkTarget: nil)
    }

    /// Checksum verification (images without a checksum only get their structure checked).
    static func verify(_ dmg: URL) async throws {
        do {
            try await ArchiveProcess.run(hdiutil, ["verify", "-quiet", dmg.path])
        } catch let e as ProcessError {
            throw PetalwheelError(l: "“%@” is damaged: %@", dmg.lastPathComponent, e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Compressed read-only image (UDZO) of `folder`'s contents.
    static func create(from folder: URL, volumeName: String, to output: URL, progress: @escaping ProgressHandler) async throws {
        let name = volumeName.isEmpty ? "Archive" : String(volumeName.prefix(27))
        progress(0.1)
        do {
            try await ArchiveProcess.run(hdiutil, ["create", "-srcfolder", folder.path, "-volname", name, "-format", "UDZO",
                                                   "-ov", "-quiet", output.path])
        } catch let e as ProcessError {
            throw PetalwheelError(l: "Couldn't create %@: %@", "DMG", e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        progress(1)
    }
}
