import Foundation

/// Archive → archive: every readable format (zip, 7z, rar, tar.*, iso, cab, pkg, deb, cpio, lzh, dmg,
/// single-file gz / bz2 / xz / zst) to every writable one (zip, 7z, tar, tar.gz / bz2 / xz / zst, iso, dmg).
/// Extracts to a temporary folder with the usual safety checks, then repacks.
struct ArchiveEngine: ConversionEngine {
    init() {}

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        source.group == .archives && source != target && ArchiveSupport.conversionTargets.contains(target)
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw NurToError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        // Several volumes of one set dropped together: convert the set once.
        let set = try ArchiveVolumeSet.resolve(source)
        guard await ArchiveVolumeClaims.shared.claim(set.key) else { return [] }
        defer { Task { await ArchiveVolumeClaims.shared.release(set.key) } }

        let temp = try OutputNaming.tempDirectory()
        defer { ArchiveSupport.removeTree(temp) }
        let contents = temp.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        progress(0.02)
        try await ArchiveSupport.extract(source, format: from, into: contents) { progress(0.02 + $0 * 0.48) }
        try Task.checkCancellation()
        if try ArchiveSupport.topLevelItems(contents).isEmpty {
            throw NurToError(l: "“%@” is empty.", source.lastPathComponent)
        }

        let base = ArchiveSupport.baseName(of: source)
        let output = ArchiveSupport.outputURL(for: source, format: target)
        let staging = temp.appendingPathComponent("out." + target.fileExtension)
        try await ArchiveSupport.pack(contentsOf: contents, format: target, to: staging, volumeName: base) { progress(0.5 + $0 * 0.49) }
        try FileManager.default.moveItem(at: staging, to: output)
        progress(1)
        return [output]
    }
}
