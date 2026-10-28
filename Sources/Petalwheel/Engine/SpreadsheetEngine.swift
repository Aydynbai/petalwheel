import Foundation

/// csv / tsv / xlsx → xlsx / csv / tsv / html.
struct SpreadsheetEngine: ConversionEngine {
    static let sources: Set<FileFormat> = [.csv, .tsv, .xlsx]
    static let targets: Set<FileFormat> = [.xlsx, .csv, .tsv, .html]

    init() {}

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        Self.sources.contains(source) && Self.targets.contains(target)
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw PetalwheelError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        progress(0.05)
        let baseName = source.deletingPathExtension().lastPathComponent
        let sheets = try await Self.load(source, format: from)
        progress(0.5)
        try Task.checkCancellation()

        switch target {
        case .xlsx:
            let out = OutputNaming.url(for: source, ext: "xlsx")
            try await SpreadsheetXLSX.write(sheets, to: out)
            progress(1)
            return [out]
        case .csv, .tsv:
            let delimiter: Character = target == .csv ? "," : "\t"
            var outputs: [URL] = []
            for (i, sheet) in sheets.enumerated() {
                let out: URL
                if sheets.count == 1 {
                    out = OutputNaming.url(for: source, ext: target.rawValue)
                } else {
                    out = OutputNaming.url(named: "\(baseName) - \(Self.fileSafe(sheet.name))", ext: target.rawValue,
                                           in: source.deletingLastPathComponent())
                }
                let text = SpreadsheetCSV.write(sheet.rows.map { $0.map(\.value) }, delimiter: delimiter)
                // UTF-8 BOM so Excel detects the encoding (non-ASCII text stays readable).
                var data = Data([0xEF, 0xBB, 0xBF])
                data.append(Data(text.utf8))
                try data.write(to: out)
                outputs.append(out)
                progress(0.5 + 0.5 * Double(i + 1) / Double(sheets.count))
            }
            return outputs
        case .html:
            let out = OutputNaming.url(for: source, ext: "html")
            try Self.html(sheets, title: baseName).write(to: out, atomically: true, encoding: .utf8)
            progress(1)
            return [out]
        default:
            throw PetalwheelError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
    }

    static func load(_ source: URL, format: FileFormat) async throws -> [SpreadsheetSheet] {
        let name = source.deletingPathExtension().lastPathComponent
        switch format {
        case .xlsx:
            return try await SpreadsheetXLSX.read(source)
        case .csv, .tsv:
            let text = try DocumentTextDecoder.decode(contentsOf: source)
            let rows = SpreadsheetCSV.parse(text, delimiter: format == .tsv ? "\t" : nil)
            var sheet = SpreadsheetSheet(name: name, rows: rows.map { $0.map { SpreadsheetCell($0) } })
            sheet.trim()
            return [sheet]
        default:
            throw PetalwheelError(l: "%@ isn't a spreadsheet format.", format.title)
        }
    }

    static func fileSafe(_ s: String) -> String {
        let cleaned = String(s.map { "/:\\".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Sheet" : cleaned
    }

    static func html(_ sheets: [SpreadsheetSheet], title: String) -> String {
        func esc(_ s: String) -> String {
            MarkdownToHTML.escapeHTML(s).replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
        }
        var body = ""
        for sheet in sheets {
            if sheets.count > 1 { body += "<h2>\(esc(sheet.name))</h2>\n" }
            let cols = sheet.columnCount
            body += "<div class=\"wrap\"><table>\n"
            var rows = sheet.rows[...]
            if sheet.hasHeaderRow, let header = rows.first {
                body += "<thead><tr>"
                for c in 0..<cols { body += "<th>\(c < header.count ? esc(header[c].value) : "")</th>" }
                body += "</tr></thead>\n"
                rows = rows.dropFirst()
            }
            body += "<tbody>\n"
            for row in rows {
                body += "<tr>"
                for c in 0..<cols {
                    let cell = c < row.count ? row[c] : SpreadsheetCell("")
                    body += cell.isNumeric ? "<td class=\"num\">\(esc(cell.value))</td>" : "<td>\(esc(cell.value))</td>"
                }
                body += "</tr>\n"
            }
            body += "</tbody></table></div>\n"
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        <style>
        body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 14px; color: #1d1d1f; margin: 24px; }
        h1 { font-size: 20px; margin: 0 0 16px; }
        h2 { font-size: 16px; margin: 28px 0 10px; }
        .wrap { overflow-x: auto; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #d8d8dc; padding: 6px 10px; text-align: left; vertical-align: top; }
        thead th { background: #f4f4f5; font-weight: 600; position: sticky; top: 0; }
        tbody tr:nth-child(even) td { background: #fafafa; }
        td.num { text-align: right; font-variant-numeric: tabular-nums; }
        @media (prefers-color-scheme: dark) {
          body { background: #1e1e1e; color: #eee; }
          th, td { border-color: #444; }
          thead th { background: #2c2c2e; }
          tbody tr:nth-child(even) td { background: #252527; }
        }
        </style>
        </head>
        <body>
        <h1>\(esc(title))</h1>
        \(body)</body>
        </html>
        """
    }
}
