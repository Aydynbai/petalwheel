import Foundation

/// A compact, dependency-free Markdown → HTML converter covering CommonMark/GFM essentials:
/// ATX + setext headings, paragraphs, hard breaks, emphasis/strong/strikethrough, code spans,
/// fenced + indented code, (nested) ordered/unordered/task lists, blockquotes, horizontal rules,
/// links/images (inline, reference, autolinks, bare URLs), GFM tables and raw HTML pass-through.
struct MarkdownToHTML {
    private var references: [String: (url: String, title: String?)] = [:]
    /// Emit table-based markup for code blocks, quotes and rules: Cocoa's HTML importer ignores
    /// block margins/borders but renders table cells faithfully (used for PDF/DOCX/RTF output).
    var forImport = false

    init(forImport: Bool = false) { self.forImport = forImport }

    /// Full standalone HTML document with the default stylesheet.
    static func document(markdown: String, title: String, baseURL: URL? = nil, forImport: Bool = false) -> String {
        let body = MarkdownToHTML(forImport: forImport).render(markdown)
        var head = "<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        head += "<title>\(escapeHTML(title))</title>\n"
        if let baseURL { head += "<base href=\"\(escapeAttribute(baseURL.absoluteString))\">\n" }
        head += "<style>\n\(defaultCSS)\n</style>\n"
        return "<!DOCTYPE html>\n<html>\n<head>\n\(head)</head>\n<body>\n\(body)</body>\n</html>\n"
    }

    static let defaultCSS = """
    body { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 12pt; line-height: 1.45; color: #1d1d1f; max-width: 46em; margin: 2em auto; padding: 0 1em; }
    h1, h2, h3, h4, h5, h6 { font-weight: bold; line-height: 1.25; margin-top: 14pt; margin-bottom: 6pt; }
    h1 { font-size: 24pt; } h2 { font-size: 19pt; } h3 { font-size: 15pt; } h4 { font-size: 13pt; } h5 { font-size: 12pt; } h6 { font-size: 11pt; color: #555555; }
    p { margin-top: 0; margin-bottom: 9pt; }
    a { color: #c2410c; }
    code { font-family: Menlo, Monaco, monospace; font-size: 10.5pt; background-color: #f2f2f4; }
    pre { font-family: Menlo, Monaco, monospace; font-size: 10pt; line-height: 1.35; background-color: #f2f2f4; padding: 8pt; margin-top: 0; margin-bottom: 10pt; white-space: pre-wrap; }
    pre code { background-color: transparent; font-size: 10pt; }
    blockquote { margin: 0 0 10pt 0; padding-left: 12pt; color: #555555; font-style: italic; border-left: 3pt solid #e4a07a; }
    table { border-collapse: collapse; margin-bottom: 12pt; }
    th, td { border: 1px solid #c8c8cc; padding: 4pt 8pt; text-align: left; vertical-align: top; }
    th { background-color: #f2f2f4; font-weight: bold; }
    hr { border: 0; border-top: 1px solid #c8c8cc; margin: 14pt 0; }
    img { max-width: 100%; }
    ul, ol { margin-top: 0; margin-bottom: 9pt; padding-left: 20pt; }
    li { margin: 2pt 0; }
    table.kq-code, table.kq-quote, table.kq-rule { border-collapse: collapse; width: 100%; margin: 0; }
    table.kq-code td { background-color: #f2f2f4; padding: 8pt; border: none; }
    table.kq-code pre { margin: 0; padding: 0; background-color: transparent; }
    table.kq-quote td { border: none; border-left: 3pt solid #e4a07a; padding: 0 0 0 10pt; color: #555555; }
    table.kq-quote p { margin-bottom: 4pt; }
    table.kq-rule td { border: none; border-top: 1px solid #c8c8cc; padding: 0; font-size: 2pt; }
    p.kq-gap { font-size: 5pt; line-height: 1; margin: 0; }
    """

    // MARK: - Blocks

    func render(_ markdown: String) -> String {
        var copy = self
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var lines = text.components(separatedBy: "\n").map(Self.expandTabs)
        lines = copy.extractReferences(lines)
        return copy.renderBlocks(lines)
    }

    private static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var out = "", col = 0
        for ch in line {
            if ch == "\t" {
                let n = 4 - (col % 4)
                out += String(repeating: " ", count: n); col += n
            } else { out.append(ch); col += 1 }
        }
        return out
    }

    private mutating func extractReferences(_ lines: [String]) -> [String] {
        var out: [String] = []
        var inFence = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let m = Self.match(#"^ {0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s+["'(](.*)["')])?\s*$"#, line) {
                references[m[1].lowercased()] = (m[2], m[3].isEmpty ? nil : m[3])
                continue
            }
            out.append(line)
        }
        return out
    }

    private func renderBlocks(_ lines: [String]) -> String {
        var html = ""
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            let indent = Self.indentation(line)

            // Fenced code
            if indent < 4, let fence = Self.fenceStart(trimmed) {
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence.marker), t.allSatisfy({ $0 == fence.marker.first }) { i += 1; break }
                    code.append(Self.removeIndent(lines[i], upTo: indent))
                    i += 1
                }
                let cls = fence.lang.isEmpty ? "" : " class=\"language-\(Self.escapeAttribute(fence.lang))\""
                html += wrapCode("<pre><code\(cls)>\(Self.escapeHTML(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            // Indented code
            if indent >= 4 {
                var code: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty {
                        code.append(""); i += 1; continue
                    }
                    if Self.indentation(l) < 4 { break }
                    code.append(String(l.dropFirst(4))); i += 1
                }
                while code.last == "" { code.removeLast() }
                html += wrapCode("<pre><code>\(Self.escapeHTML(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            // ATX heading
            if let m = Self.match(#"^ {0,3}(#{1,6})(?:\s+(.*?))?(?:\s+#+)?\s*$"#, line) {
                let level = m[1].count
                html += "<h\(level)>\(renderInline(m[2]))</h\(level)>\n"
                i += 1; continue
            }
            // Horizontal rule
            if Self.isRule(line) {
                html += forImport ? "<p class=\"kq-gap\">&nbsp;</p>\n<table class=\"kq-rule\"><tr><td>&nbsp;</td></tr></table>\n" : "<hr>\n"
                i += 1; continue
            }
            // Blockquote
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var rest = String(t.dropFirst())
                        if rest.hasPrefix(" ") { rest.removeFirst() }
                        inner.append(rest)
                    } else if !t.isEmpty, let last = inner.last, !last.trimmingCharacters(in: .whitespaces).isEmpty,
                              !Self.startsBlock(lines[i]) {
                        inner.append(t)          // lazy continuation
                    } else { break }
                    i += 1
                }
                if forImport {
                    html += "<table class=\"kq-quote\"><tr><td>\n\(renderBlocks(inner))</td></tr></table>\n<p class=\"kq-gap\">&nbsp;</p>\n"
                } else {
                    html += "<blockquote>\n\(renderBlocks(inner))</blockquote>\n"
                }
                continue
            }
            // List
            if Self.listMarker(line) != nil {
                let (listHTML, next) = renderList(lines, from: i)
                html += listHTML
                i = next
                continue
            }
            // Table
            if i + 1 < lines.count, line.contains("|"), Self.isTableDelimiter(lines[i + 1]) {
                let header = Self.splitRow(line)
                let aligns = Self.splitRow(lines[i + 1]).map { cell -> String in
                    let c = cell.trimmingCharacters(in: .whitespaces)
                    if c.hasPrefix(":") && c.hasSuffix(":") { return "center" }
                    if c.hasSuffix(":") { return "right" }
                    return ""
                }
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty || !l.contains("|") { break }
                    rows.append(Self.splitRow(l)); i += 1
                }
                func cell(_ tag: String, _ text: String, _ col: Int) -> String {
                    let a = col < aligns.count && !aligns[col].isEmpty ? " style=\"text-align: \(aligns[col])\"" : ""
                    return "<\(tag)\(a)>\(renderInline(text))</\(tag)>"
                }
                html += "<table>\n<thead>\n<tr>" + header.enumerated().map { cell("th", $0.element, $0.offset) }.joined() + "</tr>\n</thead>\n<tbody>\n"
                for row in rows {
                    var cells = row
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    html += "<tr>" + cells.prefix(max(header.count, 1)).enumerated().map { cell("td", $0.element, $0.offset) }.joined() + "</tr>\n"
                }
                html += "</tbody>\n</table>\n"
                continue
            }
            // Raw HTML block
            if Self.match(#"^ {0,3}<(/?(?:div|table|thead|tbody|tr|td|th|p|pre|section|article|aside|header|footer|nav|figure|figcaption|details|summary|center|dl|dt|dd|ul|ol|li|h[1-6]|hr|br|img|iframe|video|audio|style|script)\b|!--)"#, line.lowercased()) != nil {
                var block: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    block.append(lines[i]); i += 1
                }
                html += block.joined(separator: "\n") + "\n"
                continue
            }
            // Paragraph (with setext heading detection)
            var para: [String] = [line]
            i += 1
            var setext = 0
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if Self.indentation(l) < 4 {
                    if Self.match(#"^=+$"#, t) != nil { setext = 1; i += 1; break }
                    if Self.match(#"^-+$"#, t) != nil { setext = 2; i += 1; break }
                }
                if Self.startsBlock(l) { break }
                if i + 1 < lines.count, l.contains("|"), Self.isTableDelimiter(lines[i + 1]) { break }
                para.append(l); i += 1
            }
            if setext > 0 {
                let text = para.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                html += "<h\(setext)>\(renderInline(text))</h\(setext)>\n"
            } else {
                html += "<p>\(renderParagraph(para))</p>\n"
            }
        }
        return html
    }

    private func wrapCode(_ pre: String) -> String {
        forImport ? "<table class=\"kq-code\"><tr><td>\(pre)</td></tr></table>\n<p class=\"kq-gap\">&nbsp;</p>\n" : pre + "\n"
    }

    private func renderParagraph(_ lines: [String]) -> String {
        var parts: [String] = []
        for (n, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var hardBreak = false
            if n < lines.count - 1 {
                if raw.hasSuffix("  ") { hardBreak = true }
                else if line.hasSuffix("\\") { hardBreak = true; line.removeLast() }
            }
            parts.append(renderInline(line) + (hardBreak ? "<br>" : ""))
        }
        return parts.joined(separator: "\n")
    }

    private struct Marker { let indent: Int; let ordered: Bool; let start: Int; let contentIndent: Int; let bulletChar: Character }

    private static func listMarker(_ line: String) -> Marker? {
        guard let m = match(#"^( {0,3}|\s*)([-*+]|\d{1,9}[.)])( +|$)"#, line) else { return nil }
        if isRule(line) { return nil }
        let indent = m[1].count
        let marker = m[2]
        let spaces = m[3].count
        let ordered = marker.first!.isNumber
        let contentIndent = indent + marker.count + (spaces == 0 || spaces > 4 ? 1 : spaces)
        return Marker(indent: indent, ordered: ordered, start: ordered ? Int(marker.dropLast()) ?? 1 : 1,
                      contentIndent: contentIndent, bulletChar: marker.last!)
    }

    private func renderList(_ lines: [String], from startIndex: Int) -> (String, Int) {
        guard let first = Self.listMarker(lines[startIndex]) else { return ("", startIndex + 1) }
        var items: [[String]] = []
        var loose = false
        var i = startIndex
        var current: [String] = []
        var currentMarker = first
        var sawBlank = false

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                sawBlank = true
                current.append("")
                i += 1
                continue
            }
            let indent = Self.indentation(line)
            if let m = Self.listMarker(line), m.indent < currentMarker.contentIndent, abs(m.indent - first.indent) <= 3 || m.indent <= first.indent {
                // Sibling item (same list type) or end of list.
                if m.ordered != first.ordered || (!m.ordered && m.bulletChar != first.bulletChar) { break }
                if i != startIndex {
                    if sawBlank { loose = true }
                    items.append(current); current = []
                }
                sawBlank = false
                currentMarker = m
                let content = String(line.dropFirst(min(m.contentIndent, line.count)))
                current.append(content)
                i += 1
                continue
            }
            if indent >= currentMarker.contentIndent || (indent >= 2 && indent > currentMarker.indent) {
                if sawBlank, current.contains(where: { !$0.isEmpty }) {
                    // Blank line followed by indented content: loose only if it's a new paragraph.
                    if Self.listMarker(line) == nil { loose = true }
                }
                sawBlank = false
                current.append(Self.removeIndent(line, upTo: currentMarker.contentIndent))
                i += 1
                continue
            }
            if !sawBlank, !Self.startsBlock(line) {
                current.append(t)  // lazy continuation
                i += 1
                continue
            }
            break
        }
        items.append(current)
        while let last = items.last?.last, last.isEmpty { items[items.count - 1].removeLast() }

        let tag = first.ordered ? "ol" : "ul"
        let startAttr = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        var html = "<\(tag)\(startAttr)>\n"
        for var item in items {
            while item.last?.isEmpty == true { item.removeLast() }
            var prefix = ""
            if let firstLine = item.first, let m = Self.match(#"^\[([ xX])\]\s+(.*)$"#, firstLine) {
                prefix = m[1] == " " ? "☐ " : "☑ "
                item[0] = m[2]
            }
            var inner = renderBlocks(item)
            if !loose {
                // Tight list: unwrap paragraphs.
                inner = inner.replacingOccurrences(of: "<p>", with: "").replacingOccurrences(of: "</p>\n", with: "\n")
            }
            inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            html += "<li>\(prefix)\(inner)</li>\n"
        }
        html += "</\(tag)>\n"
        return (html, i)
    }

    // MARK: - Block helpers

    private static func indentation(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }

    private static func removeIndent(_ line: String, upTo n: Int) -> String {
        let k = min(n, indentation(line))
        return String(line.dropFirst(k))
    }

    private static func fenceStart(_ trimmed: String) -> (marker: String, lang: String)? {
        for ch in ["`", "~"] {
            let run = trimmed.prefix(while: { String($0) == ch })
            if run.count >= 3 {
                let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
                if ch == "`" && info.contains("`") { return nil }
                return (String(run), String(info.split(separator: " ").first ?? ""))
            }
        }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        match(#"^ {0,3}([-*_])(\s*\1){2,}\s*$"#, line) != nil
    }

    private static func startsBlock(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if indentation(line) >= 4 { return false }
        if t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~") { return true }
        if match(#"^#{1,6}(\s|$)"#, t) != nil { return true }
        if isRule(line) { return true }
        if let m = listMarker(line) {
            // An ordered list can interrupt a paragraph only when it starts at 1.
            return !m.ordered || m.start == 1
        }
        return false
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return match(#"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$"#, t) != nil
    }

    private static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cur = ""
        var inCode = false
        var prev: Character = " "
        for ch in t {
            if ch == "`" { inCode.toggle() }
            if ch == "|" && prev != "\\" && !inCode {
                cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else if ch == "|" && prev == "\\" {
                cur.removeLast(); cur.append(ch)
            } else { cur.append(ch) }
            prev = ch
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Inlines

    func renderInline(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        var buffer = ""

        func flushText() {
            if !buffer.isEmpty { out += Self.autolinkBareURLs(Self.escapeHTML(buffer)); buffer = "" }
        }

        while i < chars.count {
            let c = chars[i]
            // Backslash escapes
            if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|<>~\"'".contains(chars[i + 1]) {
                buffer.append(chars[i + 1]); i += 2; continue
            }
            // Code spans
            if c == "`" {
                var n = 0
                while i + n < chars.count && chars[i + n] == "`" { n += 1 }
                if let close = Self.findRun(chars, of: "`", length: n, from: i + n) {
                    flushText()
                    var code = String(chars[(i + n)..<close])
                    if code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    out += "<code>\(Self.escapeHTML(code))</code>"
                    i = close + n
                    continue
                }
                buffer += String(repeating: "`", count: n); i += n; continue
            }
            // Autolinks <http://...> and raw inline HTML
            if c == "<" {
                if let end = chars[i...].firstIndex(of: ">") {
                    let inner = String(chars[(i + 1)..<end])
                    if Self.match(#"^(https?|ftp|mailto):[^\s<>]+$"#, inner) != nil || Self.match(#"^[^\s@<>]+@[^\s@<>]+\.[a-z]+$"#, inner) != nil {
                        flushText()
                        let href = inner.contains(":") ? inner : "mailto:" + inner
                        out += "<a href=\"\(Self.escapeAttribute(href))\">\(Self.escapeHTML(inner))</a>"
                        i = end + 1; continue
                    }
                    if Self.match(#"^/?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?$"#, inner) != nil || inner.hasPrefix("!--") {
                        flushText()
                        out += "<" + inner + ">"
                        i = end + 1; continue
                    }
                }
            }
            // Images and links
            if c == "!" && i + 1 < chars.count && chars[i + 1] == "[" || c == "[" {
                let isImage = c == "!"
                let open = isImage ? i + 1 : i
                if let (label, dest, title, next) = parseLink(chars, at: open) {
                    flushText()
                    let t = title.map { " title=\"\(Self.escapeAttribute($0))\"" } ?? ""
                    if isImage {
                        out += "<img src=\"\(Self.escapeAttribute(dest))\" alt=\"\(Self.escapeAttribute(Self.plainText(label)))\"\(t)>"
                    } else {
                        out += "<a href=\"\(Self.escapeAttribute(dest))\"\(t)>\(renderInline(label))</a>"
                    }
                    i = next
                    continue
                }
            }
            // Strikethrough
            if c == "~", i + 1 < chars.count, chars[i + 1] == "~",
               let close = Self.findRun(chars, of: "~", length: 2, from: i + 2), close > i + 2 {
                flushText()
                out += "<del>\(renderInline(String(chars[(i + 2)..<close])))</del>"
                i = close + 2
                continue
            }
            // Emphasis
            if c == "*" || c == "_" {
                var n = 0
                while i + n < chars.count && chars[i + n] == c { n += 1 }
                let prevChar: Character? = i > 0 ? chars[i - 1] : nil
                let nextChar: Character? = i + n < chars.count ? chars[i + n] : nil
                let leftFlanking = nextChar.map { !$0.isWhitespace } ?? false
                let intraword = c == "_" && (prevChar.map { $0.isLetter || $0.isNumber } ?? false)
                if leftFlanking && !intraword {
                    var handled = false
                    for len in stride(from: min(n, 3), through: 1, by: -1) {
                        if let close = findEmphasisClose(chars, char: c, length: len, from: i + len) {
                            flushText()
                            if n > len { buffer += String(repeating: String(c), count: n - len); flushText() }
                            let inner = renderInline(String(chars[(i + n)..<close]))
                            switch len {
                            case 3: out += "<strong><em>\(inner)</em></strong>"
                            case 2: out += "<strong>\(inner)</strong>"
                            default: out += "<em>\(inner)</em>"
                            }
                            i = close + len
                            handled = true
                            break
                        }
                    }
                    if handled { continue }
                }
                buffer += String(repeating: String(c), count: n); i += n; continue
            }
            buffer.append(c)
            i += 1
        }
        flushText()
        return out
    }

    private func findEmphasisClose(_ chars: [Character], char: Character, length: Int, from start: Int) -> Int? {
        var j = start
        var depthBracket = 0
        while j < chars.count {
            let ch = chars[j]
            if ch == "\\" { j += 2; continue }
            if ch == "`" {
                var n = 0
                while j + n < chars.count && chars[j + n] == "`" { n += 1 }
                if let close = Self.findRun(chars, of: "`", length: n, from: j + n) { j = close + n; continue }
                j += n; continue
            }
            if ch == "[" { depthBracket += 1 }
            if ch == "]" { depthBracket = max(0, depthBracket - 1) }
            if ch == char {
                var n = 0
                while j + n < chars.count && chars[j + n] == char { n += 1 }
                let prev = chars[j - 1]
                let after: Character? = j + n < chars.count ? chars[j + n] : nil
                let rightFlanking = !prev.isWhitespace && j > start
                let intraword = char == "_" && (after.map { $0.isLetter || $0.isNumber } ?? false)
                if rightFlanking && !intraword && n >= length && depthBracket == 0 {
                    // Use the last `length` delimiters of the run when it's longer (e.g. **bold *it***).
                    return j + (n - length)
                }
                j += n
                continue
            }
            j += 1
        }
        return nil
    }

    private func parseLink(_ chars: [Character], at open: Int) -> (String, String, String?, Int)? {
        // Find matching ]
        var depth = 0
        var j = open
        var close: Int?
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "`" {
                var n = 0
                while j + n < chars.count && chars[j + n] == "`" { n += 1 }
                if let c = Self.findRun(chars, of: "`", length: n, from: j + n) { j = c + n; continue }
            }
            if chars[j] == "[" { depth += 1 }
            if chars[j] == "]" { depth -= 1; if depth == 0 { close = j; break } }
            j += 1
        }
        guard let close else { return nil }
        let label = String(chars[(open + 1)..<close])
        let after = close + 1
        if after < chars.count && chars[after] == "(" {
            // Inline destination, allowing balanced parens.
            var k = after + 1
            var parens = 1
            while k < chars.count {
                if chars[k] == "\\" { k += 2; continue }
                if chars[k] == "(" { parens += 1 }
                if chars[k] == ")" { parens -= 1; if parens == 0 { break } }
                k += 1
            }
            guard k < chars.count else { return nil }
            let inside = String(chars[(after + 1)..<k]).trimmingCharacters(in: .whitespaces)
            var dest = inside
            var title: String?
            if let m = Self.match(#"^<([^>]*)>(?:\s+["'(](.*)["')])?$"#, inside) {
                dest = m[1]; title = m[2].isEmpty ? nil : m[2]
            } else if let m = Self.match(#"^(\S+)\s+["'(](.*)["')]$"#, inside) {
                dest = m[1]; title = m[2]
            }
            return (label, dest, title, k + 1)
        }
        // Reference links: [text][ref], [text][], [ref]
        var refKey = label.lowercased()
        var next = after
        if after < chars.count && chars[after] == "[" {
            if let end = chars[after...].firstIndex(of: "]") {
                let key = String(chars[(after + 1)..<end])
                if !key.isEmpty { refKey = key.lowercased() }
                next = end + 1
            }
        }
        if let ref = references[refKey] { return (label, ref.url, ref.title, next) }
        return nil
    }

    private static func findRun(_ chars: [Character], of ch: Character, length: Int, from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == ch {
                var n = 0
                while j + n < chars.count && chars[j + n] == ch { n += 1 }
                if n == length { return j }
                j += n
            } else { j += 1 }
        }
        return nil
    }

    private static func autolinkBareURLs(_ escaped: String) -> String {
        guard escaped.contains("http") || escaped.contains("www.") else { return escaped }
        let pattern = #"(?<![\w"=/])((?:https?://|www\.)[^\s<]*[^\s<.,;:!?)\]'"])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return escaped }
        let ns = escaped as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: escaped, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let url = ns.substring(with: m.range)
            let href = url.hasPrefix("www.") ? "http://" + url : url
            out += "<a href=\"\(href)\">\(url)</a>"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func plainText(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: #"[*_`~\[\]]"#, with: "", options: .regularExpression)
    }

    // MARK: - Utilities

    static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func escapeAttribute(_ s: String) -> String {
        escapeHTML(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Returns capture groups (index 0 = whole match; missing groups = "").
    static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = MarkdownRegexCache.regex(pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { idx in
            let r = m.range(at: idx)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

enum MarkdownRegexCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[pattern] { return r }
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = r
        return r
    }
}
