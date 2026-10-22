import Foundation

/// zip ↔ tar ↔ tar.gz: extract to a temporary folder (with zip-slip checks), then repack.
struct ArchiveEngine: ConversionEngine {
    static let formats: Set<FileFormat> = [.zip, .tar, .tgz]

    init() {}

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        Self.formats.contains(source) && Self.formats.contains(target)
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw KumquatError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        let temp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let contents = temp.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        progress(0.05)
        try await ArchiveSupport.extract(source, format: from, into: contents)
        progress(0.5)
        try Task.checkCancellation()

        let output = ArchiveSupport.outputURL(for: source, format: target)
        let staging = temp.appendingPathComponent("out." + target.fileExtension)
        do {
            try await ArchiveSupport.pack(contentsOf: contents, format: target, to: staging)
        } catch let e as ProcessError {
            throw KumquatError(l: "Couldn't create %@: %@", target.title, e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try FileManager.default.moveItem(at: staging, to: output)
        progress(1)
        return [output]
    }
}
