import Foundation

/// A structured-data tree shared by the JSON, YAML, XML, plist and CSV converters. Objects keep their
/// key order so a JSON → YAML → JSON round trip reads the same.
indirect enum DataValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([DataValue])
    case object([(String, DataValue)])

    static func == (a: DataValue, b: DataValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y || (x.isNaN && y.isNaN)
        case let (.int(x), .double(y)), let (.double(y), .int(x)): return Double(x) == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            let dy = Dictionary(y, uniquingKeysWith: { a, _ in a })
            return x.allSatisfy { dy[$0.0] == $0.1 }
        default: return false
        }
    }

    subscript(key: String) -> DataValue? {
        if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    /// Text form of a scalar (used for XML text and CSV cells); containers become compact JSON.
    var scalarText: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return DataJSON.number(d)
        case .string(let s): return s
        case .array, .object: return DataJSON.write(self, pretty: false)
        }
    }

    var isContainer: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }
}

/// Our own JSON reader / writer: keeps key order and the int / double / bool distinction
/// (JSONSerialization returns unordered NSDictionary and NSNumber booleans).
enum DataJSON {
    struct ParseError: Error { var message: String; var line: Int }

    static func parse(_ text: String) throws -> DataValue {
        var p = Parser(Array(text.unicodeScalars))
        p.skipBOM()
        p.skipSpace()
        let v = try p.value(depth: 0)
        p.skipSpace()
        guard p.atEnd else { throw p.error(L("Unexpected text after the value.")) }
        return v
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        func error(_ m: String) -> ParseError {
            ParseError(message: m, line: s[..<min(i, s.count)].filter { $0 == "\n" }.count + 1)
        }
        mutating func skipBOM() { if !atEnd && s[i] == "\u{FEFF}" { i += 1 } }
        mutating func skipSpace() {
            while !atEnd {
                let c = s[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
                // Tolerate // and /* */ comments (JSONC, common in config files).
                if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                    while !atEnd && s[i] != "\n" { i += 1 }
                    continue
                }
                if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count && !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                    i = min(s.count, i + 2)
                    continue
                }
                break
            }
        }
        mutating func expect(_ c: Unicode.Scalar) throws {
            guard !atEnd, s[i] == c else { throw error(L("Expected “%@”.", String(c))) }
            i += 1
        }
        mutating func value(depth: Int) throws -> DataValue {
            guard depth < 512 else { throw error(L("Nesting too deep.")) }
            guard !atEnd else { throw error(L("Unexpected end of text.")) }
            switch s[i] {
            case "{":
                i += 1
                var pairs: [(String, DataValue)] = []
                skipSpace()
                if !atEnd && s[i] == "}" { i += 1; return .object(pairs) }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    try expect(":")
                    skipSpace()
                    let v = try value(depth: depth + 1)
                    if let idx = pairs.firstIndex(where: { $0.0 == key }) { pairs[idx].1 = v } else { pairs.append((key, v)) }
                    skipSpace()
                    guard !atEnd else { throw error(L("Unterminated object.")) }
                    if s[i] == "," {
                        i += 1
                        skipSpace()
                        if !atEnd && s[i] == "}" { i += 1; return .object(pairs) }   // trailing comma
                        continue
                    }
                    try expect("}")
                    return .object(pairs)
                }
            case "[":
                i += 1
                var items: [DataValue] = []
                skipSpace()
                if !atEnd && s[i] == "]" { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard !atEnd else { throw error(L("Unterminated array.")) }
                    if s[i] == "," {
                        i += 1
                        skipSpace()
                        if !atEnd && s[i] == "]" { i += 1; return .array(items) }
                        continue
                    }
                    try expect("]")
                    return .array(items)
                }
            case "\"":
                return .string(try string())
            case "t": try word("true"); return .bool(true)
            case "f": try word("false"); return .bool(false)
            case "n": try word("null"); return .null
            default:
                return try number()
            }
        }
        mutating func word(_ w: String) throws {
            for c in w.unicodeScalars {
                guard !atEnd, s[i] == c else { throw error(L("Unexpected text.")) }
                i += 1
            }
        }
        mutating func number() throws -> DataValue {
            let start = i
            if !atEnd && (s[i] == "-" || s[i] == "+") { i += 1 }
            var isDouble = false
            while !atEnd {
                let c = s[i]
                if ("0"..."9").contains(c) { i += 1 }
                else if c == "." || c == "e" || c == "E" || ((c == "-" || c == "+") && (s[i - 1] == "e" || s[i - 1] == "E")) { isDouble = true; i += 1 }
                else { break }
            }
            let text = String(String.UnicodeScalarView(s[start..<i]))
            guard !text.isEmpty, text != "-" else { throw error(L("Unexpected character.")) }
            if !isDouble, let n = Int(text) { return .int(n) }
            guard let d = Double(text) else { throw error(L("“%@” isn't a valid number.", text)) }
            return .double(d)
        }
        mutating func string() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            while true {
                guard !atEnd else { throw error(L("Unterminated string.")) }
                let c = s[i]
                i += 1
                if c == "\"" { break }
                if c != "\\" { out.append(c); continue }
                guard !atEnd else { throw error(L("Unterminated string.")) }
                let e = s[i]
                i += 1
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{C}")
                case "u":
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), i + 1 < s.count, s[i] == "\\", s[i + 1] == "u" {
                        i += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    out.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: out.append(e)
                }
            }
            return String(out)
        }
        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= s.count, let v = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16) else {
                throw error(L("Invalid \\u escape."))
            }
            i += 4
            return v
        }
    }

    // MARK: Writing

    static func number(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(format: "%.1f", d) }
        return "\(d)"
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func write(_ v: DataValue, pretty: Bool = true) -> String {
        var out = ""
        emit(v, indent: 0, pretty: pretty, into: &out)
        return pretty ? out + "\n" : out
    }

    private static func emit(_ v: DataValue, indent: Int, pretty: Bool, into out: inout String) {
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let close = pretty ? String(repeating: "  ", count: indent) : ""
        let nl = pretty ? "\n" : ""
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += number(d)
        case .string(let s): out += quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (n, item) in items.enumerated() {
                out += pad
                emit(item, indent: indent + 1, pretty: pretty, into: &out)
                out += (n < items.count - 1 ? "," : "") + nl
            }
            out += close + "]"
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (n, (k, item)) in pairs.enumerated() {
                out += pad + quote(k) + (pretty ? ": " : ":")
                emit(item, indent: indent + 1, pretty: pretty, into: &out)
                out += (n < pairs.count - 1 ? "," : "") + nl
            }
            out += close + "}"
        }
    }
}
