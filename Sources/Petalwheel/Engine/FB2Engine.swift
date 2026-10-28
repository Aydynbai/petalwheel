import AppKit

/// FictionBook 2 in and out.
/// - fb2 (and .fb2.zip) → epub: EPUB 3 via EpubWriter, one chapter per top-level section (plus the title
///   page and a Notes chapter when the book has notes).
/// - fb2 → html: self-contained HTML (pictures as data: URIs).
/// - fb2 → pdf: the HTML printed by WebKit (paginated A4), like EPUB → PDF.
/// - fb2 → docx / odt / rtf / md / txt: the HTML through DocumentEngine (textutil).
/// - epub / docx / odt / rtf / rtfd / html / md / txt / doc → fb2: HTML → FB2Writer.
struct FB2Engine: ConversionEngine {
    static let readTargets: Set<FileFormat> = [.epub, .pdf, .docx, .odt, .rtf, .html, .md, .txt]
    static let writeSources: Set<FileFormat> = [.epub, .docx, .odt, .rtf, .rtfd, .html, .md, .txt, .doc]

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        if source == .fb2 { return Self.readTargets.contains(target) }
        return target == .fb2 && Self.writeSources.contains(source)
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw PetalwheelError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        let temp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        progress(0.02)
        if target == .fb2 { return try await writeFB2(source, from: from, temp: temp, progress: progress) }

        // "book.fb2.zip" is named like "book.fb2" so outputs become "book.epub", not "book.fb2.epub".
        let naming = source.deletingLastPathComponent().appendingPathComponent(FB2Reader.fileBaseName(source) + ".fb2")
        let out = OutputNaming.url(for: naming, ext: target.fileExtension)
        do {
            switch target {
            case .html:
                let book = try await FB2Reader.read(source, temp: temp, images: .embedded)
                try book.html.write(to: out, atomically: true, encoding: .utf8)
            case .epub:
                let book = try await FB2Reader.read(source, temp: temp, images: .embedded)
                progress(0.4)
                try await EpubWriter.write(html: book.html, baseURL: nil, title: book.title, language: book.language,
                                           to: out, temp: temp)
            case .pdf:
                let dir = temp.appendingPathComponent("book", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let book = try await FB2Reader.read(source, temp: temp, images: .files(dir))
                let html = dir.appendingPathComponent("book.html")
                try book.html.write(to: html, atomically: true, encoding: .utf8)
                progress(0.3)
                try await Self.printHTML(html, readAccess: dir, to: out)
            default:
                let dir = temp.appendingPathComponent("book", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let book = try await FB2Reader.read(source, temp: temp, images: .files(dir))
                let html = dir.appendingPathComponent("book.html")
                try book.html.write(to: html, atomically: true, encoding: .utf8)
                progress(0.3)
                return try await OfficeSupport.convertIntermediate(html, format: .html, to: target, original: naming,
                                                                   temp: temp, options: options) { p in progress(0.3 + 0.7 * p) }
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress(1)
        return [out]
    }

    @MainActor
    private static func printHTML(_ html: URL, readAccess: URL, to output: URL) async throws {
        let page = DocumentEngine.pageSize
        let margin: CGFloat = 54
        let renderer = OfficeWebRenderer(width: page.width - 2 * margin)
        try await renderer.load(html, readAccess: readAccess)
        let size = try await renderer.contentSize()
        try await renderer.resize(to: CGSize(width: page.width - 2 * margin, height: max(size.height, 100)))
        try await renderer.printPDF(to: output, paperSize: page, margin: margin)
    }

    // MARK: - Writing FB2

    private func writeFB2(_ source: URL, from: FileFormat, temp: URL, progress: @escaping ProgressHandler) async throws -> [URL] {
        let title = source.deletingPathExtension().lastPathComponent
        var meta = FB2Writer.Metadata(title: title)
        let html: String
        var baseURL: URL? = source.deletingLastPathComponent()
        switch from {
        case .epub:
            let book = try await EpubReader.open(source, unpackInto: temp)
            meta.title = book.title ?? title
            meta.authors = book.author.map { [$0] } ?? []
            meta.language = book.language
            html = EpubReader.combinedHTML(book, mode: .fileURLs, fallbackTitle: title)
            baseURL = book.root
        case .md:
            let markdown = try DocumentTextDecoder.decode(contentsOf: source)
            html = MarkdownToHTML.document(markdown: markdown, title: title)
        case .html:
            html = try DocumentTextDecoder.decode(contentsOf: source)
        case .txt:
            // One paragraph per line; blank lines separate nothing extra.
            let text = try DocumentTextDecoder.decode(contentsOf: source)
            let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { "<p>\(MarkdownToHTML.escapeHTML($0))</p>" }
            html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(MarkdownToHTML.escapeHTML(title))</title></head><body>\n"
                + paragraphs.joined(separator: "\n") + "\n</body></html>"
        default:
            // Word / OpenDocument / RTF: DocumentEngine's HTML embeds the pictures as data: URIs.
            var input = source
            var format = from
            if from == .doc {
                input = try await OfficeEngine.wordDocToRTFD(source, temp: temp)
                format = .rtfd
            }
            let work = temp.appendingPathComponent("html-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let copy = work.appendingPathComponent(title).appendingPathExtension(input.pathExtension)
            try FileManager.default.copyItem(at: input, to: copy)
            let produced = try await DocumentEngine().convert(copy, from: format, to: .html, options: ConversionOptions()) { p in
                progress(0.05 + 0.4 * p)
            }
            guard let out = produced.first else { throw PetalwheelError(l: "Couldn't read “%@”.", source.lastPathComponent) }
            html = try DocumentTextDecoder.decode(contentsOf: out)
            baseURL = work
        }
        progress(0.5)
        let output = OutputNaming.url(for: source, ext: "fb2")
        do {
            try FB2Writer.write(html: html, baseURL: baseURL, metadata: meta, to: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
        return [output]
    }
}
