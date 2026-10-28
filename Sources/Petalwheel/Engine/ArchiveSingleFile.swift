import Foundation
import Compression

/// Single-file compressors: `.gz`, `.bz2`, `.xz`, `.zst` (`photo.jpg.gz` ↔ `photo.jpg`).
/// Compression goes through bsdtar's raw writer; decompression uses gzip / bzip2 from macOS, Apple's
/// Compression framework for xz and the zstd tool (Homebrew) for zst.
enum ArchiveSingleFile {
    static let formats: [FileFormat] = [.gz, .bz2, .xz, .zst]

    /// Formats offered by the "Compress File" tool on this Mac.
    static var writableFormats: [FileFormat] {
        ArchiveSupport.zstd == nil ? [.gz, .bz2, .xz] : [.gz, .bz2, .xz, .zst]
    }

    /// `photo.jpg.gz` → `photo.jpg`.
    static func decompressedName(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? "file" : base
    }

    /// Compresses `file` into `output` (which must not exist).
    static func compress(_ file: URL, format: FileFormat, to output: URL) async throws {
        let filter: String
        switch format {
        case .gz: filter = "--gzip"
        case .bz2: filter = "--bzip2"
        case .xz: filter = "--xz"
        case .zst:
            guard ArchiveSupport.zstd != nil else { throw ArchiveSupport.missingTool("zstd") }
            filter = "--zstd"
        default: throw PetalwheelError(l: "%@ isn't an archive format.", format.title)
        }
        let list = try ArchiveSupport.nameList([file.lastPathComponent], near: output)
        defer { try? FileManager.default.removeItem(at: list) }
        do {
            try await ArchiveProcess.run(ArchiveSupport.bsdtar,
                                         ["-c", "--format", "raw", filter, "-f", output.path,
                                          "-C", file.deletingLastPathComponent().path, "--null", "-T", list.path],
                                         environment: ArchiveSupport.environment)
        } catch let e as ProcessError {
            try? FileManager.default.removeItem(at: output)
            throw ArchiveSupport.translate(e, archive: file)
        }
    }

    /// Decompresses `archive` into `destination/<name without the extension>`.
    @discardableResult
    static func decompress(_ archive: URL, format: FileFormat, into destination: URL) async throws -> URL {
        let output = destination.appendingPathComponent(decompressedName(archive))
        try await decompress(archive, format: format, to: output)
        return output
    }

    /// Integrity check: decompresses everything and throws on damage.
    static func test(_ archive: URL, format: FileFormat) async throws {
        try await decompress(archive, format: format, to: nil)
    }

    /// `output` nil = discard (test).
    private static func decompress(_ archive: URL, format: FileFormat, to output: URL?) async throws {
        let fm = FileManager.default
        var handle: FileHandle
        if let output {
            guard fm.createFile(atPath: output.path, contents: nil) else {
                throw PetalwheelError(l: "Couldn't extract “%@”: %@", archive.lastPathComponent, output.path)
            }
            handle = try FileHandle(forWritingTo: output)
        } else {
            handle = FileHandle.nullDevice
        }
        defer { if output != nil { try? handle.close() } }
        do {
            switch format {
            case .gz:
                try await ArchiveProcess.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-dc", "--", archive.path], stdoutTo: handle)
            case .bz2:
                try await ArchiveProcess.run(URL(fileURLWithPath: "/usr/bin/bzip2"), ["-dc", "--", archive.path], stdoutTo: handle)
            case .zst:
                guard let zstd = ArchiveSupport.zstd else { throw ArchiveSupport.missingTool("zstd") }
                try await ArchiveProcess.run(zstd, ["-d", "-c", "-q", "--", archive.path], stdoutTo: handle)
            case .xz:
                try decodeXZ(archive, to: handle)
            default:
                throw PetalwheelError(l: "%@ isn't an archive format.", format.title)
            }
        } catch {
            if let output { try? fm.removeItem(at: output) }
            if let e = error as? ProcessError { throw ArchiveSupport.translate(e, archive: archive) }
            throw error
        }
    }

    /// xz (and legacy .lzma) through Apple's Compression framework, streamed in 1 MB chunks.
    private static func decodeXZ(_ archive: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        var writeError: Error?
        let filter = try OutputFilter(.decompress, using: .lzma) { data in
            guard let data, writeError == nil else { return }
            do { try output.write(contentsOf: data) } catch { writeError = error }
        }
        do {
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                try filter.write(chunk)
                if let writeError { throw writeError }
            }
            try filter.finalize()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let writeError { throw writeError }
            throw PetalwheelError(l: "“%@” is damaged or incomplete.", archive.lastPathComponent)
        }
    }
}
