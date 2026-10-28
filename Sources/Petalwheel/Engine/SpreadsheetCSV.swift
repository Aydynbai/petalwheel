import Foundation

/// A cell value plus how it should be typed when written to xlsx.
struct SpreadsheetCell: Equatable {
    enum Kind: Equatable { case text, number, boolean, auto }
    var value: String
    var kind: Kind = .auto

    init(_ value: String, kind: Kind = .auto) { self.value = value; self.kind = kind }

    /// Whether this cell should be stored as a number in xlsx.
    var isNumeric: Bool {
        switch kind {
        case .number: return Double(value) != nil
        case .auto: return SpreadsheetCell.looksNumeric(value)
        default: return false
        }
    }

    /// Plain decimal numbers only: no leading zeros ("007" stays text), no thousands separators,
    /// and ≤ 15 significant digits so IDs and phone numbers don't lose precision.
    static func looksNumeric(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 20,
              MarkdownToHTML.match(#"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]{1,3})?$"#, s) != nil else { return false }
        let digits = s.split(whereSeparator: { $0 == "e" || $0 == "E" })[0].filter(\.isNumber)
        return digits.count <= 15 && Double(s) != nil
    }
}

struct SpreadsheetSheet {
    var name: String
    var rows: [[SpreadsheetCell]]

    /// Removes trailing empty cells and rows.
    mutating func trim() {
        rows = rows.map { row in
            var r = row
            while let last = r.last, last.value.isEmpty { r.removeLast() }
            return r
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
    }

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// First row looks like a header: all text, and the sheet has more rows.
    var hasHeaderRow: Bool {
        guard rows.count > 1, let first = rows.first, !first.isEmpty else { return false }
        return first.allSatisfy { !$0.value.isEmpty && !$0.isNumeric }
    }
}

/// RFC 4180 CSV / TSV reading and writing.
enum SpreadsheetCSV {
    /// Parses delimited text. `delimiter == nil` auto-detects among `,` `;` and tab.
    static func parse(_ rawText: String, delimiter: Character? = nil) -> [[String]] {
        var text = rawText
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let delim = delimiter ?? detectDelimiter(text)
        let d = delim.unicodeScalars.first!
        let quote: Unicode.Scalar = "\""

        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldStarted = false   // a quoted field was opened for this cell
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        func endField() { row.append(String(field)); field = String.UnicodeScalarView(); fieldStarted = false }
        func endRow() { endField(); rows.append(row); row = [] }

        while i < n {
            let c = scalars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < n && scalars[i + 1] == quote { field.append(quote); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1; continue
            }
            if c == quote && field.isEmpty && !fieldStarted {
                inQuotes = true; fieldStarted = true; i += 1; continue
            }
            if c == d { endField(); i += 1; continue }
            if c == "\r" {
                endRow()
                if i + 1 < n && scalars[i + 1] == "\n" { i += 2 } else { i += 1 }
                continue
            }
            if c == "\n" { endRow(); i += 1; continue }
            field.append(c); i += 1
        }
        if !field.isEmpty || !row.isEmpty || fieldStarted { endRow() }
        return rows
    }

    /// Picks the delimiter that occurs most consistently across the first lines (outside quotes).
    static func detectDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t", "|"]
        var lines: [[Character: Int]] = []
        var counts: [Character: Int] = [:]
        var inQuotes = false
        for ch in text.prefix(64 * 1024) {
            if ch == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                if !counts.isEmpty || !lines.isEmpty { lines.append(counts) }
                counts = [:]
                if lines.count >= 20 { break }
                continue
            }
            if candidates.contains(ch) { counts[ch, default: 0] += 1 }
        }
        if !counts.isEmpty { lines.append(counts) }
        var best: Character = ","
        var bestScore = 0.0
        for c in candidates {
            let per = lines.map { $0[c] ?? 0 }
            guard let first = per.first, first > 0 else { continue }
            let consistent = per.filter { $0 == first }.count
            let score = Double(consistent) / Double(per.count) * 100 + Double(min(first, 50))
            if score > bestScore { bestScore = score; best = c }
        }
        return best
    }

    static func write(_ rows: [[String]], delimiter: Character) -> String {
        var out = ""
        for row in rows {
            let fields = row.map { field -> String in
                if delimiter == "\t" {
                    // TSV has no quoting: flatten tabs/newlines.
                    return field.replacingOccurrences(of: "\r\n", with: " ")
                        .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                }
                let needsQuotes = field.contains(delimiter) || field.contains("\"") || field.contains("\n")
                    || field.contains("\r") || field.hasPrefix(" ") || field.hasSuffix(" ")
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }
            out += fields.joined(separator: String(delimiter)) + (delimiter == "\t" ? "\n" : "\r\n")
        }
        return out
    }
}
