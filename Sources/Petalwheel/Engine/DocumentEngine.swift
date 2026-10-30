import AppKit
import PDFKit

/// Text documents: docx odt rtf rtfd html md txt pdf.
/// Doc ↔ doc conversions run through /usr/bin/textutil (out of process: robust against odd HTML,
/// never blocks the UI on remote resources). Markdown is converted to/from HTML/attributed text by
/// our own converters. PDF output is paginated A4 with TextKit; PDF input is read with PDFKit.
struct DocumentEngine: ConversionEngine {
    static let editableSources: Set<FileFormat> = [.docx, .odt, .rtf, .rtfd, .html, .md, .txt]
    static let documentTargets: Set<FileFormat> = [.pdf, .docx, .odt, .rtf, .rtfd, .html, .md, .txt]
    static let pdfTargets: Set<FileFormat> = [.txt, .rtf, .docx, .html, .md]

    static let pageSize = CGSize(width: 595.276, height: 841.89)   // A4
    static let pageMargin: CGFloat = 54

    private static let textutil = URL(fileURLWithPath: "/usr/bin/textutil")

    init() {}

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        if source == .pdf { return Self.pdfTargets.contains(target) }
        return Self.editableSources.contains(source) && Self.documentTargets.contains(target)
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw NurToError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        let output = OutputNaming.url(for: source, ext: target.fileExtension)
        let temp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        progress(0.05)

        if from == .pdf {
            return try await convertPDF(source, to: target, output: output, progress: progress)
        }

        // Normalize the input into something textutil understands.
        var input = source
        var inputFormat = from
        switch from {
        case .txt:
            let text = try DocumentTextDecoder.decode(contentsOf: source)
            if target == .md || target == .txt {
                try text.write(to: output, atomically: true, encoding: .utf8)
                progress(1)
                return [output]
            }
            input = temp.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".txt")
            try text.write(to: input, atomically: true, encoding: .utf8)
        case .md:
            let markdown = try DocumentTextDecoder.decode(contentsOf: source)
            let title = source.deletingPathExtension().lastPathComponent
            if target == .md {
                try markdown.write(to: output, atomically: true, encoding: .utf8)
                progress(1)
                return [output]
            }
            if target == .html {
                try MarkdownToHTML.document(markdown: markdown, title: title).write(to: output, atomically: true, encoding: .utf8)
                progress(1)
                return [output]
            }
            let dir = source.deletingLastPathComponent()
            let html = MarkdownToHTML.document(markdown: markdown, title: title, baseURL: dir, forImport: true)
            input = temp.appendingPathComponent(title + ".html")
            try html.write(to: input, atomically: true, encoding: .utf8)
            inputFormat = .html
        default:
            break
        }
        progress(0.2)

        let baseURL = source.deletingLastPathComponent()
        switch target {
        case .pdf:
            let rtf = try await prepareRTF(input, format: inputFormat, temp: temp, baseURL: baseURL)
            progress(0.5)
            let title = source.deletingPathExtension().lastPathComponent
            try await MainActor.run {
                let attributed = try Self.readAttributed(rtf, displayName: source.lastPathComponent)
                try Self.renderPDF(attributed, to: output, title: title) { p in progress(0.5 + 0.5 * p) }
            }
        case .md:
            let rtf = try await prepareRTF(input, format: inputFormat, temp: temp, baseURL: baseURL)
            progress(0.6)
            let result = try await MainActor.run {
                try Self.writeMarkdown(Self.readAttributed(rtf, displayName: source.lastPathComponent), to: output)
            }
            progress(1)
            return result
        case .html:
            try await runTextutil(input: input, format: inputFormat, target: target, output: output, baseURL: baseURL)
            try await embedHTMLImages(output, input: input, format: inputFormat, temp: temp, baseURL: baseURL)
        default:
            try await runTextutil(input: input, format: inputFormat, target: target, output: output, baseURL: baseURL)
        }
        progress(1)
        return [output]
    }

    // MARK: - textutil

    private func runTextutil(input: URL, format: FileFormat, target: FileFormat, output: URL, baseURL: URL?) async throws {
        var args = ["-convert", target.rawValue]
        var source = input
        var strippedDir: URL?
        defer { if let strippedDir { try? FileManager.default.removeItem(at: strippedDir) } }
        if format == .txt { args += ["-inputencoding", "UTF-8"] }
        if target == .txt || target == .html { args += ["-encoding", "UTF-8"] }
        if format == .html {
            // Never touch the network: remote images, stylesheets and fonts are removed first.
            // Local images still resolve against the base URL.
            let dir = try OutputNaming.tempDirectory()
            strippedDir = dir
            source = HTMLRemoteStripper.strippedCopy(of: input, in: dir)
            args += ["-timeout", "8"]
            if let baseURL { args += ["-baseurl", baseURL.absoluteString] }
        }
        args += ["-output", output.path, source.path]
        do {
            try await ProcessRunner.run(Self.textutil, args)
        } catch let e as ProcessError {
            throw NurToError(l: "Couldn't convert “%@” to %@: %@", input.lastPathComponent, target.title, e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw NurToError(l: "textutil produced no output for “%@”.", input.lastPathComponent)
        }
    }

    /// Returns an RTF/RTFD version of any editable document. Everything except RTF/RTFD goes
    /// through textutil, which keeps HTML (WebKit) import out of our process.
    private func prepareRTF(_ url: URL, format: FileFormat, temp: URL, baseURL: URL) async throws -> URL {
        if format == .rtf || format == .rtfd { return url }
        let rtfURL = temp.appendingPathComponent("intermediate-\(UUID().uuidString).rtfd")
        try await runTextutil(input: url, format: format, target: .rtfd, output: rtfURL, baseURL: baseURL)
        return rtfURL
    }

    @MainActor
    static func readAttributed(_ url: URL, displayName: String) throws -> NSAttributedString {
        do {
            // macOS 15+ omits list markers from the text unless asked; TextKit 1 needs them inline.
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if #available(macOS 15.0, *) { options[NSAttributedString.DocumentReadingOptionKey.textKit1ListMarkerFormatDocumentOption] = true }
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch {
            throw NurToError(l: "Couldn't read “%@”: %@", displayName, error.localizedDescription)
        }
    }

    /// textutil's HTML writer references images as `file:///name` without saving them. Replace those
    /// references with data: URIs so the HTML is self-contained.
    private func embedHTMLImages(_ html: URL, input: URL, format: FileFormat, temp: URL, baseURL: URL) async throws {
        guard var text = try? String(contentsOf: html, encoding: .utf8), text.contains("src=\"file:///") else { return }
        let rtf = try await prepareRTF(input, format: format, temp: temp, baseURL: baseURL)
        let images: [String: Data] = try await MainActor.run {
            let attributed = try Self.readAttributed(rtf, displayName: input.lastPathComponent)
            var images: [String: Data] = [:]
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                guard let att = value as? NSTextAttachment, let w = att.fileWrapper,
                      let name = w.preferredFilename ?? w.filename, let data = w.regularFileContents else { return }
                images[name] = data
            }
            return images
        }
        for (name, data) in images {
            let mime: String
            switch (name as NSString).pathExtension.lowercased() {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "tif", "tiff": mime = "image/tiff"
            case "heic": mime = "image/heic"
            case "pdf": mime = "application/pdf"
            default: mime = "image/png"
            }
            let escapedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            for ref in ["file:///\(name)", "file:///\(escapedName)"] {
                text = text.replacingOccurrences(of: "src=\"\(ref)\"", with: "src=\"data:\(mime);base64,\(data.base64EncodedString())\"")
            }
        }
        try text.write(to: html, atomically: true, encoding: .utf8)
    }

    // MARK: - Markdown output

    /// Writes Markdown; embedded images are saved into a "<name> images" folder next to it.
    @MainActor
    static func writeMarkdown(_ attributed: NSAttributedString, to output: URL) throws -> [URL] {
        let base = output.deletingPathExtension().lastPathComponent
        let imageDir = OutputNaming.unique(output.deletingLastPathComponent().appendingPathComponent("\(base) images"))
        var names: [ObjectIdentifier: String] = [:]
        var used = Set<String>()
        var wroteImages = false
        var writeError: Error?
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let att = value as? NSTextAttachment else { return }
            var data = att.fileWrapper?.regularFileContents ?? att.contents
            var name = att.fileWrapper?.preferredFilename ?? att.fileWrapper?.filename
            if data == nil, let image = att.image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                data = rep.representation(using: .png, properties: [:]); name = nil
            }
            guard let data else { return }
            let original = (name?.isEmpty == false ? name! : "image\(names.count + 1).png")
            var unique = original
            var n = 2
            while used.contains(unique.lowercased()) {
                unique = "\((original as NSString).deletingPathExtension) \(n).\((original as NSString).pathExtension)"; n += 1
            }
            used.insert(unique.lowercased())
            do {
                if !wroteImages { try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true) }
                try data.write(to: imageDir.appendingPathComponent(unique))
                wroteImages = true
                names[ObjectIdentifier(att)] = imageDir.lastPathComponent + "/" + unique
            } catch { writeError = error }
        }
        if let writeError { throw writeError }
        var writer = MarkdownFromAttributed(attributed)
        writer.imageNamer = { att, _ in names[ObjectIdentifier(att)] }
        try writer.render().write(to: output, atomically: true, encoding: .utf8)
        return wroteImages ? [output, imageDir] : [output]
    }

    // MARK: - PDF input

    private func convertPDF(_ source: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard let doc = PDFDocument(url: source) else { throw NurToError(l: "Couldn't open “%@” as a PDF.", source.lastPathComponent) }
        if doc.isLocked { throw NurToError(l: "“%@” is password-protected.", source.lastPathComponent) }
        let count = doc.pageCount
        guard count > 0 else { throw NurToError(l: "“%@” has no pages.", source.lastPathComponent) }

        if target == .txt {
            var pages: [String] = []
            for i in 0..<count {
                try Task.checkCancellation()
                pages.append(doc.page(at: i)?.string ?? "")
                progress(0.1 + 0.8 * Double(i + 1) / Double(count))
            }
            let text = pages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.noTextLayer(source) }
            try (text + "\n").write(to: output, atomically: true, encoding: .utf8)
            progress(1)
            return [output]
        }

        let result: [URL] = try await MainActor.run {
            // Re-open on the main actor so no PDFKit object crosses actors.
            guard let doc = PDFDocument(url: source) else { throw NurToError(l: "Couldn't open “%@”.", source.lastPathComponent) }
            let combined = NSMutableAttributedString()
            for i in 0..<count {
                guard let page = doc.page(at: i), let s = page.attributedString else { continue }
                if combined.length > 0 {
                    // Page break: becomes \page in RTF / a page break in DOCX.
                    combined.append(NSAttributedString(string: "\u{0C}"))
                }
                combined.append(Self.reflow(s))
                progress(0.1 + 0.7 * Double(i + 1) / Double(count))
            }
            guard !combined.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.noTextLayer(source) }
            if target == .md { return try Self.writeMarkdown(combined, to: output) }
            let type: NSAttributedString.DocumentType
            switch target {
            case .rtf: type = .rtf
            case .docx: type = .officeOpenXML
            case .html: type = .html
            default: type = .plain
            }
            var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
            else { attrs[.paperSize] = Self.pageSize }
            let data = try combined.data(from: NSRange(location: 0, length: combined.length), documentAttributes: attrs)
            try data.write(to: output)
            return [output]
        }
        progress(1)
        return result
    }

    static func noTextLayer(_ url: URL) -> NurToError {
        NurToError(l: "“%@” has no text layer (it looks like a scanned document). Use the “Extract Text” tool to recognize its text with OCR.", url.lastPathComponent)
    }

    /// PDFKit returns one paragraph per visual line. Join lines that clearly continue a sentence
    /// (next line starts lower-case, or the line ends with a hyphenated word / comma).
    static func reflow(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        let ns = m.string as NSString
        var replacements: [(NSRange, String)] = []
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x0A, i > 0, i + 1 < ns.length {
                let prev = ns.character(at: i - 1)
                let next = ns.character(at: i + 1)
                let nextIsLower = (Character(UnicodeScalar(next) ?? " ")).isLowercase
                let prevChar = Character(UnicodeScalar(prev) ?? " ")
                // Only join lines set in the same kind of type (not headings into body, not code).
                let f1 = m.attribute(.font, at: i - 1, effectiveRange: nil) as? NSFont
                let f2 = m.attribute(.font, at: i + 1, effectiveRange: nil) as? NSFont
                let sameStyle = f1 != nil && f2 != nil && abs(f1!.pointSize - f2!.pointSize) < 0.6
                    && !MarkdownFromAttributed.isMono(f1!) && !MarkdownFromAttributed.isMono(f2!)
                if !sameStyle {
                    // keep the line break
                } else if prevChar == "-" && i >= 2 && Character(UnicodeScalar(ns.character(at: i - 2)) ?? " ").isLetter && nextIsLower {
                    replacements.append((NSRange(location: i - 1, length: 2), ""))
                } else if prevChar != "\n" && (nextIsLower || prevChar == ",") && !prevChar.isWhitespace {
                    replacements.append((NSRange(location: i, length: 1), " "))
                }
            }
            i += 1
        }
        for (r, s) in replacements.reversed() { m.replaceCharacters(in: r, with: s) }
        return m
    }

    // MARK: - PDF output

    /// Paginates an attributed string into an A4 PDF (54 pt margins) using TextKit 1.
    @MainActor
    static func renderPDF(_ attributed: NSAttributedString, to url: URL, title: String,
                          progress: (Double) -> Void) throws {
        let contentSize = CGSize(width: pageSize.width - 2 * pageMargin, height: pageSize.height - 2 * pageMargin)
        let storage = NSTextStorage(attributedString: attributed)
        fitAttachments(in: storage, maxSize: CGSize(width: contentSize.width, height: contentSize.height * 0.95))
        punctuateOrderedMarkers(in: storage)
        if storage.length == 0 { storage.append(NSAttributedString(string: " ")) }

        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        var emptyStreak = 0
        while true {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if range.length == 0 { emptyStreak += 1 } else { emptyStreak = 0 }
            if NSMaxRange(range) >= layout.numberOfGlyphs || emptyStreak > 3 || containers.count > 10_000 { break }
        }
        // Drop trailing empty pages.
        while containers.count > 1, layout.glyphRange(for: containers.last!).length == 0 {
            layout.removeTextContainer(at: containers.count - 1)
            containers.removeLast()
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "NurTo"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw NurToError(l: "Couldn't create “%@”.", url.lastPathComponent)
        }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        for (index, container) in containers.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.current = gc
            let range = layout.glyphRange(for: container)
            let origin = CGPoint(x: pageMargin, y: pageMargin)
            if range.length > 0 {
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
            }
            gc.flushGraphics()
            ctx.restoreGState()
            ctx.endPDFPage()
            progress(Double(index + 1) / Double(containers.count))
        }
        ctx.closePDF()
    }

    /// HTML import yields ordered-list markers like "\t1\t"; print them as "1." like a browser does.
    @MainActor
    private static func punctuateOrderedMarkers(in storage: NSTextStorage) {
        let ns = storage.string as NSString
        var inserts: [Int] = []
        var location = 0
        while location < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(pr)
            guard let style = storage.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle,
                  let list = style.textLists.last, MarkdownFromAttributed.isOrdered(list) else { continue }
            let format = list.markerFormat.rawValue
            // Only formats that are just a placeholder ("{decimal}") lack punctuation.
            guard format.hasPrefix("{"), format.hasSuffix("}") else { continue }
            let text = ns.substring(with: pr)
            if let m = MarkdownToHTML.match(#"^\t?([0-9A-Za-z]{1,8})\t"#, text) {
                let markerRange = (text as NSString).range(of: m[1])
                inserts.append(pr.location + NSMaxRange(markerRange))
            }
        }
        for index in inserts.reversed() {
            let attrs = storage.attributes(at: max(0, index - 1), effectiveRange: nil)
            storage.insert(NSAttributedString(string: ".", attributes: attrs), at: index)
        }
    }

    /// Scales down images that don't fit on a page (they would otherwise stall pagination).
    @MainActor
    private static func fitAttachments(in storage: NSTextStorage, maxSize: CGSize) {
        var fixes: [(NSRange, NSTextAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let att = value as? NSTextAttachment else { return }
            var size = att.bounds.size
            var image = att.image
            if image == nil, let data = att.fileWrapper?.regularFileContents ?? att.contents { image = NSImage(data: data) }
            if size == .zero, let cell = att.attachmentCell { size = cell.cellSize() }
            if size == .zero, let image { size = image.size }
            guard let image, size.width > 0, size.height > 0,
                  size.width > maxSize.width || size.height > maxSize.height else { return }
            let scale = min(maxSize.width / size.width, maxSize.height / size.height)
            let replacement = NSTextAttachment()
            replacement.image = image
            replacement.bounds = CGRect(x: 0, y: 0, width: floor(size.width * scale), height: floor(size.height * scale))
            fixes.append((range, replacement))
        }
        for (range, att) in fixes { storage.addAttribute(.attachment, value: att, range: range) }
    }
}
