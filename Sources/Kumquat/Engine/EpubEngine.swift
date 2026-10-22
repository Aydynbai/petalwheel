import AppKit

/// EPUB in and out.
/// - epub → pdf: chapters (spine order) combined into one HTML and printed by WebKit (paginated A4).
/// - epub → html: the same combined HTML, self-contained (images as data: URIs).
/// - epub → docx / odt / rtf / md / txt: combined HTML through DocumentEngine (textutil).
/// - docx / odt / rtf / rtfd / html / md / txt / doc → epub: EPUB 3, one chapter per top-level heading.
struct EpubEngine: ConversionEngine {
    static let readTargets: Set<FileFormat> = [.pdf, .html, .docx, .odt, .rtf, .md, .txt]
    static let writeSources: Set<FileFormat> = [.docx, .odt, .rtf, .rtfd, .html, .md, .txt, .doc]

    init() {}

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        if source == .epub { return Self.readTargets.contains(target) }
        return target == .epub && Self.writeSources.contains(source)
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw KumquatError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        let temp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        progress(0.02)
        if target == .epub {
            return try await writeEpub(source, from: from, temp: temp, progress: progress)
        }

        let book = try await EpubReader.open(source, unpackInto: temp)
        let fallbackTitle = source.deletingPathExtension().lastPathComponent
        progress(0.2)
        switch target {
        case .html:
            let out = OutputNaming.url(for: source, ext: "html")
            try EpubReader.combinedHTML(book, mode: .embedded, fallbackTitle: fallbackTitle)
                .write(to: out, atomically: true, encoding: .utf8)
            progress(1)
            return [out]
        case .pdf:
            let combined = book.root.appendingPathComponent("kumquat-\(UUID().uuidString).html")
            try EpubReader.combinedHTML(book, mode: .fileURLs, fallbackTitle: fallbackTitle)
                .write(to: combined, atomically: true, encoding: .utf8)
            let out = OutputNaming.url(for: source, ext: "pdf")
            do {
                try await Self.printBook(combined, root: book.root, to: out)
            } catch {
                try? FileManager.default.removeItem(at: out)
                throw error
            }
            progress(1)
            return [out]
        default:
            let combined = temp.appendingPathComponent("combined.html")
            try EpubReader.combinedHTML(book, mode: .fileURLs, fallbackTitle: fallbackTitle)
                .write(to: combined, atomically: true, encoding: .utf8)
            progress(0.35)
            return try await OfficeSupport.convertIntermediate(combined, format: .html, to: target, original: source,
                                                               temp: temp, options: options) { p in progress(0.35 + 0.65 * p) }
        }
    }

    @MainActor
    private static func printBook(_ html: URL, root: URL, to output: URL) async throws {
        let page = DocumentEngine.pageSize
        let margin: CGFloat = 54
        let renderer = OfficeWebRenderer(width: page.width - 2 * margin)
        try await renderer.load(html, readAccess: root)
        let size = try await renderer.contentSize()
        try await renderer.resize(to: CGSize(width: page.width - 2 * margin, height: max(size.height, 100)))
        try await renderer.printPDF(to: output, paperSize: page, margin: margin)
    }

    // MARK: - Writing

    private func writeEpub(_ source: URL, from: FileFormat, temp: URL, progress: @escaping ProgressHandler) async throws -> [URL] {
        let title = source.deletingPathExtension().lastPathComponent
        let dir = source.deletingLastPathComponent()
        let html: String
        var baseURL: URL? = dir
        switch from {
        case .md:
            let markdown = try DocumentTextDecoder.decode(contentsOf: source)
            html = MarkdownToHTML.document(markdown: markdown, title: title)
        case .html:
            html = try DocumentTextDecoder.decode(contentsOf: source)
        default:
            // DocumentEngine's HTML output embeds the document's pictures as data: URIs.
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
            let produced = try await DocumentEngine().convert(copy, from: format, to: .html, options: ConversionOptions()) { p in progress(0.05 + 0.4 * p) }
            guard let out = produced.first else { throw KumquatError(l: "Couldn't read “%@”.", source.lastPathComponent) }
            html = try DocumentTextDecoder.decode(contentsOf: out)
            baseURL = nil
        }
        progress(0.5)
        let output = OutputNaming.url(for: source, ext: "epub")
        try await EpubWriter.write(html: html, baseURL: baseURL, title: title, language: nil, to: output, temp: temp)
        progress(1)
        return [output]
    }
}
