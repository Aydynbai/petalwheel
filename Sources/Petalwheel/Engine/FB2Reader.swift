import Foundation

/// A FictionBook 2 document rendered as HTML (one `<h1>` per top-level section, so the EPUB writer makes
/// one chapter per section; nested sections become `<h2>`…`<h6>`).
struct FB2Book {
    var title: String
    var authors: [String]
    var language: String?
    var html: String
}

/// Reads FB2 (UTF-8 or any encoding declared in the XML prolog, e.g. windows-1251) and .fb2.zip.
/// Handles description/title-info, body sections and titles, paragraphs, emphasis / strong / strikethrough /
/// sub / sup / code, epigraphs, poems (stanzas, verses), cites, subtitles, empty lines, tables, notes
/// (bodies with a name, linked from `<a type="note">`) and base64 `<binary>` images referenced by l:href.
enum FB2Reader {
    enum ImageMode {
        /// Images as data: URIs (self-contained HTML, EPUB).
        case embedded
        /// Images written into a folder and referenced by file: URL (WebKit printing, textutil).
        case files(URL)
    }

    // MARK: Loading

    /// The FB2 XML document. `.fb2.zip` (and zipped files with any name) are unpacked into `temp` first.
    static func document(_ url: URL, temp: URL) async throws -> XMLDocument {
        var data = try Data(contentsOf: url)
        if data.starts(with: [0x50, 0x4B]) {
            let dir = temp.appendingPathComponent("fb2zip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await ArchiveSupport.extract(url, format: .zip, into: dir)
            try ArchiveSupport.verifyContained(dir)
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "fb2" } ?? []
            guard let inner = files.sorted(by: { $0.path < $1.path }).first else {
                throw PetalwheelError(l: "“%@” doesn't contain an FB2 book.", url.lastPathComponent)
            }
            data = try Data(contentsOf: inner)
        }
        if let doc = try? XMLDocument(data: data, options: []) { return doc }
        // Damaged prolog or an encoding libxml2 doesn't know: decode ourselves, declare UTF-8 and retry.
        var text = DocumentTextDecoder.decode(data)
        if let r = text.range(of: #"^\s*<\?xml[^>]*\?>"#, options: .regularExpression) { text.removeSubrange(r) }
        text = EpubWriter.stripInvalidXMLCharacters(text)
        do {
            return try XMLDocument(xmlString: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + text, options: [])
        } catch {
            throw PetalwheelError(l: "Couldn't read the FB2 book “%@”: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    static func read(_ url: URL, temp: URL, images: ImageMode) async throws -> FB2Book {
        let doc = try await document(url, temp: temp)
        guard let root = doc.rootElement(), name(root) == "FictionBook" else {
            throw PetalwheelError(l: "“%@” isn't an FB2 book.", url.lastPathComponent)
        }
        var r = Renderer(images: images)
        r.loadBinaries(root)
        return try r.render(root, fallbackTitle: fileBaseName(url))
    }

    /// "book.fb2.zip" → "book".
    static func fileBaseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".fb2.zip", ".fbz", ".fb2", ".zip"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }

    // MARK: XML helpers

    static func name(_ e: XMLElement) -> String { e.localName ?? e.name ?? "" }
    static func children(_ e: XMLElement) -> [XMLElement] { (e.children ?? []).compactMap { $0 as? XMLElement } }
    static func child(_ e: XMLElement, _ n: String) -> XMLElement? { children(e).first { name($0) == n } }
    static func attribute(_ e: XMLElement, _ local: String) -> String? {
        (e.attributes ?? []).first { ($0.localName ?? $0.name) == local }?.stringValue
    }
    static func text(_ e: XMLElement?) -> String {
        (e?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func esc(_ s: String) -> String { MarkdownToHTML.escapeHTML(s) }

    // MARK: Rendering

    private struct Renderer {
        let images: ImageMode
        var binaries: [String: (type: String, base64: String)] = [:]
        var writtenFiles: [String: String] = [:]
        var noteIDs: Set<String> = []

        init(images: ImageMode) { self.images = images }

        mutating func loadBinaries(_ root: XMLElement) {
            for b in children(root) where name(b) == "binary" {
                guard let id = attribute(b, "id") else { continue }
                var type = attribute(b, "content-type") ?? "image/jpeg"
                let raw = (b.stringValue ?? "").filter { !$0.isWhitespace }
                // Some books mislabel their pictures; trust the bytes.
                if let head = Data(base64Encoded: String(raw.prefix(16)), options: .ignoreUnknownCharacters) {
                    if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { type = "image/png" }
                    else if head.starts(with: [0xFF, 0xD8]) { type = "image/jpeg" }
                    else if head.starts(with: [0x47, 0x49, 0x46]) { type = "image/gif" }
                }
                binaries[id] = (type, raw)
            }
        }

        /// src for an image reference ("#id"), or nil when the binary is missing.
        mutating func imageSource(_ href: String?) -> String? {
            guard var id = href, !id.isEmpty else { return nil }
            if id.hasPrefix("#") { id.removeFirst() }
            guard let bin = binaries[id] else { return nil }
            switch images {
            case .embedded:
                return "data:\(bin.type);base64,\(bin.base64)"
            case .files(let dir):
                if let existing = writtenFiles[id] { return existing }
                guard let data = Data(base64Encoded: bin.base64, options: .ignoreUnknownCharacters) else { return nil }
                let ext = bin.type.contains("png") ? "png" : bin.type.contains("gif") ? "gif" : "jpg"
                let file = dir.appendingPathComponent("image-\(writtenFiles.count + 1).\(ext)")
                guard (try? data.write(to: file)) != nil else { return nil }
                writtenFiles[id] = file.absoluteString
                return file.absoluteString
            }
        }

        mutating func render(_ root: XMLElement, fallbackTitle: String) throws -> FB2Book {
            let description = child(root, "description")
            let titleInfo = description.flatMap { child($0, "title-info") }
            var title = text(titleInfo.flatMap { child($0, "book-title") })
            if title.isEmpty { title = fallbackTitle }
            let authors: [String] = titleInfo.map { info in
                children(info).filter { name($0) == "author" }.map { a in
                    let parts = ["first-name", "middle-name", "last-name"].map { text(child(a, $0)) }.filter { !$0.isEmpty }
                    return parts.isEmpty ? text(child(a, "nickname")) : parts.joined(separator: " ")
                }.filter { !$0.isEmpty }
            } ?? []
            let lang = text(titleInfo.flatMap { child($0, "lang") })

            let bodies = children(root).filter { name($0) == "body" }
            guard let main = bodies.first(where: { attribute($0, "name") == nil }) ?? bodies.first else {
                throw PetalwheelError(l: "The document has no content.")
            }
            for body in bodies where body !== main {
                for s in children(body) where name(s) == "section" {
                    if let id = attribute(s, "id") { noteIDs.insert(id) }
                }
            }

            // Title page: cover, author, title, annotation. No heading, so the EPUB writer keeps it as the
            // book's opening page instead of a numbered chapter.
            var html = "<div class=\"title-page\">\n"
            if let cover = titleInfo.flatMap({ child($0, "coverpage") }).flatMap({ children($0).first { name($0) == "image" } }),
               let src = imageSource(attribute(cover, "href")) {
                html += "<div class=\"cover\"><img src=\"\(esc(src))\" alt=\"\"/></div>\n"
            }
            if !authors.isEmpty { html += "<p class=\"author\">\(esc(authors.joined(separator: ", ")))</p>\n" }
            html += "<p class=\"book-title\"><strong>\(esc(title))</strong></p>\n"
            if let annotation = titleInfo.flatMap({ child($0, "annotation") }) {
                html += "<div class=\"annotation\">\n\(blocks(children(annotation), depth: 1))</div>\n"
            }
            html += "</div>\n"

            // The main body: its own title is the book title already shown above.
            for e in children(main) where name(e) != "title" {
                html += block(e, depth: 0)
            }
            // Notes and comments bodies.
            for body in bodies where body !== main {
                let heading = child(body, "title").map { titleText($0) } ?? ""
                html += "<h1 class=\"notes\">\(heading.isEmpty ? esc(L("Notes")) : heading)</h1>\n"
                for e in children(body) where name(e) != "title" {
                    if name(e) == "section" { html += note(e) } else { html += block(e, depth: 1) }
                }
            }

            let langAttr = lang.isEmpty ? "" : " lang=\"\(esc(lang))\""
            let document = """
            <!DOCTYPE html>
            <html\(langAttr)>
            <head>
            <meta charset="utf-8">
            <title>\(esc(title))</title>
            \(authors.isEmpty ? "" : "<meta name=\"author\" content=\"\(esc(authors.joined(separator: ", ")))\">")
            <style>
            body { font: 16px/1.5 "Iowan Old Style", Palatino, Georgia, serif; max-width: 44em; margin: 0 auto; padding: 0 1em; }
            .title-page { text-align: center; margin: 2em 0; }
            .title-page .author { font-size: 1.2em; }
            .title-page .book-title { font-size: 1.8em; margin: 0.5em 0 1em; }
            .annotation { text-align: left; font-style: italic; }
            .cover img { max-height: 70vh; }
            .epigraph { margin: 1em 0 1em 40%; font-style: italic; }
            .text-author { text-align: right; font-style: normal; font-weight: 600; }
            .poem { margin: 1em 2em; }
            .stanza { margin: 0.8em 0; }
            .stanza p, .poem p { margin: 0; text-indent: 0; }
            .subtitle { text-align: center; }
            .image { text-align: center; margin: 1em 0; }
            img { max-width: 100%; height: auto; }
            h1, h2, h3, h4, h5, h6 { text-align: center; }
            table { border-collapse: collapse; margin: 1em auto; }
            td, th { border: 1px solid #999; padding: 0.2em 0.5em; }
            </style>
            </head>
            <body>
            \(html)
            </body>
            </html>
            """
            return FB2Book(title: title, authors: authors, language: lang.isEmpty ? nil : lang, html: document)
        }

        /// A note section: anchor + bold title + its paragraphs.
        mutating func note(_ e: XMLElement) -> String {
            let id = attribute(e, "id").map { " id=\"\(esc($0))\"" } ?? ""
            var out = "<div class=\"note\"\(id)>\n"
            if let t = child(e, "title") { out += "<p><strong>\(titleText(t))</strong></p>\n" }
            for c in children(e) where name(c) != "title" { out += block(c, depth: 2) }
            return out + "</div>\n"
        }

        /// Title paragraphs joined by a line break (with a space so the plain text keeps a word gap).
        mutating func titleText(_ t: XMLElement) -> String {
            children(t).filter { name($0) == "p" }.map { inline($0) }.filter { !$0.isEmpty }.joined(separator: "<br/> ")
        }

        mutating func blocks(_ list: [XMLElement], depth: Int) -> String {
            list.map { block($0, depth: depth) }.joined()
        }

        mutating func block(_ e: XMLElement, depth: Int) -> String {
            switch name(e) {
            case "section":
                let level = min(depth + 1, 6)
                let id = attribute(e, "id").map { " id=\"\(esc($0))\"" } ?? ""
                var out = ""
                if let t = child(e, "title"), !titleText(t).isEmpty {
                    out += "<h\(level)\(id)>\(titleText(t))</h\(level)>\n"
                } else if !id.isEmpty {
                    out += "<a\(id)></a>\n"
                }
                for c in children(e) where name(c) != "title" { out += block(c, depth: depth + 1) }
                return out
            case "p":
                let id = attribute(e, "id").map { " id=\"\(esc($0))\"" } ?? ""
                return "<p\(id)>\(inline(e))</p>\n"
            case "subtitle":
                return "<p class=\"subtitle\"><strong>\(inline(e))</strong></p>\n"
            case "empty-line":
                return "<p class=\"empty-line\">&#160;</p>\n"
            case "text-author":
                return "<p class=\"text-author\">\(inline(e))</p>\n"
            case "date":
                return "<p class=\"date\"><em>\(inline(e))</em></p>\n"
            case "epigraph":
                return "<blockquote class=\"epigraph\">\n\(blocks(children(e), depth: depth))</blockquote>\n"
            case "cite":
                return "<blockquote class=\"cite\">\n\(blocks(children(e), depth: depth))</blockquote>\n"
            case "annotation":
                return "<div class=\"annotation\">\n\(blocks(children(e), depth: depth))</div>\n"
            case "poem":
                var out = "<div class=\"poem\">\n"
                for c in children(e) {
                    if name(c) == "title" { out += "<p class=\"subtitle\"><strong>\(titleText(c))</strong></p>\n" }
                    else { out += block(c, depth: depth) }
                }
                return out + "</div>\n"
            case "stanza":
                var out = "<div class=\"stanza\">\n"
                for c in children(e) {
                    switch name(c) {
                    case "title": out += "<p class=\"subtitle\"><strong>\(titleText(c))</strong></p>\n"
                    case "v": out += "<p class=\"v\">\(inline(c))</p>\n"
                    default: out += block(c, depth: depth)
                    }
                }
                return out + "</div>\n"
            case "v":
                return "<p class=\"v\">\(inline(e))</p>\n"
            case "image":
                guard let src = imageSource(attribute(e, "href")) else { return "" }
                let alt = attribute(e, "alt") ?? ""
                var out = "<div class=\"image\"><img src=\"\(esc(src))\" alt=\"\(esc(alt))\"/>"
                if let t = attribute(e, "title"), !t.isEmpty { out += "<br/><em>\(esc(t))</em>" }
                return out + "</div>\n"
            case "table":
                var out = "<table>\n"
                for tr in children(e) where name(tr) == "tr" {
                    out += "<tr>"
                    for cell in children(tr) {
                        let tag = name(cell) == "th" ? "th" : "td"
                        var attrs = ""
                        for a in ["colspan", "rowspan", "align"] {
                            if let v = attribute(cell, a) { attrs += " \(a)=\"\(esc(v))\"" }
                        }
                        out += "<\(tag)\(attrs)>\(inline(cell))</\(tag)>"
                    }
                    out += "</tr>\n"
                }
                return out + "</table>\n"
            case "title":
                return "<p class=\"subtitle\"><strong>\(titleText(e))</strong></p>\n"
            default:
                // Unknown block: keep its text.
                let t = inline(e)
                return t.isEmpty ? "" : "<p>\(t)</p>\n"
            }
        }

        mutating func inline(_ e: XMLElement) -> String {
            var out = ""
            for node in e.children ?? [] {
                guard let c = node as? XMLElement else {
                    if node.kind == .text { out += esc(node.stringValue ?? "") }
                    continue
                }
                switch name(c) {
                case "strong": out += "<strong>\(inline(c))</strong>"
                case "emphasis": out += "<em>\(inline(c))</em>"
                case "strikethrough": out += "<s>\(inline(c))</s>"
                case "sub": out += "<sub>\(inline(c))</sub>"
                case "sup": out += "<sup>\(inline(c))</sup>"
                case "code": out += "<code>\(inline(c))</code>"
                case "style": out += "<span>\(inline(c))</span>"
                case "a":
                    let href = attribute(c, "href") ?? ""
                    let isNote = attribute(c, "type") == "note" || (href.hasPrefix("#") && noteIDs.contains(String(href.dropFirst())))
                    let link = "<a href=\"\(esc(href))\">\(inline(c))</a>"
                    out += isNote ? "<sup>\(link)</sup>" : link
                case "image":
                    if let src = imageSource(attribute(c, "href")) { out += "<img src=\"\(esc(src))\" alt=\"\"/>" }
                default:
                    out += inline(c)
                }
            }
            return out
        }
    }
}
