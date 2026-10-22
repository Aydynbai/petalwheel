import Foundation

/// Minimal OOXML spreadsheet (xlsx) reader and writer. Packages are unzipped/zipped with the
/// system /usr/bin/unzip and /usr/bin/zip.
enum SpreadsheetXLSX {
    private static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
    private static let zip = URL(fileURLWithPath: "/usr/bin/zip")

    // MARK: - Reading

    static func read(_ url: URL) async throws -> [SpreadsheetSheet] {
        let dir = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try await ProcessRunner.run(unzip, ["-qq", "-o", url.path, "-d", dir.path])
        } catch {
            throw KumquatError(l: "“%@” isn't a valid xlsx file (couldn't unzip it).", url.lastPathComponent)
        }
        return try read(unpacked: dir, name: url.lastPathComponent)
    }

    static func read(unpacked dir: URL, name: String) throws -> [SpreadsheetSheet] {
        let workbookURL = dir.appendingPathComponent("xl/workbook.xml")
        guard let workbookData = try? Data(contentsOf: workbookURL) else {
            throw KumquatError(l: "“%@” has no workbook (xl/workbook.xml). Is it really an xlsx file?", name)
        }
        let workbook = XMLCollector(data: workbookData)
        let date1904 = workbook.elements.contains { $0.name == "workbookPr" && ($0.attributes["date1904"] == "1" || $0.attributes["date1904"] == "true") }
        let sheetsInfo = workbook.elements.filter { $0.name == "sheet" }

        var targets: [String: String] = [:]
        if let relsData = try? Data(contentsOf: dir.appendingPathComponent("xl/_rels/workbook.xml.rels")) {
            for rel in XMLCollector(data: relsData).elements where rel.name == "Relationship" {
                if let id = rel.attributes["Id"], let target = rel.attributes["Target"] { targets[id] = target }
            }
        }

        var shared: [String] = []
        if let ssData = try? Data(contentsOf: dir.appendingPathComponent("xl/sharedStrings.xml")) {
            shared = SharedStringsParser.parse(ssData)
        }
        let dateStyles = (try? Data(contentsOf: dir.appendingPathComponent("xl/styles.xml"))).map(DateStyleParser.parse) ?? []

        var sheets: [SpreadsheetSheet] = []
        for (index, info) in sheetsInfo.enumerated() {
            let sheetName = info.attributes["name"] ?? "Sheet\(index + 1)"
            let rid = info.attributes["r:id"] ?? info.attributes.first(where: { $0.key.hasSuffix(":id") })?.value
            var path = "xl/worksheets/sheet\(index + 1).xml"
            if let rid, let target = targets[rid] {
                if target.hasPrefix("/") { path = String(target.dropFirst()) }
                else { path = "xl/" + target }
            }
            let sheetURL = dir.appendingPathComponent((path as NSString).standardizingPath)
            guard sheetURL.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path),
                  let data = try? Data(contentsOf: sheetURL) else { continue }   // chartsheets etc.
            var sheet = SpreadsheetSheet(name: sheetName,
                                         rows: SheetParser.parse(data, shared: shared, dateStyles: dateStyles, date1904: date1904))
            sheet.trim()
            sheets.append(sheet)
        }
        if sheets.isEmpty { throw KumquatError(l: "“%@” contains no worksheets.", name) }
        return sheets
    }

    // MARK: - Writing

    static func write(_ sheets: [SpreadsheetSheet], to output: URL) async throws {
        let dir = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for sub in ["_rels", "docProps", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let names = uniqueSheetNames(sheets.map(\.name))
        let sheetCount = max(sheets.count, 1)

        var overrides = """
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        """
        for i in 1...sheetCount {
            overrides += "\n<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        try write(dir, "[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        \(overrides)
        </Types>
        """)
        try write(dir, "_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """)
        let now = ISO8601DateFormatter().string(from: Date())
        try write(dir, "docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:creator>Kumquat</dc:creator>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """)
        try write(dir, "docProps/app.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Kumquat</Application></Properties>
        """)

        var sheetEntries = ""
        var relEntries = ""
        for i in 1...sheetCount {
            let name = i <= names.count ? names[i - 1] : "Sheet1"
            sheetEntries += "<sheet name=\"\(xmlEscape(name))\" sheetId=\"\(i)\" r:id=\"rId\(i)\"/>"
            relEntries += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>\n"
        }
        relEntries += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        try write(dir, "xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <bookViews><workbookView/></bookViews>
        <sheets>\(sheetEntries)</sheets>
        </workbook>
        """)
        try write(dir, "xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(relEntries)
        </Relationships>
        """)
        try write(dir, "xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="2"><font><sz val="12"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="12"/><name val="Calibri"/><family val="2"/></font></fonts>
        <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """)

        for i in 1...sheetCount {
            let sheet = i <= sheets.count ? sheets[i - 1] : SpreadsheetSheet(name: "Sheet1", rows: [])
            try worksheetXML(sheet).write(to: dir.appendingPathComponent("xl/worksheets/sheet\(i).xml"), atomically: true, encoding: .utf8)
        }

        let packaged = dir.appendingPathComponent("out.xlsx")
        try await ProcessRunner.run(zip, ["-X", "-r", "-D", "-q", "-nw", packaged.path, "[Content_Types].xml", "_rels", "docProps", "xl"],
                                    currentDirectory: dir)
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        try FileManager.default.moveItem(at: packaged, to: output)
    }

    private static func write(_ dir: URL, _ path: String, _ content: String) throws {
        try content.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private static func worksheetXML(_ sheet: SpreadsheetSheet) -> String {
        let header = sheet.hasHeaderRow
        let cols = sheet.columnCount
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        """
        if cols > 0 && !sheet.rows.isEmpty {
            xml += "<dimension ref=\"A1:\(columnName(cols - 1))\(sheet.rows.count)\"/>"
        }
        xml += "<sheetViews><sheetView workbookViewId=\"0\"\(header ? "" : " tabSelected=\"1\"")>"
        if header { xml += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>" }
        xml += "</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"16\"/>"
        if cols > 0 {
            xml += "<cols>"
            for c in 0..<cols {
                let longest = sheet.rows.prefix(500).map { c < $0.count ? $0[c].value.split(separator: "\n").map(\.count).max() ?? 0 : 0 }.max() ?? 0
                let width = min(60, max(8, Double(longest) * 1.1 + 2))
                xml += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(String(format: "%.1f", width))\" customWidth=\"1\"/>"
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        var body = ""
        body.reserveCapacity(sheet.rows.count * 64)
        for (r, row) in sheet.rows.enumerated() {
            body += "<row r=\"\(r + 1)\">"
            for (c, cell) in row.enumerated() where !cell.value.isEmpty {
                let ref = "\(columnName(c))\(r + 1)"
                let style = header && r == 0 ? " s=\"1\"" : ""
                if cell.kind == .boolean {
                    let v = ["true", "1"].contains(cell.value.lowercased()) ? "1" : "0"
                    body += "<c r=\"\(ref)\" t=\"b\"\(style)><v>\(v)</v></c>"
                } else if cell.isNumeric {
                    body += "<c r=\"\(ref)\"\(style)><v>\(cell.value)</v></c>"
                } else {
                    body += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(xmlEscape(cell.value))</t></is></c>"
                }
            }
            body += "</row>"
        }
        xml += body + "</sheetData></worksheet>"
        return xml
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// "AB12" → 27 (zero-based column index).
    static func columnIndex(fromReference ref: String) -> Int? {
        var n = 0
        var any = false
        for ch in ref.uppercased().unicodeScalars {
            guard ch.value >= 65 && ch.value <= 90 else { break }
            n = n * 26 + Int(ch.value - 64)
            any = true
        }
        return any ? n - 1 : nil
    }

    static func uniqueSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.enumerated().map { i, raw in
            var name = String(raw.map { "[]:*?/\\".contains($0) ? "_" : $0 })
                .trimmingCharacters(in: CharacterSet(charactersIn: "' ").union(.whitespaces))
            if name.isEmpty { name = "Sheet\(i + 1)" }
            name = String(name.prefix(31))
            var candidate = name
            var n = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(n))"
                candidate = String(name.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // Characters not allowed in XML 1.0 are dropped.
                if scalar.value < 0x20 || (scalar.value >= 0xFFFE && scalar.value <= 0xFFFF) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

// MARK: - XML helpers

/// Collects every element with its attributes (used for small files: workbook, rels).
private final class XMLCollector: NSObject, XMLParserDelegate {
    struct Element { let name: String; let attributes: [String: String] }
    private(set) var elements: [Element] = []

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elements.append(Element(name: Self.local(elementName), attributes: attributeDict))
    }

    static func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inSI = false, inT = false, inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let p = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch XMLCollector.local(elementName) {
        case "si": inSI = true; current = ""
        case "t": inT = true
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch XMLCollector.local(elementName) {
        case "si": inSI = false; strings.append(current)
        case "t": inT = false
        case "rPh": inPhonetic = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inSI && inT && !inPhonetic { current += string }
    }
}

/// Indices of cellXfs entries whose number format is a date/time (value: true = has date part).
private enum DateStyleParser {
    enum Kind { case none, date, dateTime, time }

    static func parse(_ data: Data) -> [Kind] {
        let elements = XMLCollector(data: data).elements
        var customFormats: [Int: String] = [:]
        for e in elements where e.name == "numFmt" {
            if let id = e.attributes["numFmtId"].flatMap(Int.init), let code = e.attributes["formatCode"] { customFormats[id] = code }
        }
        // xf elements inside cellXfs come after cellStyleXfs; find the cellXfs section.
        var inCellXfs = false
        var kinds: [Kind] = []
        for e in elements {
            if e.name == "cellXfs" { inCellXfs = true; continue }
            if e.name == "cellStyles" || e.name == "dxfs" { inCellXfs = false }
            guard inCellXfs, e.name == "xf" else { continue }
            let id = e.attributes["numFmtId"].flatMap(Int.init) ?? 0
            kinds.append(kind(id: id, code: customFormats[id]))
        }
        return kinds
    }

    static func kind(id: Int, code: String?) -> Kind {
        switch id {
        case 14, 15, 16, 17: return .date
        case 22: return .dateTime
        case 18, 19, 20, 21, 45, 46, 47: return .time
        default: break
        }
        guard let code else { return .none }
        // Remove quoted literals, escapes and [color]/[$-locale] sections.
        var cleaned = code.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\\."#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression).lowercased()
        let hasDate = cleaned.contains("y") || cleaned.contains("d")
        let hasTime = cleaned.contains("h") || cleaned.contains("s")
        if hasDate && hasTime { return .dateTime }
        if hasDate { return .date }
        if hasTime && !cleaned.contains("0") && !cleaned.contains("#") { return .time }
        return .none
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private let dateStyles: [DateStyleParser.Kind]
    private let date1904: Bool
    private var rows: [[SpreadsheetCell]] = []
    private var currentRow: [SpreadsheetCell] = []
    private var currentRowIndex = -1
    private var cellColumn = 0
    private var cellType = "n"
    private var cellStyle = 0
    private var value = ""
    private var inlineText = ""
    private var inV = false, inIS = false, inT = false, inCell = false, inPhonetic = false

    init(shared: [String], dateStyles: [DateStyleParser.Kind], date1904: Bool) {
        self.shared = shared
        self.dateStyles = dateStyles
        self.date1904 = date1904
    }

    static func parse(_ data: Data, shared: [String], dateStyles: [DateStyleParser.Kind], date1904: Bool) -> [[SpreadsheetCell]] {
        let p = SheetParser(shared: shared, dateStyles: dateStyles, date1904: date1904)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        switch XMLCollector.local(elementName) {
        case "row":
            let r = a["r"].flatMap(Int.init).map { $0 - 1 } ?? (currentRowIndex + 1)
            // Sparse rows: pad with empty rows (bounded, to survive pathological files).
            while rows.count < r && rows.count < 1_048_576 && r - rows.count < 100_000 { rows.append([]) }
            currentRowIndex = max(r, rows.count)
            currentRow = []
            cellColumn = 0
        case "c":
            inCell = true
            if let ref = a["r"], let col = SpreadsheetXLSX.columnIndex(fromReference: ref) { cellColumn = col }
            cellType = a["t"] ?? "n"
            cellStyle = a["s"].flatMap(Int.init) ?? 0
            value = ""; inlineText = ""
        case "v": inV = true
        case "is": inIS = true
        case "t": inT = true
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inV { value += string }
        else if inIS && inT && !inPhonetic { inlineText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch XMLCollector.local(elementName) {
        case "v": inV = false
        case "is": inIS = false
        case "t": inT = false
        case "rPh": inPhonetic = false
        case "c":
            inCell = false
            let cell = makeCell()
            if cellColumn < 16_384 {
                while currentRow.count < cellColumn { currentRow.append(SpreadsheetCell("")) }
                if currentRow.count == cellColumn { currentRow.append(cell) } else { currentRow[cellColumn] = cell }
            }
            cellColumn += 1
        case "row":
            if rows.count <= currentRowIndex { rows.append(currentRow) } else { rows[currentRowIndex] = currentRow }
        default: break
        }
    }

    private func makeCell() -> SpreadsheetCell {
        switch cellType {
        case "s":
            let i = Int(value.trimmingCharacters(in: .whitespaces)) ?? -1
            return SpreadsheetCell(i >= 0 && i < shared.count ? shared[i] : "", kind: .text)
        case "inlineStr": return SpreadsheetCell(inlineText, kind: .text)
        case "str", "e": return SpreadsheetCell(value, kind: .text)
        case "b": return SpreadsheetCell(value == "1" ? "TRUE" : "FALSE", kind: .boolean)
        default:
            let v = value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return SpreadsheetCell("") }
            let kind = cellStyle < dateStyles.count ? dateStyles[cellStyle] : .none
            if kind != .none, let serial = Double(v), let formatted = formatDate(serial, kind: kind) {
                return SpreadsheetCell(formatted, kind: .text)
            }
            return SpreadsheetCell(Self.tidyNumber(v), kind: .number)
        }
    }

    private func formatDate(_ serial: Double, kind: DateStyleParser.Kind) -> String? {
        guard serial.isFinite, serial > -1, serial < 2_958_466 else { return nil }
        var comps = DateComponents()
        comps.year = date1904 ? 1904 : 1899
        comps.month = date1904 ? 1 : 12
        comps.day = date1904 ? 1 : 30
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let epoch = cal.date(from: comps) else { return nil }
        let seconds = (serial * 86_400).rounded()
        let date = epoch.addingTimeInterval(seconds)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        switch kind {
        case .date: f.dateFormat = "yyyy-MM-dd"
        case .dateTime: f.dateFormat = seconds.truncatingRemainder(dividingBy: 86_400) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        case .time: f.dateFormat = "HH:mm:ss"
        case .none: return nil
        }
        return f.string(from: date)
    }

    /// "3.0000000000000004" → "3", "1.23E-2" stays parseable; keeps integers as integers.
    static func tidyNumber(_ v: String) -> String {
        guard let d = Double(v), d.isFinite else { return v }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        let rounded = Double(String(format: "%.15g", d)) ?? d
        var s = String(format: "%.15g", rounded)
        if s.contains("e") { s = "\(rounded)" }
        return s
    }
}
