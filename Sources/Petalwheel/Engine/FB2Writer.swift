import Foundation
import AppKit

/// Writes FictionBook 2 from an HTML document: sections nested by heading level (or one top-level section
/// per EPUB chapter), paragraphs with strong / emphasis / strikethrough / sub / sup / code and external
/// links, lists as bulleted paragraphs, blockquotes as cites, tables, and pictures embedded as base64
/// `<binary>` (PNG / JPEG; other formats are re-encoded as PNG).
enum FB2Writer {
    struct Metadata {
        var title: String
        var authors: [String] = []
        var language: String?
    }

    static func write(html: String, baseURL: URL?, metadata: Metadata, to output: URL) throws {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(xmlString: html, options: [.documentTidyHTML])
        } catch {
            throw NurToError(l: "Couldn't read the document's HTML: %@", error.localizedDescription)
        }
        guard let body = (try? doc.nodes(forXPath: "//body"))?.first as? XMLElement else {
            throw NurToError(l: "The document has no content.")
        }
        var b = Builder(baseURL: baseURL)
        let chapters = ((try? body.nodes(forXPath: ".//section[contains(concat(' ', @class, ' '), ' kq-chapter ')]")) ?? [])
            .compactMap { $0 as? XMLElement }
        if chapters.isEmpty {
            b.walk(body)
        } else {
            for chapter in chapters {
                b.blocks.append(.chapter)
                b.walk(chapter)
            }
        }
        let htmlLang = (try? doc.nodes(forXPath: "//html/@lang"))?.first?.stringValue
        var meta = metadata
        if meta.language == nil || meta.language?.isEmpty == true { meta.language = htmlLang }
        let xml = b.fictionBook(meta)
        try xml.write(to: output, atomically: true, encoding: .utf8)
    }

    // MARK: - Model

    struct Style: OptionSet, Hashable {
        let rawValue: Int
        static let strong = Style(rawValue: 1), emphasis = Style(rawValue: 2), strike = Style(rawValue: 4),
                   sub = Style(rawValue: 8), sup = Style(rawValue: 16), code = Style(rawValue: 32)
    }

    enum Segment {
        case text(String, Style, link: String?)
        case lineBreak
        case image(String)        // binary id
    }

    indirect enum Block {
        case chapter
        case heading(level: Int, text: String)
        case paragraph(String)
        case image(String)
        case empty
        case cite([Block])
        case table([[String]])
    }

    final class Section {
        var depth: Int
        var title: String?
        var blocks: [Block] = []
        var children: [Section] = []
        init(depth: Int, title: String?) { self.depth = depth; self.title = title }
    }

    // MARK: - Builder

    struct Builder {
        let baseURL: URL?
        var blocks: [Block] = []
        var binaries: [(id: String, type: String, data: Data)] = []
        var binaryByHash: [String: String] = [:]

        init(baseURL: URL?) { self.baseURL = baseURL }

        static let skip: Set<String> = ["head", "script", "style", "noscript", "template", "nav", "svg", "math", "iframe", "object", "button", "form", "input", "select", "textarea"]
        static let blockTags: Set<String> = ["p", "div", "section", "article", "main", "header", "footer", "aside", "blockquote", "ul", "ol",
                                             "li", "dl", "dt", "dd", "table", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "figure",
                                             "figcaption", "hr", "address", "center", "body", "tbody", "thead", "tr", "td", "th", "details", "summary"]

        static func tag(_ n: XMLNode) -> String { (n as? XMLElement)?.name?.lowercased() ?? "" }

        static func hasBlockChild(_ e: XMLElement) -> Bool {
            (e.children ?? []).contains { c in
                let t = tag(c)
                return blockTags.contains(t) || (t == "img" && isStandaloneImage(c as! XMLElement, in: e))
            }
        }

        /// An image that is the only meaningful content of its parent.
        static func isStandaloneImage(_ img: XMLElement, in parent: XMLElement) -> Bool {
            (parent.children ?? []).allSatisfy { $0 === img || ($0.kind == .text && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }

        // MARK: Walking blocks

        mutating func walk(_ e: XMLElement) {
            var run: [XMLNode] = []
            func flush(_ b: inout Builder) {
                if !run.isEmpty { b.blocks += b.paragraphs(from: run); run = [] }
            }
            for node in e.children ?? [] {
                let t = Self.tag(node)
                if node.kind == .comment || Self.skip.contains(t) { continue }
                if node.kind == .element && (Self.blockTags.contains(t) || (t == "img" && Self.isStandaloneImage(node as! XMLElement, in: e))) {
                    flush(&self)
                    blockElement(node as! XMLElement)
                } else {
                    run.append(node)
                }
            }
            flush(&self)
        }

        mutating func blockElement(_ e: XMLElement) {
            let t = Self.tag(e)
            switch t {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let text = inlineParagraphs(e.children ?? []).joined(separator: " ")
                if !text.isEmpty { blocks.append(.heading(level: Int(t.dropFirst())!, text: text)) }
            case "hr":
                blocks.append(.empty)
            case "img":
                if let id = imageID(e) { blocks.append(.image(id)) }
            case "blockquote":
                var inner = Builder(baseURL: baseURL)
                inner.binaries = binaries
                inner.binaryByHash = binaryByHash
                inner.walk(e)
                binaries = inner.binaries
                binaryByHash = inner.binaryByHash
                // FB2 cites hold paragraphs only: headings become bold paragraphs, nested cites flatten.
                let flat = inner.blocks.flatMap { b -> [Block] in
                    switch b {
                    case .heading(_, let text): return [.paragraph("<strong>\(text)</strong>")]
                    case .cite(let inner): return inner
                    case .chapter: return []
                    default: return [b]
                    }
                }
                if !flat.isEmpty { blocks.append(.cite(flat)) }
            case "ul", "ol":
                var n = 0
                for li in (e.children ?? []).compactMap({ $0 as? XMLElement }) where Self.tag(li) == "li" {
                    n += 1
                    let marker = t == "ol" ? "\(n). " : "• "
                    let before = blocks.count
                    if Self.hasBlockChild(li) { walk(li) } else { blocks += paragraphs(from: li.children ?? []) }
                    // Prefix the item's first paragraph.
                    if let idx = blocks.indices.dropFirst(before).first(where: { if case .paragraph = blocks[$0] { return true }; return false }),
                       case .paragraph(let text) = blocks[idx] {
                        blocks[idx] = .paragraph(marker + text)
                    }
                }
            case "pre":
                let text = (e.stringValue ?? "").replacingOccurrences(of: "\r\n", with: "\n")
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    blocks.append(trimmed.isEmpty ? .empty : .paragraph("<code>\(FB2Writer.escape(line))</code>"))
                }
                if case .empty = blocks.last { blocks.removeLast() }
            case "table":
                var rows: [[String]] = []
                for tr in ((try? e.nodes(forXPath: ".//tr")) ?? []).compactMap({ $0 as? XMLElement }) {
                    let cells = (tr.children ?? []).compactMap { $0 as? XMLElement }.filter { ["td", "th"].contains(Self.tag($0)) }
                    rows.append(cells.map { cell in
                        let text = inlineParagraphs(cell.children ?? []).joined(separator: " ")
                        return Self.tag(cell) == "th" && !text.isEmpty ? "<strong>\(text)</strong>" : text
                    })
                }
                if !rows.isEmpty { blocks.append(.table(rows)) }
            case "dt":
                let text = inlineParagraphs(e.children ?? []).joined(separator: " ")
                if !text.isEmpty { blocks.append(.paragraph("<strong>\(text)</strong>")) }
            default:
                if Self.hasBlockChild(e) { walk(e) } else { blocks += paragraphs(from: e.children ?? []) }
            }
        }

        /// Inline nodes → paragraphs (split at <br>), with pictures moved out as image blocks.
        mutating func paragraphs(from nodes: [XMLNode]) -> [Block] {
            var out: [Block] = []
            var segments: [Segment] = []
            for n in nodes { collect(n, style: [], link: nil, into: &segments) }
            var current: [Segment] = []
            var pendingImages: [String] = []
            func emit() {
                let text = FB2Writer.render(current)
                if text.unicodeScalars.allSatisfy({ $0 == "\u{00A0}" || $0 == " " }) {
                    // A paragraph holding only a no-break space is a spacer.
                    if !text.isEmpty { out.append(.empty) }
                } else {
                    out.append(.paragraph(text))
                }
                for id in pendingImages { out.append(.image(id)) }
                current = []
                pendingImages = []
            }
            for s in segments {
                switch s {
                case .lineBreak: emit()
                case .image(let id): pendingImages.append(id)
                default: current.append(s)
                }
            }
            emit()
            return out
        }

        mutating func inlineParagraphs(_ nodes: [XMLNode]) -> [String] {
            var segments: [Segment] = []
            for n in nodes { collect(n, style: [], link: nil, into: &segments) }
            var parts: [String] = []
            var current: [Segment] = []
            for s in segments {
                if case .lineBreak = s { parts.append(FB2Writer.render(current)); current = [] }
                else if case .text = s { current.append(s) }
            }
            parts.append(FB2Writer.render(current))
            return parts.filter { !$0.isEmpty }
        }

        mutating func collect(_ node: XMLNode, style: Style, link: String?, into out: inout [Segment]) {
            if node.kind == .text {
                if let s = node.stringValue, !s.isEmpty { out.append(.text(s, style, link: link)) }
                return
            }
            guard let e = node as? XMLElement else { return }
            let t = Self.tag(e)
            if Self.skip.contains(t) { return }
            var st = style
            var ln = link
            switch t {
            case "br": out.append(.lineBreak); return
            case "img":
                if let id = imageID(e) { out.append(.image(id)) }
                return
            case "b", "strong": st.insert(.strong)
            case "i", "em", "cite", "dfn", "var": st.insert(.emphasis)
            case "s", "strike", "del": st.insert(.strike)
            case "sub": st.insert(.sub)
            case "sup": st.insert(.sup)
            case "code", "kbd", "tt", "samp": st.insert(.code)
            case "a":
                if let href = e.attribute(forName: "href")?.stringValue {
                    let lower = href.lowercased()
                    if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("mailto:") { ln = href }
                }
            default: break
            }
            // Block elements nested in inline context still separate paragraphs.
            let isBlock = Self.blockTags.contains(t)
            if isBlock, !out.isEmpty { out.append(.lineBreak) }
            for c in e.children ?? [] { collect(c, style: st, link: ln, into: &out) }
            if isBlock { out.append(.lineBreak) }
        }

        // MARK: Images

        mutating func imageID(_ img: XMLElement) -> String? {
            let src = img.attribute(forName: "src")?.stringValue ?? ""
            var data: Data?
            var type = "image/png"
            if src.lowercased().hasPrefix("data:") {
                if let comma = src.firstIndex(of: ","), src[..<comma].lowercased().contains(";base64") {
                    type = String(src[src.index(src.startIndex, offsetBy: 5)..<comma]).split(separator: ";").first.map(String.init) ?? type
                    data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters)
                }
            } else if let url = localURL(src) {
                data = try? Data(contentsOf: url)
                let ext = url.pathExtension.lowercased()
                type = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : ext == "png" ? "image/png" : "image/\(ext)"
            }
            guard var bytes = data, !bytes.isEmpty else { return nil }
            if bytes.starts(with: [0xFF, 0xD8]) { type = "image/jpeg" }
            else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { type = "image/png" }
            else {
                // GIF, WebP, SVG, TIFF…: FB2 readers expect PNG or JPEG.
                guard let image = NSImage(data: bytes), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let png = try? ImageCodec.encode(cg, format: .png, quality: 1) else { return nil }
                bytes = png
                type = "image/png"
            }
            let key = "\(bytes.count)-\(bytes.hashValue)"
            if let existing = binaryByHash[key] { return existing }
            let id = "image\(binaries.count + 1).\(type == "image/jpeg" ? "jpg" : "png")"
            binaries.append((id, type, bytes))
            binaryByHash[key] = id
            return id
        }

        func localURL(_ src: String) -> URL? {
            guard !src.isEmpty else { return nil }
            if src.lowercased().hasPrefix("file:") { return URL(string: src).flatMap { $0.isFileURL ? $0 : nil } }
            guard !src.contains("://"), let baseURL else { return nil }
            let path = src.split(separator: "?").first.map(String.init) ?? src
            return URL(string: path, relativeTo: baseURL)?.absoluteURL
        }

        // MARK: Sections

        func sections() -> [Section] {
            let root = Section(depth: 0, title: nil)
            var stack = [root]
            // Heading levels in use → nesting depth (h2-only documents still start at depth 1).
            let levels = Array(Set(blocks.compactMap { b -> Int? in if case .heading(let l, _) = b { return l }; return nil })).sorted()
            let chaptered = blocks.contains { if case .chapter = $0 { return true }; return false }
            var awaitingChapterTitle = false
            func current() -> Section {
                if stack.count == 1 {
                    let s = Section(depth: 1, title: nil)
                    root.children.append(s)
                    stack.append(s)
                }
                return stack.last!
            }
            for block in blocks {
                switch block {
                case .chapter:
                    stack = [root]
                    let s = Section(depth: 1, title: nil)
                    root.children.append(s)
                    stack.append(s)
                    awaitingChapterTitle = true
                case .heading(let level, let text):
                    if chaptered && awaitingChapterTitle, let top = stack.last, top.depth == 1, top.blocks.isEmpty, top.title == nil {
                        top.title = text
                        awaitingChapterTitle = false
                        continue
                    }
                    let rank = (levels.firstIndex(of: level) ?? 0) + 1
                    let depth = chaptered ? rank + 1 : rank
                    while let top = stack.last, top.depth >= depth, stack.count > 1 { stack.removeLast() }
                    if chaptered && stack.count == 1 { _ = current() }
                    let s = Section(depth: depth, title: text)
                    stack.last!.children.append(s)
                    stack.append(s)
                    awaitingChapterTitle = false
                default:
                    current().blocks.append(block)
                    awaitingChapterTitle = false
                }
            }
            return root.children
        }
    }

    // MARK: - Serialization

    static func escape(_ s: String) -> String {
        var out = ""
        for u in EpubWriter.stripInvalidXMLCharacters(s).unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// Text segments → FB2 inline markup with collapsed whitespace; each run gets its own (valid) tags.
    static func render(_ segments: [Segment]) -> String {
        var out = ""
        var lastSpace = true
        for case let .text(raw, style, link) in segments {
            var text = ""
            for ch in raw {
                if ch.isWhitespace && ch != "\u{00A0}" {
                    if !lastSpace { text.append(" "); lastSpace = true }
                } else {
                    text.append(ch)
                    lastSpace = false
                }
            }
            if text.isEmpty { continue }
            var piece = escape(text)
            if style.contains(.code) { piece = "<code>\(piece)</code>" }
            if style.contains(.sub) { piece = "<sub>\(piece)</sub>" }
            if style.contains(.sup) { piece = "<sup>\(piece)</sup>" }
            if style.contains(.strike) { piece = "<strikethrough>\(piece)</strikethrough>" }
            if style.contains(.emphasis) { piece = "<emphasis>\(piece)</emphasis>" }
            if style.contains(.strong) { piece = "<strong>\(piece)</strong>" }
            if let link { piece = "<a l:href=\"\(escape(link))\">\(piece)</a>" }
            out += piece
        }
        // Trim the whitespace collapsed at the ends (it may sit inside a tag).
        out = out.replacingOccurrences(of: #"^((?:<[^>]+>)*) "#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #" ((?:</[^>]+>)*)$"#, with: "$1", options: .regularExpression)
        // Merge adjacent runs with the same markup: </emphasis><emphasis> → nothing.
        out = out.replacingOccurrences(of: #"</(strong|emphasis|strikethrough|sub|sup|code)><\1>"#, with: "", options: .regularExpression)
        return out
    }

    private static func blockXML(_ b: Block, indent: String) -> String {
        switch b {
        case .paragraph(let t): return "\(indent)<p>\(t)</p>\n"
        case .image(let id): return "\(indent)<image l:href=\"#\(escape(id))\"/>\n"
        case .empty: return "\(indent)<empty-line/>\n"
        case .cite(let inner):
            return "\(indent)<cite>\n" + inner.map { blockXML($0, indent: indent + "  ") }.joined() + "\(indent)</cite>\n"
        case .table(let rows):
            var out = "\(indent)<table>\n"
            for row in rows { out += "\(indent)  <tr>" + row.map { "<td>\($0)</td>" }.joined() + "</tr>\n" }
            return out + "\(indent)</table>\n"
        case .heading(_, let t): return "\(indent)<subtitle>\(t)</subtitle>\n"
        case .chapter: return ""
        }
    }

    private static func sectionXML(_ s: Section, indent: String) -> String {
        var out = "\(indent)<section>\n"
        if let t = s.title, !t.isEmpty { out += "\(indent)  <title><p>\(t)</p></title>\n" }
        let content = s.blocks.map { blockXML($0, indent: indent + "  ") }.joined()
        if s.children.isEmpty {
            out += content.isEmpty ? "\(indent)  <empty-line/>\n" : content
        } else {
            // A section holds either content or subsections: lead-in text gets an untitled subsection.
            if !content.isEmpty {
                out += "\(indent)  <section>\n" + s.blocks.map { blockXML($0, indent: indent + "    ") }.joined() + "\(indent)  </section>\n"
            }
            for c in s.children { out += sectionXML(c, indent: indent + "  ") }
        }
        return out + "\(indent)</section>\n"
    }

    static func authorXML(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        if parts.count >= 2 {
            let first = escape(parts[0])
            let middle = parts.count > 2 ? "<middle-name>\(escape(parts[1..<(parts.count - 1)].joined(separator: " ")))</middle-name>" : ""
            return "<author><first-name>\(first)</first-name>\(middle)<last-name>\(escape(parts.last!))</last-name></author>"
        }
        return "<author><nickname>\(escape(name))</nickname></author>"
    }
}

extension FB2Writer.Builder {
    func fictionBook(_ meta: FB2Writer.Metadata) -> String {
        let secs = sections()
        let bodyText = secs.map { FB2Writer.sectionXMLPublic($0) }.joined()
        let lang: String = {
            if let l = meta.language?.split(separator: "-").first, !l.isEmpty { return String(l).lowercased() }
            // No declared language: Cyrillic text is most likely Russian.
            return bodyText.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? "ru" : "en"
        }()
        let authors = meta.authors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let authorXML = authors.isEmpty ? "<author><nickname>\(FB2Writer.escape(L("Unknown author")))</nickname></author>"
                                        : authors.map(FB2Writer.authorXML).joined(separator: "\n      ")
        let date = { () -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
          <description>
            <title-info>
              <genre>nonfiction</genre>
              \(authorXML)
              <book-title>\(FB2Writer.escape(meta.title))</book-title>
              <lang>\(FB2Writer.escape(lang))</lang>
            </title-info>
            <document-info>
              <author><nickname>NurTo</nickname></author>
              <program-used>NurTo</program-used>
              <date value="\(date)">\(date)</date>
              <id>\(UUID().uuidString.lowercased())</id>
              <version>1.0</version>
            </document-info>
          </description>
          <body>
            <title><p>\(FB2Writer.escape(meta.title))</p></title>

        """
        out += secs.isEmpty ? "    <section>\n      <empty-line/>\n    </section>\n" : bodyText
        out += "  </body>\n"
        for b in binaries {
            let base64 = b.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            out += "  <binary id=\"\(FB2Writer.escape(b.id))\" content-type=\"\(b.type)\">\n\(base64)\n  </binary>\n"
        }
        return out + "</FictionBook>\n"
    }
}

extension FB2Writer {
    fileprivate static func sectionXMLPublic(_ s: Section) -> String { sectionXML(s, indent: "    ") }
}
