import Foundation

/// An unpacked EPUB (2 or 3): metadata and the spine's XHTML chapters in reading order.
struct EpubBook {
    var root: URL
    var title: String?
    var author: String?
    var language: String?
    var chapters: [URL]
}

enum EpubReader {
    /// Unpacks `epub` into `dir` (zip-slip safe) and reads its package document.
    /// Unpacked EPUB folders (as Apple Books stores them) are copied, never modified.
    static func open(_ epub: URL, unpackInto dir: URL) async throws -> EpubBook {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: epub.path, isDirectory: &isDir)
        let root = dir.appendingPathComponent("book")
        if isDir.boolValue {
            try FileManager.default.copyItem(at: epub, to: root)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                try await ArchiveSupport.extract(epub, format: .zip, into: root)
            } catch let e as NurToError {
                throw e
            } catch {
                throw NurToError(l: "“%@” isn't a valid EPUB (it can't be unzipped).", epub.lastPathComponent)
            }
            try ArchiveSupport.verifyContained(root)
        }
        return try read(root: root, name: epub.lastPathComponent)
    }

    static func read(root: URL, name: String) throws -> EpubBook {
        let container = root.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: container) else {
            throw NurToError(l: "“%@” isn't a valid EPUB (META-INF/container.xml is missing).", name)
        }
        let rootfile = EpubXMLCollector.parse(containerData).first { $0.name == "rootfile" && $0.attributes["full-path"] != nil }
        guard let opfPath = rootfile?.attributes["full-path"],
              let opfURL = OfficeSupport.containedFile(opfPath, in: root),
              let opfData = try? Data(contentsOf: opfURL) else {
            throw NurToError(l: "“%@” isn't a valid EPUB (the package document is missing).", name)
        }
        let opfDir = opfURL.deletingLastPathComponent()
        let elements = EpubXMLCollector.parse(opfData)

        var manifest: [String: (url: URL, type: String)] = [:]
        for item in elements where item.name == "item" {
            guard let id = item.attributes["id"], let href = item.attributes["href"],
                  let url = resolve(href, against: opfDir, root: root) else { continue }
            manifest[id] = (url, item.attributes["media-type"] ?? "")
        }
        var chapters: [URL] = []
        for ref in elements where ref.name == "itemref" {
            guard let id = ref.attributes["idref"], let item = manifest[id] else { continue }
            let type = item.type.lowercased()
            let ext = item.url.pathExtension.lowercased()
            guard type.contains("html") || ["xhtml", "html", "htm"].contains(ext) else { continue }
            if FileManager.default.fileExists(atPath: item.url.path) { chapters.append(item.url) }
        }
        guard !chapters.isEmpty else { throw NurToError(l: "“%@” has no readable chapters.", name) }

        func text(_ local: String) -> String? {
            elements.first { $0.name == local && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return EpubBook(root: root, title: text("title"), author: text("creator"), language: text("language"), chapters: chapters)
    }

    /// Resolves a (percent-encoded) relative href; nil if it points outside the book.
    static func resolve(_ href: String, against base: URL, root: URL) -> URL? {
        let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
        guard !path.isEmpty, !path.contains(":") else { return nil }
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL.standardizedFileURL, url.isFileURL else { return nil }
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
        return url
    }

    // MARK: - Combined HTML

    enum ResourceMode {
        /// Absolute file: URLs (for WebKit / textutil reading from the unpacked book).
        case fileURLs
        /// Self-contained: images become data: URIs and stylesheets are inlined.
        case embedded
    }

    /// All chapters concatenated into one HTML document, in spine order. Each chapter is a
    /// `<section class="kq-chapter">` that starts on a new page when printed.
    static func combinedHTML(_ book: EpubBook, mode: ResourceMode, fallbackTitle: String) -> String {
        var stylesheets: [URL] = []
        var inlineStyles: [String] = []
        var sections: [String] = []
        let chapterIndex = Dictionary(book.chapters.enumerated().map { ($1.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })

        for (index, chapter) in book.chapters.enumerated() {
            guard let data = try? Data(contentsOf: chapter) else { continue }
            let source = String(data: data, encoding: .utf8) ?? DocumentTextDecoder.decode(data)
            let base = chapter.deletingLastPathComponent()

            let head = firstMatch(#"<head\b[^>]*>([\s\S]*?)</head>"#, in: source) ?? ""
            for link in allMatches(#"<link\b[^>]*>"#, in: head) where link.range(of: "stylesheet", options: .caseInsensitive) != nil {
                if let href = attribute("href", in: link), let url = resolve(href, against: base, root: book.root),
                   !stylesheets.contains(url) { stylesheets.append(url) }
            }
            for style in allMatches(#"<style\b[^>]*>([\s\S]*?)</style>"#, in: head, group: 1) { inlineStyles.append(style) }

            var body = source
            var bodyClass = ""
            if let re = try? NSRegularExpression(pattern: #"<body\b([^>]*)>([\s\S]*)</body>"#, options: [.caseInsensitive]),
               let m = re.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)) {
                let ns = source as NSString
                bodyClass = attribute("class", in: "<b \(ns.substring(with: m.range(at: 1)))>") ?? ""
                body = ns.substring(with: m.range(at: 2))
            }
            body = removeMatches(#"<script\b[\s\S]*?</script>"#, in: body)
            body = svgCoversToImages(body)
            body = expandSelfClosing(body)
            body = rewriteReferences(body, base: base, book: book, mode: mode, chapterIndex: chapterIndex)
            let cls = ("kq-chapter " + bodyClass).trimmingCharacters(in: .whitespaces)
            sections.append("<section class=\"\(escapeAttr(cls))\" id=\"kq-ch-\(index + 1)\">\n\(body)\n</section>")
        }

        var css = ""
        switch mode {
        case .fileURLs:
            css = stylesheets.map { "<link rel=\"stylesheet\" href=\"\(escapeAttr($0.absoluteString))\">" }.joined(separator: "\n")
        case .embedded:
            css = stylesheets.compactMap { url -> String? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</style", with: "<\\/style")
                return "<style>\n\(text)\n</style>"
            }.joined(separator: "\n")
        }
        css += inlineStyles.map { "\n<style>\n\($0)\n</style>" }.joined()

        let title = book.title ?? fallbackTitle
        let author = book.author.map { "<meta name=\"author\" content=\"\(escapeAttr($0))\">\n" } ?? ""
        let lang = book.language.map { " lang=\"\(escapeAttr($0))\"" } ?? ""
        return """
        <!DOCTYPE html>
        <html\(lang)>
        <head>
        <meta charset="utf-8">
        <title>\(escapeText(title))</title>
        \(author)<style>
        body { font: 16px/1.5 "Iowan Old Style", "Palatino", Georgia, serif; color: #111; background: #fff; margin: 0 auto; max-width: 44em; padding: 0 1em; }
        </style>
        \(css)
        <style>
        img, svg, video { max-width: 100% !important; height: auto; }
        .kq-chapter + .kq-chapter { page-break-before: always; break-before: page; }
        pre { white-space: pre-wrap; }
        @media print { body { max-width: none; padding: 0; } }
        </style>
        </head>
        <body>
        \(sections.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    // MARK: - Rewriting

    private static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input",
                                                    "link", "meta", "param", "source", "track", "wbr"]

    /// XHTML `<a id="x"/>` would swallow the rest of the chapter in an HTML parser.
    static func expandSelfClosing(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<([A-Za-z][\w:.-]*)(\s[^<>]*?)?\s*/>"#) else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            let attrs = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            if voidElements.contains(name.lowercased()) || isInsideSVG(name) {
                out += ns.substring(with: m.range)
            } else {
                out += "<\(name)\(attrs)></\(name)>"
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// SVG children (path, rect, image…) may stay self-closing: the HTML parser handles foreign content.
    private static func isInsideSVG(_ name: String) -> Bool {
        ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "image", "use", "stop"].contains(name.lowercased())
    }

    /// The common EPUB cover `<svg><image xlink:href="cover.jpg"/></svg>` → `<img>` (textutil ignores SVG).
    static func svgCoversToImages(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<svg\b[^>]*>\s*<image\b[^>]*?(?:xlink:)?href\s*=\s*["']([^"']+)["'][^>]*>\s*(?:</image>\s*)?</svg>"#,
                                                options: [.caseInsensitive]) else { return html }
        return re.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length),
                                           withTemplate: "<img class=\"kq-cover\" src=\"$1\" alt=\"\">")
    }

    private static func rewriteReferences(_ html: String, base: URL, book: EpubBook, mode: ResourceMode,
                                          chapterIndex: [String: Int]) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(\s(?:src|href|xlink:href|poster)\s*=\s*)(["'])([^"']*)\2"#,
                                                options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            let prefix = ns.substring(with: m.range(at: 1))
            let value = decodeAttr(ns.substring(with: m.range(at: 3)))
            let isLink = prefix.lowercased().contains("href") && !prefix.lowercased().contains("xlink")
            out += prefix + "\"" + escapeAttr(rewrite(value, isLink: isLink, base: base, book: book, mode: mode, chapterIndex: chapterIndex)) + "\""
        }
        out += ns.substring(from: last)
        return out
    }

    private static func rewrite(_ value: String, isLink: Bool, base: URL, book: EpubBook, mode: ResourceMode,
                                chapterIndex: [String: Int]) -> String {
        let lower = value.lowercased()
        if value.isEmpty || value.hasPrefix("#") || lower.hasPrefix("data:") || lower.hasPrefix("mailto:")
            || lower.hasPrefix("http:") || lower.hasPrefix("https:") { return value }
        guard let url = resolve(value, against: base, root: book.root) else { return isLink ? "#" : "" }
        if isLink {
            // Links between chapters become in-document anchors.
            let fragment = value.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init)
            if let fragment, !fragment.isEmpty { return "#" + fragment }
            if let index = chapterIndex[url.path] { return "#kq-ch-\(index + 1)" }
            return "#"
        }
        switch mode {
        case .fileURLs:
            return url.absoluteString
        case .embedded:
            guard let data = try? Data(contentsOf: url), data.count < 40_000_000 else { return "" }
            return "data:\(mimeType(for: url));base64,\(data.base64EncodedString())"
        }
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "css": return "text/css"
        default: return "image/png"
        }
    }

    // MARK: - String helpers

    static func firstMatch(_ pattern: String, in s: String, group: Int = 1) -> String? {
        allMatches(pattern, in: s, group: group).first
    }

    static func allMatches(_ pattern: String, in s: String, group: Int = 0) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.range(at: group).location == NSNotFound ? nil : ns.substring(with: $0.range(at: group))
        }
    }

    static func removeMatches(_ pattern: String, in s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        firstMatch(#"\s"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']*)["']"#, in: tag).map(decodeAttr)
    }

    static func decodeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Flat list of XML elements (local name, attributes, direct text). Enough for container.xml and OPF files.
final class EpubXMLCollector: NSObject, XMLParserDelegate {
    struct Element { var name: String; var attributes: [String: String]; var text: String }
    private(set) var elements: [Element] = []
    private var stack: [Int] = []

    static func parse(_ data: Data) -> [Element] {
        let collector = EpubXMLCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        parser.parse()
        return collector.elements
    }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attrs: [String: String] = [:]
        for (k, v) in attributeDict { attrs[Self.local(k)] = v }
        elements.append(Element(name: Self.local(elementName), attributes: attrs, text: ""))
        stack.append(elements.count - 1)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let i = stack.last { elements[i].text += string }
    }
}
