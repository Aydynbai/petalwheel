import Foundation

enum FormatGroup: String, CaseIterable {
    case images, audio, video, documents, spreadsheets, subtitles, archives

    var title: String {
        switch self {
        case .images: return L("Images")
        case .audio: return L("Audio")
        case .video: return L("Video")
        case .documents: return L("Documents")
        case .spreadsheets: return L("Spreadsheets")
        case .subtitles: return L("Subtitles")
        case .archives: return L("Archives")
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
    // archives
    case zip, tar, tgz

    var id: String { rawValue }

    var group: FormatGroup {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp: return .images
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif: return .video
        case .pdf, .docx, .odt, .rtf, .rtfd, .html, .md, .txt, .epub, .doc, .pptx, .key, .pages: return .documents
        case .xlsx, .csv, .tsv, .xls, .numbers: return .spreadsheets
        case .srt, .vtt: return .subtitles
        case .zip, .tar, .tgz: return .archives
        }
    }

    var title: String {
        switch self {
        case .tgz: return "TAR.GZ"
        case .md: return "Markdown"
        case .key: return "Keynote"
        case .pages: return "Pages"
        case .numbers: return "Numbers"
        default: return rawValue.uppercased()
        }
    }

    var fileExtension: String {
        switch self {
        case .tgz: return "tar.gz"
        default: return rawValue
        }
    }

    /// Formats Kumquat can read but never writes (never offered as a conversion target).
    var isInputOnly: Bool {
        switch self {
        case .doc, .pptx, .key, .pages, .xls, .numbers: return true
        default: return false
        }
    }

    /// Raster formats ImageIO can read directly.
    var isRasterImage: Bool { group == .images && self != .svg }

    private static let aliases: [String: FileFormat] = [
        "jpeg": .jpg, "jpe": .jpg, "jfif": .jpg, "tif": .tiff, "heif": .heic, "hif": .heic,
        "aif": .aiff, "aifc": .aiff, "oga": .ogg, "m4v": .mp4, "htm": .html, "xhtml": .html,
        "markdown": .md, "mdown": .md, "text": .txt, "gz": .tgz, "tgz": .tgz, "dib": .bmp,
        "ppsx": .pptx, "dot": .doc, "xlt": .xls,
    ]

    static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return .tgz }
        let ext = url.pathExtension.lowercased()
        return FileFormat(rawValue: ext) ?? aliases[ext]
    }
}
