import Foundation

enum FormatGroup: String, CaseIterable {
    case images, audio, video, documents, spreadsheets, subtitles, archives
    case data   // New formats: JSON / YAML / XML / plist

    var title: String {
        switch self {
        case .images: return L("Images")
        case .audio: return L("Audio")
        case .video: return L("Video")
        case .documents: return L("Documents")
        case .spreadsheets: return L("Spreadsheets")
        case .subtitles: return L("Subtitles")
        case .archives: return L("Archives")
        case .data: return L("Data")   // New formats
        }
    }
}

enum FileFormat: String, CaseIterable, Identifiable {
    // images
    case jpg, png, webp, heic, tiff, svg, avif, bmp
    // audio
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    // video
    case mp4, mov, mkv, webm, avi, wmv, gif
    // documents
    case pdf, docx, odt, rtf, rtfd, html, md, txt, epub
    // input-only documents (rendered through Quick Look / textutil)
    case doc, pptx, key, pages
    // spreadsheets
    case xlsx, csv, tsv
    // input-only spreadsheets
    case xls, numbers
    // subtitles
    case srt, vtt
    // archives (writable: zip, 7z, tar, tar.gz/bz2/xz/zst, iso, dmg)
    case zip, tar, tgz, sevenZ = "7z", tbz2, txz, tzst, iso, dmg
    // input-only archives (RAR is read-only: creating RAR is license-restricted)
    case rar, cab, pkg, deb, cpio, lzh
    // single-file compressors (written by the compressSingle tool, not as conversion targets)
    case gz, bz2, xz, zst
    // --- New formats (images, documents, data, subtitles) ---
    // input-only images: camera RAW (Core Image), JPEG XL and Photoshop (ImageIO)
    case dng, cr2, cr3, nef, arw, raf, orf, rw2, jxl, psd
    // icons, read and written
    case ico, icns
    // FictionBook 2 (also .fb2.zip)
    case fb2
    // structured data
    case json, yaml, xml, plist
    // styled subtitles
    case ass, ssa

    var id: String { rawValue }

    var group: FormatGroup {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp: return .images
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif: return .video
        case .pdf, .docx, .odt, .rtf, .rtfd, .html, .md, .txt, .epub, .doc, .pptx, .key, .pages: return .documents
        case .xlsx, .csv, .tsv, .xls, .numbers: return .spreadsheets
        case .srt, .vtt: return .subtitles
        case .zip, .tar, .tgz, .sevenZ, .tbz2, .txz, .tzst, .iso, .dmg,
             .rar, .cab, .pkg, .deb, .cpio, .lzh, .gz, .bz2, .xz, .zst: return .archives
        // New formats
        case .dng, .cr2, .cr3, .nef, .arw, .raf, .orf, .rw2, .jxl, .psd, .ico, .icns: return .images
        case .fb2: return .documents
        case .json, .yaml, .xml, .plist: return .data
        case .ass, .ssa: return .subtitles
        }
    }

    var title: String {
        switch self {
        case .tgz: return "TAR.GZ"
        case .tbz2, .txz, .tzst: return fileExtension.uppercased()
        case .md: return "Markdown"
        case .key: return "Keynote"
        case .pages: return "Pages"
        case .numbers: return "Numbers"
        case .jxl: return "JPEG XL"   // New formats
        default: return rawValue.uppercased()
        }
    }

    var fileExtension: String {
        switch self {
        case .tgz: return "tar.gz"
        case .tbz2: return "tar.bz2"
        case .txz: return "tar.xz"
        case .tzst: return "tar.zst"
        default: return rawValue
        }
    }

    /// Formats NurTo can read but never writes (never offered as a conversion target).
    var isInputOnly: Bool {
        switch self {
        case .doc, .pptx, .key, .pages, .xls, .numbers: return true
        case .rar, .cab, .pkg, .deb, .cpio, .lzh, .gz, .bz2, .xz, .zst: return true
        case .dng, .cr2, .cr3, .nef, .arw, .raf, .orf, .rw2, .jxl, .psd: return true   // New formats
        default: return false
        }
    }

    /// Raster formats ImageIO can read directly.
    /// (The new input-only and icon formats are converted only, never edited in place.)
    var isRasterImage: Bool { group == .images && self != .svg && !isConvertOnlyImage }

    private static let aliases: [String: FileFormat] = [
        "jpeg": .jpg, "jpe": .jpg, "jfif": .jpg, "tif": .tiff, "heif": .heic, "hif": .heic,
        "aif": .aiff, "aifc": .aiff, "oga": .ogg, "m4v": .mp4, "htm": .html, "xhtml": .html,
        "markdown": .md, "mdown": .md, "text": .txt, "tgz": .tgz, "dib": .bmp,
        "ppsx": .pptx, "dot": .doc, "xlt": .xls,
    ]

    static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return .tgz }
        if let f = detectNewFormat(name) { return f }   // New formats (.fb2.zip, .yml)
        if let archive = detectArchive(name) { return archive }
        let ext = url.pathExtension.lowercased()
        return FileFormat(rawValue: ext) ?? aliases[ext]
    }
}

// MARK: - Archives

extension FileFormat {
    private static let archiveAliases: [String: FileFormat] = [
        "tbz": .tbz2, "tb2": .tbz2, "bzip2": .bz2, "zstd": .zst, "xar": .pkg, "mpkg": .pkg,
        "lha": .lzh, "udf": .iso,
    ]

    /// Two-part tar extensions and multi-volume names (`.part2.rar`, `.r00`, `.z01`, `.7z.001`).
    static func detectArchive(_ name: String) -> FileFormat? {
        let compound: [(String, FileFormat)] = [
            (".tar.bz2", .tbz2), (".tar.bz", .tbz2), (".tar.xz", .txz), (".tar.zst", .tzst), (".tar.zstd", .tzst),
            // Rarer tar compressions: bsdtar detects them on read, so they behave like a plain tar.
            (".tar.lz4", .tar), (".tar.lzma", .tar), (".tar.lz", .tar), (".tlz", .tar), (".tar.z", .tar),
        ]
        for (suffix, format) in compound where name.hasSuffix(suffix) { return format }
        let ext = (name as NSString).pathExtension
        if let f = archiveAliases[ext] { return f }
        // Old-style RAR volumes (.r00…) and split zips (.z01…).
        if ext.count == 3, ext.dropFirst().allSatisfy(\.isNumber) {
            if ext.hasPrefix("r") { return .rar }
            if ext.hasPrefix("z") { return .zip }
        }
        // Byte-split volumes: archive.7z.001, archive.zip.001.
        if ext.count == 3, ext.allSatisfy(\.isNumber) {
            let inner = ((name as NSString).deletingPathExtension as NSString).pathExtension
            if inner == "7z" { return .sevenZ }
            if inner == "zip" { return .zip }
        }
        return nil
    }
}

// MARK: - New formats (images, documents, data, subtitles)

extension FileFormat {
    /// Camera RAW formats decoded with Core Image's RAW filter.
    var isCameraRaw: Bool { [.dng, .cr2, .cr3, .nef, .arw, .raf, .orf, .rw2].contains(self) }

    /// Images that are converted to other formats but never re-encoded in place by the image tools.
    var isConvertOnlyImage: Bool { isCameraRaw || [.jxl, .psd, .ico, .icns].contains(self) }

    static func detectNewFormat(_ name: String) -> FileFormat? {
        if name.hasSuffix(".fb2.zip") { return .fb2 }
        switch (name as NSString).pathExtension {
        case "yml": return .yaml
        case "fbz": return .fb2
        default: return nil
        }
    }
}
