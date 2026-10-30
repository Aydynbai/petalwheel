import Foundation

/// Structured data: JSON ↔ YAML ↔ XML ↔ plist, data ↔ CSV / TSV (an array of objects, one per row),
/// and spreadsheets (csv, tsv, xlsx) → JSON / YAML / XML. All output is pretty-printed UTF-8.
struct DataFormatEngine: ConversionEngine {
    static let dataFormats: Set<FileFormat> = [.json, .yaml, .xml, .plist]
    static let tableFormats: Set<FileFormat> = [.csv, .tsv]

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        if Self.dataFormats.contains(source) { return Self.dataFormats.contains(target) || Self.tableFormats.contains(target) }
        if [.csv, .tsv, .xlsx].contains(source) { return [.json, .yaml, .xml].contains(target) }
        return false
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw NurToError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        progress(0.05)
        let value = try await Self.load(source, format: from)
        progress(0.6)
        try Task.checkCancellation()
        let out = OutputNaming.url(for: source, ext: target.fileExtension)
        let data = try Self.encode(value, as: target)
        do {
            try data.write(to: out, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress(1)
        return [out]
    }

    // MARK: Loading

    static func load(_ url: URL, format: FileFormat) async throws -> DataValue {
        let name = url.lastPathComponent
        switch format {
        case .json:
            let text = try DocumentTextDecoder.decode(contentsOf: url)
            do { return try DataJSON.parse(text) } catch let e as DataJSON.ParseError {
                throw NurToError(l: "Couldn't read “%@” (line %d): %@", name, e.line, e.message)
            }
        case .yaml:
            let text = try DocumentTextDecoder.decode(contentsOf: url)
            do { return try DataYAML.parse(text) } catch let e as DataYAML.ParseError {
                throw NurToError(l: "Couldn't read “%@” (line %d): %@", name, e.line, e.message)
            }
        case .xml:
            return try DataXML.parse(try Data(contentsOf: url))
        case .plist:
            let data = try Data(contentsOf: url)
            guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                throw NurToError(l: "“%@” isn't a valid property list.", name)
            }
            return fromPropertyList(object)
        case .csv, .tsv, .xlsx:
            let sheets = try await SpreadsheetEngine.load(url, format: format)
            let tables = sheets.map { objects(fromRows: $0.rows.map { $0.map(\.value) }) }
            if tables.count == 1 { return tables[0] }
            return .object(zip(sheets, tables).map { ($0.name, $1) })
        default:
            throw NurToError(l: "Can't convert %@ to %@.", format.title, FileFormat.json.title)
        }
    }

    // MARK: Encoding

    static func encode(_ value: DataValue, as target: FileFormat) throws -> Data {
        switch target {
        case .json: return Data(DataJSON.write(value).utf8)
        case .yaml: return Data(DataYAML.write(value).utf8)
        case .xml: return Data(DataXML.write(value).utf8)
        case .plist:
            do {
                return try PropertyListSerialization.data(fromPropertyList: toPropertyList(value), format: .xml, options: 0)
            } catch {
                throw NurToError(l: "Couldn't write the property list: %@", error.localizedDescription)
            }
        case .csv, .tsv:
            guard let rows = table(value) else {
                throw NurToError(l: "This data can't be laid out as a table. CSV and TSV need a list of records (an array of objects).")
            }
            // "\r\n" is one Character in Swift, so CSV quoting checks wouldn't see the line break: use "\n".
            let cells = rows.map { $0.map { $0.replacingOccurrences(of: "\r\n", with: "\n") } }
            let text = SpreadsheetCSV.write(cells, delimiter: target == .csv ? "," : "\t")
            // UTF-8 BOM so Excel detects the encoding (same as the spreadsheet engine).
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data(text.utf8))
            return data
        default:
            throw NurToError(l: "Can't convert %@ to %@.", FileFormat.json.title, target.title)
        }
    }

    // MARK: Property lists

    static func fromPropertyList(_ object: Any) -> DataValue {
        switch object {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.intValue)
        case let d as Date:
            let f = ISO8601DateFormatter()
            return .string(f.string(from: d))
        case let d as Data: return .string(d.base64EncodedString())
        case let a as [Any]: return .array(a.map(fromPropertyList))
        case let d as [String: Any]:
            // Property lists don't keep key order; sort for a stable result.
            return .object(d.keys.sorted().map { ($0, fromPropertyList(d[$0]!)) })
        default: return .string("\(object)")
        }
    }

    /// Plists have no null: null values are left out of dictionaries and become empty strings in arrays.
    static func toPropertyList(_ v: DataValue) -> Any {
        switch v {
        case .null: return ""
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(toPropertyList)
        case .object(let pairs):
            var d: [String: Any] = [:]
            for (k, item) in pairs where item != .null { d[k] = toPropertyList(item) }
            return d
        }
    }

    // MARK: Tables

    /// Rows (first = header) → array of objects. Cells that look like plain numbers or booleans are typed.
    static func objects(fromRows rows: [[String]]) -> DataValue {
        guard let header = rows.first else { return .array([]) }
        var keys: [String] = []
        for (i, raw) in header.enumerated() {
            var k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if k.isEmpty { k = "column \(i + 1)" }
            var unique = k, n = 2
            while keys.contains(unique) { unique = "\(k) \(n)"; n += 1 }
            keys.append(unique)
        }
        var records: [DataValue] = []
        for row in rows.dropFirst() {
            if row.allSatisfy({ $0.isEmpty }) { continue }
            var pairs: [(String, DataValue)] = []
            for (i, key) in keys.enumerated() {
                pairs.append((key, typedCell(i < row.count ? row[i] : "")))
            }
            // Extra cells beyond the header keep their position.
            if row.count > keys.count {
                for i in keys.count..<row.count where !row[i].isEmpty { pairs.append(("column \(i + 1)", typedCell(row[i]))) }
            }
            records.append(.object(pairs))
        }
        return .array(records)
    }

    static func typedCell(_ raw: String) -> DataValue {
        let s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        // No leading zeros ("007" is an identifier, not a number), no thousands separators.
        if s.range(of: #"^-?(0|[1-9][0-9]{0,17})$"#, options: .regularExpression) != nil, let i = Int(s) { return .int(i) }
        if s.range(of: #"^-?(0|[1-9][0-9]*)\.[0-9]+$"#, options: .regularExpression) != nil, let d = Double(s) { return .double(d) }
        return .string(s)
    }

    /// Data → rows with a header, or nil when the data isn't tabular.
    static func table(_ value: DataValue) -> [[String]]? {
        switch value {
        case .array(let items):
            if items.isEmpty { return [] }
            if items.allSatisfy({ if case .array = $0 { return true }; return false }) {
                return items.map { item in
                    guard case .array(let cells) = item else { return [] }
                    return cells.map(\.scalarText)
                }
            }
            var keys: [String] = []
            var records: [[(String, DataValue)]] = []
            for item in items {
                let pairs: [(String, DataValue)]
                if case .object(let p) = item { pairs = p } else { pairs = [("value", item)] }
                for (k, _) in pairs where !keys.contains(k) { keys.append(k) }
                records.append(pairs)
            }
            var rows = [keys]
            for r in records {
                let d = Dictionary(r, uniquingKeysWith: { a, _ in a })
                rows.append(keys.map { d[$0]?.scalarText ?? "" })
            }
            return rows
        case .object(let pairs):
            if pairs.count == 1 { return table(pairs[0].1) }
            // A flat record is a one-row table.
            if pairs.allSatisfy({ !$0.1.isContainer }) { return [pairs.map(\.0), pairs.map { $0.1.scalarText }] }
            // A wrapper object with exactly one list of records (e.g. {"count": 2, "items": […]}).
            let lists = pairs.filter { if case .array = $0.1 { return true }; return false }
            if lists.count == 1 { return table(lists[0].1) }
            return nil
        default:
            return nil
        }
    }
}
