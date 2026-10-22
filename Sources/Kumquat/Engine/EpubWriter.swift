import Foundation

/// Builds a minimal, valid EPUB 3 (with an EPUB 2 NCX for older readers) from an HTML document:
/// one chapter per top-level `<h1>`, images copied into the book, `mimetype` stored first.
enum EpubWriter {
    struct Chapter { var title: String; var xhtml: String }

    /// - Parameters:
    ///   - html: the source document.
    ///   - baseURL: directory that relative image paths resolve against (nil = only data: images).
    static func write(html: String, baseURL: URL?, title: String, language: String?, to output: URL, temp: URL) async throws {
        let root = temp.appendingPathComponent("epub-\(UUID().uuidString)")
        let oebps = root.appendingPathComponent("OEBPS")
        let imagesDir = oebps.appendingPathComponent("images")
        let fm = FileManager.default
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)

        let doc: XMLDocument
        do {
            doc = try XMLDocument(xmlString: html, options: [.documentTidyHTML])
        } catch {
            throw KumquatError(l: "Couldn't read the document's HTML: %@", error.localizedDescription)
        }
        let headStyles = ((try? doc.nodes(forXPath: "//head//style")) ?? []).compactMap { $0.stringValue }
        guard let body = (try? doc.nodes(forXPath: "//body"))?.first as? XMLElement else {
            throw KumquatError(l: "The document has no content.")
        }
        for xpath in ["//script", "//noscript", "//iframe", "//object", "//embed", "//form", "//base", "//link", "//meta"] {
            for node in (try? body.nodes(forXPath: xpath)) ?? [] { node.detach() }
        }
        var images: [(name: String, type: String)] = []
        try collectImages(in: body, baseURL: baseURL, into: imagesDir, images: &images)
        for case let a as XMLElement in (try? body.nodes(forXPath: ".//a[@href]")) ?? [] {
            let href = a.attribute(forName: "href")?.stringValue ?? ""
            let lower = href.lowercased()
            if !(href.hasPrefix("#") || lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("mailto:")) {
                a.removeAttribute(forName: "href")
            }
        }

        let chapters = splitChapters(body, documentTitle: title)
        let lang = (language?.isEmpty == false ? language! : (Locale.current.language.languageCode?.identifier ?? "en"))

        // Files
        let css = baseCSS + "\n" + headStyles.joined(separator: "\n")
        try write("application/epub+zip", to: root.appendingPathComponent("mimetype"))
        try write(containerXML, to: root.appendingPathComponent("META-INF/container.xml"))
        try write(css, to: oebps.appendingPathComponent("style.css"))
        var chapterFiles: [String] = []
        for (i, chapter) in chapters.enumerated() {
            let name = String(format: "chapter-%03d.xhtml", i + 1)
            chapterFiles.append(name)
            try write(xhtmlPage(title: chapter.title, body: chapter.xhtml, lang: lang), to: oebps.appendingPathComponent(name))
        }
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        try write(navXHTML(chapters: chapters, files: chapterFiles, title: title, lang: lang), to: oebps.appendingPathComponent("nav.xhtml"))
        try write(ncx(chapters: chapters, files: chapterFiles, title: title, identifier: identifier), to: oebps.appendingPathComponent("toc.ncx"))
        try write(opf(title: title, lang: lang, identifier: identifier, files: chapterFiles, images: images),
                  to: oebps.appendingPathComponent("content.opf"))
        if images.isEmpty { try? fm.removeItem(at: imagesDir) }

        // mimetype first and uncompressed, then everything else.
        let tmpOut = temp.appendingPathComponent("\(UUID().uuidString).epub")
        do {
            try await ProcessRunner.run(OfficeSupport.zip, ["-X0q", tmpOut.path, "mimetype"], currentDirectory: root)
            try await ProcessRunner.run(OfficeSupport.zip, ["-Xr9Dq", tmpOut.path, "META-INF", "OEBPS"], currentDirectory: root)
        } catch let e as ProcessError {
            throw KumquatError(l: "Couldn't pack the EPUB: %@", e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try fm.moveItem(at: tmpOut, to: output)
    }

    // MARK: - Images

    private static func collectImages(in body: XMLElement, baseURL: URL?, into dir: URL,
                                      images: inout [(name: String, type: String)]) throws {
        var byKey: [String: String] = [:]
        for case let img as XMLElement in (try? body.nodes(forXPath: ".//img")) ?? [] {
            img.removeAttribute(forName: "srcset")
            let src = img.attribute(forName: "src")?.stringValue ?? ""
            var data: Data?
            var ext = "png"
            if src.lowercased().hasPrefix("data:") {
                if let comma = src.firstIndex(of: ","), src[..<comma].lowercased().contains(";base64") {
                    let header = src[..<comma].lowercased()
                    data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters)
                    ext = header.contains("jpeg") || header.contains("jpg") ? "jpg" : header.contains("gif") ? "gif"
                        : header.contains("svg") ? "svg" : header.contains("webp") ? "webp" : "png"
                }
            } else if let url = localURL(src, baseURL: baseURL) {
                ext = url.pathExtension.lowercased() == "jpeg" ? "jpg" : url.pathExtension.lowercased()
                if ["png", "jpg", "gif", "svg", "webp"].contains(ext) { data = try? Data(contentsOf: url) }
            }
            guard let data, !data.isEmpty else {
                // Remote or missing images can't go into the book: keep the alt text.
                let alt = img.attribute(forName: "alt")?.stringValue ?? ""
                if let parent = img.parent as? XMLElement {
                    let index = img.index
                    img.detach()
                    if !alt.isEmpty { parent.insertChild(XMLNode.text(withStringValue: alt) as! XMLNode, at: index) }
                }
                continue
            }
            let key = "\(data.count)-\(data.hashValue)"
            let name: String
            if let existing = byKey[key] {
                name = existing
            } else {
                name = "image-\(images.count + 1).\(ext)"
                try data.write(to: dir.appendingPathComponent(name))
                images.append((name, EpubReader.mimeType(for: URL(fileURLWithPath: name))))
                byKey[key] = name
            }
            img.attribute(forName: "src")?.stringValue = "images/\(name)"
            if img.attribute(forName: "alt") == nil { img.addAttribute(XMLNode.attribute(withName: "alt", stringValue: "") as! XMLNode) }
        }
    }

    private static func localURL(_ src: String, baseURL: URL?) -> URL? {
        guard !src.isEmpty else { return nil }
        if src.lowercased().hasPrefix("file:") { return URL(string: src).flatMap { $0.isFileURL ? $0 : nil } }
        guard !src.contains("://"), let baseURL else { return nil }
        let path = src.split(separator: "?").first.map(String.init) ?? src
        return URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(path.removingPercentEncoding ?? path)
    }

    // MARK: - Chapters

    static func splitChapters(_ body: XMLElement, documentTitle: String) -> [Chapter] {
        // Descend through single wrapper elements (<div><main>…) to find the headings' level.
        var container = body
        while let children = container.children?.compactMap({ $0 as? XMLElement }), children.count == 1,
              let only = children.first, ["div", "main", "article", "section"].contains(only.name?.lowercased() ?? ""),
              (container.children ?? []).allSatisfy({ $0.kind == .element || ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            container = only
        }
        var chapters: [Chapter] = []
        var current: [XMLNode] = []
        var currentTitle: String?
        func flush() {
            let markup = current.map { serialize($0) }.joined()
            let hasContent = current.contains { node in
                if let e = node as? XMLElement, ((try? e.nodes(forXPath: ".//img")) ?? []).isEmpty == false { return true }
                return !(node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if hasContent || currentTitle != nil {
                chapters.append(Chapter(title: currentTitle ?? documentTitle, xhtml: markup))
            }
            current = []
        }
        // Split at <h1>; documents without one (e.g. converted from Word) split at <h2>.
        let topLevel = (container.children ?? []).compactMap { ($0 as? XMLElement)?.name?.lowercased() }
        let splitTag = topLevel.contains("h1") ? "h1" : "h2"
        for node in container.children ?? [] {
            if let e = node as? XMLElement, e.name?.lowercased() == splitTag {
                flush()
                let text = (e.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                currentTitle = text.isEmpty ? "Chapter \(chapters.count + 1)" : text
            }
            current.append(node)
        }
        flush()
        if chapters.isEmpty { chapters.append(Chapter(title: documentTitle, xhtml: "<p></p>")) }
        return chapters
    }

    private static func serialize(_ node: XMLNode) -> String {
        var xml = stripInvalidXMLCharacters(node.xmlString(options: [.nodeCompactEmptyElement]))
        // Tidy serializes void elements as <br></br>; readers with HTML parsers see two breaks.
        if let re = try? NSRegularExpression(pattern: #"<(br|hr|img|col|wbr|area|input|source|track|embed|param)\b([^>]*?)/?>\s*</\1>"#,
                                             options: [.caseInsensitive]) {
            xml = re.stringByReplacingMatches(in: xml, range: NSRange(location: 0, length: (xml as NSString).length), withTemplate: "<$1$2/>")
        }
        return xml
    }

    static func stripInvalidXMLCharacters(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { u in
            u == "\t" || u == "\n" || u == "\r" || (u.value >= 0x20 && u.value != 0xFFFE && u.value != 0xFFFF)
        }))
    }

    // MARK: - Templates

    private static func x(_ s: String) -> String { EpubReader.escapeText(s).replacingOccurrences(of: "\"", with: "&quot;") }

    private static func write(_ s: String, to url: URL) throws { try s.write(to: url, atomically: true, encoding: .utf8) }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static let baseCSS = """
    body { font-family: serif; line-height: 1.5; margin: 0 5%; }
    h1, h2, h3 { line-height: 1.25; page-break-after: avoid; }
    img { max-width: 100%; height: auto; }
    pre, code { font-family: monospace; white-space: pre-wrap; }
    table { border-collapse: collapse; }
    td, th { border: 1px solid #999; padding: 0.2em 0.5em; }
    """

    private static func xhtmlPage(title: String, body: String, lang: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(x(lang))" lang="\(x(lang))">
        <head>
        <meta charset="UTF-8"/>
        <title>\(x(title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func navXHTML(chapters: [Chapter], files: [String], title: String, lang: String) -> String {
        let items = zip(chapters, files).map { "      <li><a href=\"\($1)\">\(x($0.title))</a></li>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(x(lang))" lang="\(x(lang))">
        <head>
        <meta charset="UTF-8"/>
        <title>\(x(title))</title>
        </head>
        <body>
        <nav epub:type="toc" id="toc">
          <h1>Contents</h1>
          <ol>
        \(items)
          </ol>
        </nav>
        </body>
        </html>
        """
    }

    private static func ncx(chapters: [Chapter], files: [String], title: String, identifier: String) -> String {
        let points = zip(chapters, files).enumerated().map { i, pair in
            """
                <navPoint id="nav-\(i + 1)" playOrder="\(i + 1)">
                  <navLabel><text>\(x(pair.0.title))</text></navLabel>
                  <content src="\(pair.1)"/>
                </navPoint>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(x(identifier))"/>
            <meta name="dtb:depth" content="1"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle><text>\(x(title))</text></docTitle>
          <navMap>
        \(points)
          </navMap>
        </ncx>
        """
    }

    private static func opf(title: String, lang: String, identifier: String, files: [String],
                            images: [(name: String, type: String)]) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        let modified = f.string(from: Date())
        var manifest = [
            "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
            "    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
            "    <item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>",
        ]
        for (i, file) in files.enumerated() {
            manifest.append("    <item id=\"ch\(i + 1)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>")
        }
        for (i, image) in images.enumerated() {
            manifest.append("    <item id=\"img\(i + 1)\" href=\"images/\(image.name)\" media-type=\"\(image.type)\"/>")
        }
        let spine = files.indices.map { "    <itemref idref=\"ch\($0 + 1)\"/>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(x(lang))">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(x(identifier))</dc:identifier>
            <dc:title>\(x(title))</dc:title>
            <dc:language>\(x(lang))</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
        \(manifest.joined(separator: "\n"))
          </manifest>
          <spine toc="ncx">
        \(spine)
          </spine>
        </package>
        """
    }
}
