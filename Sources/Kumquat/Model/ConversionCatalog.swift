import Foundation

/// Which formats a given source can be converted into, taking installed helpers into account.
enum ConversionCatalog {
    static func outputs(from source: FileFormat) -> [FileFormat] {
        let tools = ExternalTools.shared
        var result: [FileFormat]
        switch source.group {
        case .images:
            result = [.jpg, .png, .heic, .webp, .avif, .tiff, .bmp, .gif, .pdf]
            if !tools.hasWebPEncoder { result.removeAll { $0 == .webp } }
        case .audio:
            result = tools.hasFFmpeg ? [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma] : [.m4a, .wav, .aiff]
        case .video:
            if tools.hasFFmpeg {
                result = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3, .m4a, .wav]
                if source == .gif { result = [.mp4, .mov, .webm, .png, .jpg] }
            } else {
                result = [.mp4, .mov, .m4a]
            }
        case .documents:
            switch source {
            case .pdf: result = [.png, .jpg, .txt, .rtf, .docx, .html, .md]
            case .epub: result = [.pdf, .docx, .odt, .rtf, .html, .md, .txt]
            // Presentations: rendered through Quick Look; images are one file per slide.
            case .pptx, .key: result = [.pdf, .png, .jpg]
            // Pages renders to PDF; text formats are extracted from that PDF.
            case .pages: result = [.pdf, .docx, .rtf, .html, .md, .txt]
            default: result = [.pdf, .docx, .odt, .rtf, .rtfd, .html, .md, .txt, .epub]
            }
        case .spreadsheets:
            switch source {
            case .xls: result = [.xlsx, .csv, .tsv, .html, .pdf]
            case .numbers: result = [.pdf]
            default: result = [.xlsx, .csv, .tsv, .html]
            }
        case .subtitles:
            result = [.srt, .vtt, .txt]
        case .archives:
            result = [.zip, .tar, .tgz]
        }
        result.removeAll { $0 == source || $0.isInputOnly }
        return result
    }

    /// Targets valid for every file in the selection, preserving the order of the first file's list.
    static func commonOutputs(for urls: [URL]) -> [FileFormat] {
        let formats = urls.map(FileFormat.detect)
        guard let first = formats.first, let firstFormat = first else { return [] }
        var common = outputs(from: firstFormat)
        for f in formats.dropFirst() {
            guard let f else { return [] }
            let set = Set(outputs(from: f) + [f])
            common = common.filter { set.contains($0) }
        }
        // A target identical to some (but not all) sources is fine: those files get re-encoded.
        return common
    }
}
