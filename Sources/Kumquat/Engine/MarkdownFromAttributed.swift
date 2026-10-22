import AppKit

/// Converts an NSAttributedString (from RTF/DOCX/HTML/PDF import) into clean Markdown.
/// Headings are inferred from font size / weight relative to the body text, lists come from
/// NSTextList, tables from NSTextTableBlock, code from monospaced fonts, links from `.link`.
struct MarkdownFromAttributed {
    let attributed: NSAttributedString
    /// Name to use for images that have no file name.
    var imageNamer: ((NSTextAttachment, Int) -> String?)? = nil

    init(_ attributed: NSAttributedString) { self.attributed = attributed }

    func render() -> String {
        let ns = attributed.string as NSString
        let length = ns.length
        guard length > 0 else { return "" }
        let base = bodyFontSize()

        var blocks: [String] = []          // finished blocks, joined by blank lines
        var listBuffer: [String] = []
        var codeBuffer: [String] = []
        var tableRows: [[Int: String]] = []
        var currentTable: NSTextTable?
        var listCounters: [Int] = []
        var listIdentities: [ObjectIdentifier?] = []
        var imageIndex = 0

        func flushList() {
            if !listBuffer.isEmpty { blocks.append(listBuffer.joined(separator: "\n")); listBuffer = [] }
            listCounters = []; listIdentities = []
        }
        func appendListItem(level: Int, ordered: Bool, identity: ObjectIdentifier?, start: Int, text rawItem: String) {
            if listCounters.count > level + 1 {
                listCounters.removeLast(listCounters.count - level - 1)
                listIdentities.removeLast(listIdentities.count - level - 1)
            }
            while listCounters.count < level + 1 { listCounters.append(0); listIdentities.append(identity) }
            if listIdentities[level] != identity { listCounters[level] = 0; listIdentities[level] = identity }
            listCounters[level] += 1
            // Lists without an NSTextList carry their own numbers.
            let number = identity == nil ? start : listCounters[level] + max(0, start - 1)
            let marker = ordered ? "\(number)." : "-"
            var text = rawItem
            for task in ["☐ ", "☑ ", "☒ "] where text.hasPrefix(task) {
                text = (task == "☐ " ? "[ ] " : "[x] ") + text.dropFirst(task.count)
            }
            listBuffer.append(String(repeating: "    ", count: level) + marker + " " + text)
        }
        func flushCode() {
            if !codeBuffer.isEmpty {
                while codeBuffer.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { codeBuffer.removeLast() }
                blocks.append("```\n" + codeBuffer.joined(separator: "\n") + "\n```"); codeBuffer = []
            }
        }
        func flushTable() {
            guard !tableRows.isEmpty else { currentTable = nil; return }
            let cols = max(1, tableRows.map { ($0.keys.max() ?? 0) + 1 }.max() ?? 1)
            var lines: [String] = []
            for (r, row) in tableRows.enumerated() {
                let cells = (0..<cols).map { c -> String in
                    var cell = (row[c] ?? "").replacingOccurrences(of: "|", with: "\\|")
                    // Header cells are bold anyway.
                    if r == 0, cell.hasPrefix("**"), cell.hasSuffix("**"), cell.count > 4 { cell = String(cell.dropFirst(2).dropLast(2)) }
                    return cell
                }
                lines.append("| " + cells.joined(separator: " | ") + " |")
                if r == 0 { lines.append("|" + String(repeating: " --- |", count: cols)) }
            }
            blocks.append(lines.joined(separator: "\n"))
            tableRows = []
            currentTable = nil
        }

        var location = 0
        while location < length {
            let pr = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = pr.location + pr.length
            var content = pr
            while content.length > 0 {
                let last = ns.character(at: content.location + content.length - 1)
                if last == 0x0A || last == 0x0D || last == 0x2029 || last == 0x0C { content.length -= 1 } else { break }
            }
            let style = attributed.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
            let rawText = ns.substring(with: content)
            let isBlank = rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !rawText.contains("\u{FFFC}")

            // Tables
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                flushList(); flushCode()
                if currentTable !== cell.table { flushTable(); currentTable = cell.table }
                let text = inline(content, base: base, imageIndex: &imageIndex).trimmingCharacters(in: .whitespacesAndNewlines)
                while tableRows.count <= cell.startingRow { tableRows.append([:]) }
                let existing = tableRows[cell.startingRow][cell.startingColumn]
                tableRows[cell.startingRow][cell.startingColumn] = existing.map { $0.isEmpty ? text : (text.isEmpty ? $0 : $0 + "<br>" + text) } ?? text
                continue
            }
            if currentTable != nil { flushTable() }

            if isBlank {
                if !codeBuffer.isEmpty { codeBuffer.append(""); continue }
                flushList()
                continue
            }

            // Code blocks: every visible character in a monospaced font.
            if isMonospaced(content) && style?.textLists.isEmpty != false {
                flushList()
                codeBuffer.append(contentsOf: rawText.replacingOccurrences(of: "\u{2028}", with: "\n").components(separatedBy: "\n"))
                continue
            }
            flushCode()

            // Lists
            if let lists = style?.textLists, let list = lists.last {
                var stripped = content
                if let m = MarkdownToHTML.match(#"^\t?[^\t\n]{0,16}\t"#, rawText) {
                    let n = (m[0] as NSString).length
                    stripped = NSRange(location: content.location + n, length: content.length - n)
                }
                let text = inline(stripped, base: base, imageIndex: &imageIndex).trimmingCharacters(in: .whitespaces)
                appendListItem(level: lists.count - 1, ordered: Self.isOrdered(list), identity: ObjectIdentifier(list),
                               start: list.startingItemNumber, text: text)
                continue
            }
            // Lists whose markers are plain text ("\t•\tItem" from some DOCX writers, "• Item" from PDFs).
            if let m = MarkdownToHTML.match(#"^\t?([•◦▪‣·○■□●–]|\d{1,3}[.)]?)\t"#, rawText)
                ?? MarkdownToHTML.match(#"^\s*([•◦▪‣○■□●]|\d{1,3}[.)])[ \u00A0]+"#, rawText) {
                let n = (m[0] as NSString).length
                let stripped = NSRange(location: content.location + n, length: content.length - n)
                let indent = style?.headIndent ?? 0
                var level = max(0, min(8, Int((indent / 36).rounded()) - 1))
                if indent == 0 { level = ["◦", "○"].contains(m[1]) ? 1 : (["▪", "■"].contains(m[1]) ? 2 : 0) }
                let ordered = m[1].first?.isNumber == true
                let text = inline(stripped, base: base, imageIndex: &imageIndex).trimmingCharacters(in: .whitespaces)
                appendListItem(level: level, ordered: ordered, identity: nil, start: ordered ? Int(m[1].filter(\.isNumber)) ?? 1 : 1, text: text)
                continue
            }
            flushList()

            // Headings
            let text = inline(content, base: base, imageIndex: &imageIndex, suppressBold: true)
            if let level = headingLevel(content, base: base, text: rawText) {
                let plain = text.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\n", with: " ")
                blocks.append(String(repeating: "#", count: level) + " " + plain)
                continue
            }
            let body = inline(content, base: base, imageIndex: &imageIndex).trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }
            // Horizontal-rule-like paragraphs
            if MarkdownToHTML.match(#"^[-_*—–]{3,}$"#, body) != nil { blocks.append("---"); continue }
            blocks.append(body)
        }
        flushTable(); flushList(); flushCode()
        var out = blocks.joined(separator: "\n\n")
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Analysis

    private func bodyFontSize() -> CGFloat {
        var hist: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let f = value as? NSFont else { return }
            hist[(f.pointSize * 2).rounded() / 2, default: 0] += range.length
        }
        return hist.max { $0.value < $1.value }?.key ?? 12
    }

    private func fonts(in range: NSRange) -> [NSFont] {
        var result: [NSFont] = []
        let ns = attributed.string as NSString
        attributed.enumerateAttribute(.font, in: range) { value, r, _ in
            let s = ns.substring(with: r)
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let f = value as? NSFont { result.append(f) }
        }
        return result
    }

    private func isMonospaced(_ range: NSRange) -> Bool {
        let fs = fonts(in: range)
        return !fs.isEmpty && fs.allSatisfy(Self.isMono)
    }

    private func headingLevel(_ range: NSRange, base: CGFloat, text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160, !trimmed.contains("\u{FFFC}") else { return nil }
        let fs = fonts(in: range)
        guard !fs.isEmpty else { return nil }
        let minSize = fs.map(\.pointSize).min()!
        let allBold = fs.allSatisfy(Self.isBold)
        let ratio = minSize / max(base, 1)
        if ratio >= 1.75 { return 1 }
        if ratio >= 1.4 { return 2 }
        if ratio >= 1.15 { return 3 }
        if ratio >= 1.05 && allBold { return 4 }
        return nil
    }

    static func isOrdered(_ list: NSTextList) -> Bool {
        let f = list.markerFormat.rawValue.lowercased()
        return f.contains("decimal") || f.contains("roman") || f.contains("alpha") || f.contains("octal")
    }

    static func isMono(_ f: NSFont) -> Bool {
        if f.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
        let n = f.fontName.lowercased()
        return n.contains("mono") || n.contains("menlo") || n.contains("courier") || n.contains("consol") || n.contains("monaco")
    }

    static func isBold(_ f: NSFont) -> Bool {
        if f.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let n = f.fontName.lowercased()
        return n.contains("bold") || n.contains("black") || n.contains("heavy") || n.contains("semibold")
    }

    static func isItalic(_ f: NSFont) -> Bool {
        if f.fontDescriptor.symbolicTraits.contains(.italic) { return true }
        let n = f.fontName.lowercased()
        return n.contains("italic") || n.contains("oblique")
    }

    // MARK: - Inline

    private struct Run { var text: String; var bold: Bool; var italic: Bool; var code: Bool; var strike: Bool; var link: String? }

    private func inline(_ range: NSRange, base: CGFloat, imageIndex: inout Int, suppressBold: Bool = false) -> String {
        guard range.length > 0 else { return "" }
        var runs: [Run] = []
        let ns = attributed.string as NSString
        var idx = imageIndex
        attributed.enumerateAttributes(in: range) { attrs, r, _ in
            var s = ns.substring(with: r)
            if let att = attrs[.attachment] as? NSTextAttachment, s.contains("\u{FFFC}") {
                idx += 1
                let name = imageNamer?(att, idx) ?? att.fileWrapper?.preferredFilename ?? att.fileWrapper?.filename
                if let name {
                    let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                    runs.append(Run(text: "![\(Self.escape(((name as NSString).lastPathComponent as NSString).deletingPathExtension))](\(enc))", bold: false, italic: false, code: false, strike: false, link: "\u{0}raw"))
                }
                s = s.replacingOccurrences(of: "\u{FFFC}", with: "")
                if s.isEmpty { return }
            }
            let font = attrs[.font] as? NSFont
            let link: String? = {
                if let u = attrs[.link] as? URL { return u.absoluteString }
                if let str = attrs[.link] as? String { return str }
                return nil
            }()
            let strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
            runs.append(Run(text: s,
                            bold: !suppressBold && (font.map(Self.isBold) ?? false),
                            italic: font.map(Self.isItalic) ?? false,
                            code: font.map(Self.isMono) ?? false,
                            strike: strike, link: link))
        }
        imageIndex = idx

        // Merge adjacent runs with identical styling.
        var merged: [Run] = []
        for r in runs {
            if var last = merged.last, last.link != "\u{0}raw", r.link != "\u{0}raw",
               last.bold == r.bold, last.italic == r.italic, last.code == r.code, last.strike == r.strike, last.link == r.link {
                last.text += r.text
                merged[merged.count - 1] = last
            } else { merged.append(r) }
        }

        var out = ""
        for r in merged {
            if r.link == "\u{0}raw" { out += r.text; continue }
            let text = r.text.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{00A0}", with: " ")
            // Keep surrounding whitespace outside of emphasis markers.
            let lead = String(text.prefix(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
            let rest = text.dropFirst(lead.count)
            let trail = String(rest.reversed().prefix(while: { $0 == " " || $0 == "\t" || $0 == "\n" }).reversed())
            let core = String(rest.dropLast(trail.count))
            if core.isEmpty { out += text.replacingOccurrences(of: "\t", with: " "); continue }
            var piece: String
            if r.code && r.link == nil {
                let fence = core.contains("`") ? "`` " : "`"
                piece = fence + core + (fence == "`" ? "`" : " ``")
            } else {
                piece = Self.escape(core)
                if r.strike { piece = "~~\(piece)~~" }
                if r.italic { piece = "*\(piece)*" }
                if r.bold { piece = "**\(piece)**" }
            }
            if let link = r.link {
                let label = piece
                piece = link == core ? "<\(link)>" : "[\(label)](\(link.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ")", with: "%29")))"
            }
            out += lead + piece + trail
        }
        // Soft line breaks inside a paragraph become hard breaks.
        out = out.replacingOccurrences(of: "\n", with: "  \n")
        out = out.replacingOccurrences(of: "\t", with: " ")
        return out
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\`*_[]<>".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        // Avoid accidental block syntax at the start of a paragraph.
        if let first = out.first, "#>+".contains(first) { out = "\\" + out }
        if MarkdownToHTML.match(#"^\d+[.)]\s"#, out) != nil, let dot = out.firstIndex(where: { $0 == "." || $0 == ")" }) {
            out.insert("\\", at: dot)
        }
        if out.hasPrefix("- ") { out = "\\" + out }
        return out
    }
}
