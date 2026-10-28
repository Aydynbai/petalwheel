import Foundation

/// YAML writer and a reader for the block-style subset people write by hand.
///
/// Reader supports: block mappings and sequences (including `- key: value` items and `key:` followed by a
/// sequence at the same indent), plain / 'single' / "double" quoted scalars, literal `|` and folded `>`
/// block scalars with `-` / `+` chomping and indentation indicators, single- or multi-line flow collections
/// (`[a, b]`, `{a: 1}`), comments, `---` / `...` markers, anchors `&a` with aliases `*a`, the `<<` merge
/// key, the `!!str` / `!!int` / `!!float` / `!!bool` tags, and YAML 1.2 core-schema scalars
/// (null, true / false, ints incl. 0x / 0o, floats incl. .inf / .nan).
/// Not supported: multiple documents (only the first is read), complex `? ` keys, custom tags, plain
/// scalars continued over several lines inside flow collections, and directives other than `%YAML`.
enum DataYAML {
    struct ParseError: Error { var message: String; var line: Int }

    // MARK: - Writing

    static func write(_ value: DataValue) -> String {
        var lines: [String] = []
        switch value {
        case .array(let a) where !a.isEmpty: lines = block(value)
        case .object(let o) where !o.isEmpty: lines = block(value)
        default: lines = [inline(value)]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Lines for a non-empty container, unindented.
    private static func block(_ value: DataValue) -> [String] {
        var out: [String] = []
        switch value {
        case .object(let pairs):
            for (k, v) in pairs {
                let key = scalarString(k, isKey: true)
                if isNonEmptyContainer(v) {
                    out.append(key + ":")
                    // Sequences under a key are indented too (the more common style).
                    out += block(v).map { "  " + $0 }
                } else if case .string(let s) = v, let literal = literalBlock(s) {
                    out.append(key + ": " + literal.header)
                    out += literal.lines.map { $0.isEmpty ? "" : "  " + $0 }
                } else {
                    out.append(key + ": " + inline(v))
                }
            }
        case .array(let items):
            for v in items {
                if isNonEmptyContainer(v) {
                    let sub = block(v)
                    out.append("- " + sub[0])
                    out += sub.dropFirst().map { "  " + $0 }
                } else if case .string(let s) = v, let literal = literalBlock(s) {
                    out.append("- " + literal.header)
                    out += literal.lines.map { $0.isEmpty ? "" : "  " + $0 }
                } else {
                    out.append("- " + inline(v))
                }
            }
        default:
            out.append(inline(value))
        }
        return out
    }

    private static func isNonEmptyContainer(_ v: DataValue) -> Bool {
        switch v {
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        default: return false
        }
    }

    private static func inline(_ v: DataValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d.isNaN { return ".nan" }
            if d.isInfinite { return d > 0 ? ".inf" : "-.inf" }
            return DataJSON.number(d)
        case .string(let s): return scalarString(s, isKey: false)
        case .array: return "[]"
        case .object: return "{}"
        }
    }

    /// A `|` block for multi-line strings that survive it unchanged.
    private static func literalBlock(_ s: String) -> (header: String, lines: [String])? {
        guard s.contains("\n"), !s.contains("\r"), !s.hasPrefix(" "), !s.hasPrefix("\n"),
              !s.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" }),
              !s.components(separatedBy: "\n").contains(where: { $0.hasSuffix(" ") || $0.hasPrefix("\t") }) else { return nil }
        var body = s
        var chomp = "-"
        if body.hasSuffix("\n") {
            body.removeLast()
            chomp = body.hasSuffix("\n") || body.isEmpty ? "+" : ""
            if chomp == "+" { body = s; body.removeLast() }
        }
        return ("|" + chomp, body.components(separatedBy: "\n"))
    }

    private static let reservedWords: Set<String> = ["null", "~", "true", "false", "yes", "no", "on", "off", "y", "n"]

    static func scalarString(_ s: String, isKey: Bool) -> String {
        if needsQuotes(s, isKey: isKey) { return DataJSON.quote(s) }
        return s
    }

    private static func needsQuotes(_ s: String, isKey: Bool) -> Bool {
        if s.isEmpty || s != s.trimmingCharacters(in: .whitespaces) { return true }
        if reservedWords.contains(s.lowercased()) { return true }
        if resolvePlain(s) != .string(s) { return true }          // would read back as a number etc.
        if let first = s.unicodeScalars.first, "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(first) { return true }
        if s.contains(": ") || s.contains(" #") || s.hasSuffix(":") { return true }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\u{FEFF}" || $0 == "\u{2028}" || $0 == "\u{2029}" }) { return true }
        if isKey && (s.contains("[") || s.contains("]") || s.contains("{") || s.contains("}") || s.contains(",")) { return true }
        return false
    }

    // MARK: - Scalars

    /// YAML 1.2 core schema resolution of a plain scalar.
    static func resolvePlain(_ s: String) -> DataValue {
        switch s {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .double(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .double(-.infinity)
        case ".nan", ".NaN", ".NAN": return .double(.nan)
        default: break
        }
        if s.range(of: #"^[-+]?[0-9]+$"#, options: .regularExpression) != nil {
            if let i = Int(s.hasPrefix("+") ? String(s.dropFirst()) : s) { return .int(i) }
            return .double(Double(s) ?? 0)
        }
        if s.range(of: #"^0x[0-9a-fA-F]+$"#, options: .regularExpression) != nil, let i = Int(s.dropFirst(2), radix: 16) { return .int(i) }
        if s.range(of: #"^0o[0-7]+$"#, options: .regularExpression) != nil, let i = Int(s.dropFirst(2), radix: 8) { return .int(i) }
        if s.range(of: #"^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil,
           let d = Double(s) { return .double(d) }
        return .string(s)
    }

    // MARK: - Reading

    static func parse(_ text: String) throws -> DataValue {
        var p = Parser(text)
        return try p.document()
    }

    fileprivate struct Line {
        var number: Int
        var indent: Int
        var text: String      // without indentation
        var raw: String
    }

    private struct Parser {
        var lines: [Line] = []
        var i = 0
        var anchors: [String: DataValue] = [:]

        init(_ text: String) {
            var t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
            var started = false
            for (n, raw) in t.components(separatedBy: "\n").enumerated() {
                if raw.hasPrefix("%") && !started { continue }                // directives
                if raw == "---" || raw.hasPrefix("--- ") {
                    if started && lines.contains(where: { !$0.isBlankOrComment }) { break }   // second document
                    started = true
                    let rest = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty && !rest.hasPrefix("#") { lines.append(Line(number: n + 1, indent: 0, text: rest, raw: rest)) }
                    continue
                }
                if raw == "..." || raw.hasPrefix("... ") { break }
                started = true
                let indent = raw.prefix(while: { $0 == " " }).count
                lines.append(Line(number: n + 1, indent: indent, text: String(raw.dropFirst(indent)), raw: raw))
            }
        }

        func error(_ m: String) -> ParseError {
            ParseError(message: m, line: i < lines.count ? lines[i].number : (lines.last?.number ?? 0))
        }

        mutating func skipBlank() {
            while i < lines.count && lines[i].isBlankOrComment { i += 1 }
        }

        mutating func document() throws -> DataValue {
            skipBlank()
            guard i < lines.count else { return .null }
            if lines[i].text.hasPrefix("\t") { throw error(L("Tabs can't be used for indentation in YAML.")) }
            let v = try node(minIndent: 0)
            skipBlank()
            if i < lines.count { throw error(L("Unexpected text (check the indentation).")) }
            return v
        }

        /// The block node starting at the next non-blank line, whose indent must be ≥ minIndent.
        mutating func node(minIndent: Int) throws -> DataValue {
            skipBlank()
            guard i < lines.count, lines[i].indent >= minIndent else { return .null }
            let line = lines[i]
            if line.text.hasPrefix("\t") { throw error(L("Tabs can't be used for indentation in YAML.")) }
            if isSequenceItem(line.text) { return try sequence(indent: line.indent) }
            if splitKey(line.text) != nil { return try mapping(indent: line.indent) }
            // A lone scalar or flow collection (possibly over several lines).
            i += 1
            return try inlineValue(line.text, indent: line.indent - 1)
        }

        func isSequenceItem(_ t: String) -> Bool { t == "-" || t.hasPrefix("- ") || t.hasPrefix("-\t") }

        mutating func sequence(indent: Int) throws -> DataValue {
            var items: [DataValue] = []
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent, isSequenceItem(lines[i].text) else { break }
                let line = lines[i]
                let rest = String(line.text.dropFirst(1))
                let gap = rest.prefix(while: { $0 == " " || $0 == "\t" }).count
                let content = String(rest.dropFirst(gap))
                if content.isEmpty || content.hasPrefix("#") {
                    i += 1
                    items.append(try node(minIndent: indent + 1))
                } else {
                    // Re-read the item's content as if it started its own (more indented) line.
                    lines[i] = Line(number: line.number, indent: indent + 1 + gap, text: content, raw: line.raw)
                    items.append(try itemNode(indent: indent + 1 + gap))
                }
            }
            return .array(items)
        }

        /// Node whose first line is the current (rewritten) line at `indent`.
        mutating func itemNode(indent: Int) throws -> DataValue {
            let text = lines[i].text
            if isSequenceItem(text) { return try sequence(indent: indent) }
            if splitKey(text) != nil { return try mapping(indent: indent) }
            i += 1
            return try inlineValue(text, indent: indent - 1)
        }

        mutating func mapping(indent: Int) throws -> DataValue {
            var pairs: [(String, DataValue)] = []
            func set(_ k: String, _ v: DataValue) {
                if let idx = pairs.firstIndex(where: { $0.0 == k }) { pairs[idx].1 = v } else { pairs.append((k, v)) }
            }
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent else { break }
                let line = lines[i]
                if line.text.hasPrefix("? ") { throw error(L("Complex keys (“? ”) aren't supported.")) }
                guard let (key, rest) = splitKey(line.text) else {
                    if isSequenceItem(line.text) { throw error(L("A list item can't follow a key at the same level.")) }
                    throw error(L("Expected “key: value”."))
                }
                i += 1
                var value: DataValue
                var restText = stripComment(rest).trimmingCharacters(in: .whitespaces)
                var anchor: String?
                if restText.hasPrefix("&") {
                    let name = restText.dropFirst().prefix(while: { !$0.isWhitespace })
                    anchor = String(name)
                    restText = String(restText.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
                }
                var tag: String?
                if restText.hasPrefix("!") && !restText.hasPrefix("!=") {
                    let t = restText.prefix(while: { !$0.isWhitespace })
                    tag = String(t)
                    restText = String(restText.dropFirst(t.count)).trimmingCharacters(in: .whitespaces)
                }
                if restText.isEmpty {
                    skipBlank()
                    if i < lines.count, lines[i].indent == indent, isSequenceItem(lines[i].text) {
                        value = try sequence(indent: indent)          // "key:\n- item" at the same indent
                    } else if i < lines.count, lines[i].indent > indent {
                        value = try node(minIndent: indent + 1)
                    } else {
                        value = .null
                    }
                } else if restText.hasPrefix("|") || restText.hasPrefix(">") {
                    value = .string(try blockScalar(header: restText, parentIndent: indent))
                } else {
                    value = try inlineValue(rest, indent: indent)
                }
                if let tag { value = try applyTag(tag, value) }
                if let anchor { anchors[anchor] = value }
                if key == "<<" {
                    // Merge key: copy the referenced mapping(s) without overriding existing keys.
                    let sources: [DataValue]
                    if case .array(let a) = value { sources = a } else { sources = [value] }
                    for src in sources {
                        if case .object(let o) = src { for (k, v) in o where !pairs.contains(where: { $0.0 == k }) { pairs.append((k, v)) } }
                    }
                    continue
                }
                set(key, value)
            }
            return .object(pairs)
        }

        /// "key: rest" → (key, rest). Handles quoted keys; plain keys end at the first ": ".
        func splitKey(_ t: String) -> (String, String)? {
            if t.hasPrefix("\"") || t.hasPrefix("'") {
                var sub = Substring(t)
                guard let key = try? Parser.quoted(&sub) else { return nil }
                let after = sub.drop(while: { $0 == " " })
                guard after.hasPrefix(":") else { return nil }
                let rest = after.dropFirst()
                guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
                return (key, String(rest))
            }
            if t.hasPrefix("[") || t.hasPrefix("{") || t.hasPrefix("#") || isSequenceItem(t) { return nil }
            var idx = t.startIndex
            while idx < t.endIndex {
                if t[idx] == "#", idx > t.startIndex, t[t.index(before: idx)] == " " { return nil }
                if t[idx] == ":" {
                    let next = t.index(after: idx)
                    if next == t.endIndex || t[next] == " " || t[next] == "\t" {
                        let key = String(t[..<idx]).trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { return nil }
                        return (key, String(t[next...]))
                    }
                }
                idx = t.index(after: idx)
            }
            return nil
        }

        func stripComment(_ s: String) -> String {
            // Quoted scalars and flow collections are handled by inlineValue; this only trims a trailing
            // " # comment" from a plain value.
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") || trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { return s }
            if trimmed.hasPrefix("#") { return "" }
            if let r = s.range(of: " #") ?? s.range(of: "\t#") { return String(s[..<r.lowerBound]) }
            return s
        }

        mutating func applyTag(_ tag: String, _ v: DataValue) throws -> DataValue {
            switch tag {
            case "!!str": return .string(v.scalarText)
            case "!!int":
                if case .string(let s) = v, let n = Int(s) { return .int(n) }
                return v
            case "!!float":
                if case .int(let n) = v { return .double(Double(n)) }
                if case .string(let s) = v, let d = Double(s) { return .double(d) }
                return v
            case "!!bool":
                if case .string(let s) = v { return .bool(["true", "yes", "on"].contains(s.lowercased())) }
                return v
            case "!!null": return .null
            default: return v        // !!map, !!seq, !!binary and custom tags: keep the value as read
            }
        }

        /// Literal (|) or folded (>) block scalar; `header` is the indicator text after the colon.
        mutating func blockScalar(header: String, parentIndent: Int) throws -> String {
            let literal = header.hasPrefix("|")
            var chomp: Character = " "
            var explicitIndent: Int?
            for c in header.dropFirst().prefix(while: { !$0.isWhitespace && $0 != "#" }) {
                if c == "-" || c == "+" { chomp = c } else if let d = c.wholeNumberValue { explicitIndent = d }
            }
            var raw: [String] = []
            var blockIndent: Int? = explicitIndent.map { parentIndent + $0 }
            while i < lines.count {
                let line = lines[i]
                let blank = line.raw.trimmingCharacters(in: .whitespaces).isEmpty
                if !blank {
                    if blockIndent == nil {
                        guard line.indent > parentIndent else { break }
                        blockIndent = line.indent
                    }
                    if line.indent < blockIndent! { break }
                }
                raw.append(blank ? "" : String(line.raw.dropFirst(blockIndent!)))
                i += 1
            }
            // Trailing blank lines belong to chomping, not content.
            var trailing = 0
            while let last = raw.last, last.isEmpty { raw.removeLast(); trailing += 1 }
            var text: String
            if literal {
                text = raw.joined(separator: "\n")
            } else {
                // Folding: a single line break between two normal lines becomes a space; empty lines
                // stay line breaks; more-indented lines keep theirs.
                text = ""
                var first = true, prevNormal = false, pending = 0
                for l in raw {
                    if l.isEmpty { pending += 1; continue }
                    let normal = !(l.hasPrefix(" ") || l.hasPrefix("\t"))
                    if first {
                        text = String(repeating: "\n", count: pending) + l
                        first = false
                    } else if pending > 0 {
                        text += String(repeating: "\n", count: prevNormal && normal ? pending : pending + 1) + l
                    } else {
                        text += (prevNormal && normal ? " " : "\n") + l
                    }
                    pending = 0
                    prevNormal = normal
                }
            }
            if raw.isEmpty { return chomp == "+" ? String(repeating: "\n", count: trailing) : "" }
            switch chomp {
            case "-": return text
            case "+": return text + "\n" + String(repeating: "\n", count: trailing)
            default: return text + "\n"
            }
        }

        /// A value written on the same line as its key or dash: quoted / plain scalar, alias or flow
        /// collection. Plain scalars may continue on following, more indented lines.
        mutating func inlineValue(_ text: String, indent: Int) throws -> DataValue {
            var t = text.trimmingCharacters(in: .whitespaces)
            var anchor: String?
            if t.hasPrefix("&") {
                let name = t.dropFirst().prefix(while: { !$0.isWhitespace })
                anchor = String(name)
                t = String(t.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            var tag: String?
            if t.hasPrefix("!") {
                let tg = t.prefix(while: { !$0.isWhitespace })
                tag = String(tg)
                t = String(t.dropFirst(tg.count)).trimmingCharacters(in: .whitespaces)
            }
            var value: DataValue
            if t.hasPrefix("*") {
                let name = String(t.dropFirst().prefix(while: { !$0.isWhitespace && $0 != "," }))
                guard let v = anchors[name] else { throw error(L("Unknown alias “*%@”.", name)) }
                value = v
            } else if t.hasPrefix("[") || t.hasPrefix("{") {
                // Join following lines until the brackets balance.
                var joined = t
                while !Parser.balanced(joined), i < lines.count {
                    joined += " " + lines[i].text
                    i += 1
                }
                var sub = Substring(joined)
                value = try flow(&sub)
                let tail = sub.trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty && !tail.hasPrefix("#") { throw error(L("Unexpected text after a flow collection.")) }
            } else if t.hasPrefix("\"") || t.hasPrefix("'") {
                var joined = t
                // Quoted scalars may span lines (folded with spaces).
                while !Parser.quoteClosed(joined), i < lines.count {
                    let next = lines[i].text.trimmingCharacters(in: .whitespaces)
                    joined += next.isEmpty ? "\n" : (joined.hasSuffix("\n") ? next : " " + next)
                    i += 1
                }
                var sub = Substring(joined)
                value = .string(try Parser.quoted(&sub))
                let tail = sub.trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty && !tail.hasPrefix("#") { throw error(L("Unexpected text after a quoted string.")) }
            } else {
                var plain = stripComment(t).trimmingCharacters(in: .whitespaces)
                // Multi-line plain scalar: continuation lines are more indented than the parent.
                while i < lines.count, !lines[i].isBlankOrComment, lines[i].indent > indent,
                      splitKey(lines[i].text) == nil, !isSequenceItem(lines[i].text) {
                    plain += " " + stripComment(lines[i].text).trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                value = resolvePlain(plain)
            }
            if let tag { value = try applyTag(tag, value) }
            if let anchor { anchors[anchor] = value }
            return value
        }

        static func balanced(_ s: String) -> Bool {
            var depth = 0
            var quote: Character?
            var prev: Character = " "
            for c in s {
                if let q = quote {
                    if c == q && !(q == "\"" && prev == "\\") { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == "#" && prev == " " {
                    break
                } else if c == "[" || c == "{" { depth += 1 } else if c == "]" || c == "}" { depth -= 1 }
                prev = c
            }
            return depth <= 0
        }

        static func quoteClosed(_ s: String) -> Bool {
            var sub = Substring(s)
            return (try? quoted(&sub)) != nil
        }

        /// Reads a quoted scalar at the start of `s`, advancing past it.
        static func quoted(_ s: inout Substring) throws -> String {
            guard let q = s.first else { throw ParseError(message: L("Expected a string."), line: 0) }
            s = s.dropFirst()
            var out = ""
            while let c = s.first {
                s = s.dropFirst()
                if q == "'" {
                    if c == "'" {
                        if s.first == "'" { out.append("'"); s = s.dropFirst(); continue }
                        return out
                    }
                    out.append(c)
                    continue
                }
                if c == "\"" { return out }
                if c != "\\" { out.append(c); continue }
                guard let e = s.first else { break }
                s = s.dropFirst()
                switch e {
                case "n": out.append("\n")
                case "t", "\t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case "a": out.append("\u{7}")
                case "b": out.append("\u{8}")
                case "e": out.append("\u{1B}")
                case "f": out.append("\u{C}")
                case "v": out.append("\u{B}")
                case "N": out.append("\u{85}")
                case "_": out.append("\u{A0}")
                case "L": out.append("\u{2028}")
                case "P": out.append("\u{2029}")
                case " ": out.append(" ")
                case "x", "u", "U":
                    let n = e == "x" ? 2 : e == "u" ? 4 : 8
                    let hex = String(s.prefix(n))
                    guard hex.count == n, let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else {
                        throw ParseError(message: L("Invalid escape “\\%@”.", "\(e)\(hex)"), line: 0)
                    }
                    out.unicodeScalars.append(u)
                    s = s.dropFirst(n)
                default: out.append(e)
                }
            }
            throw ParseError(message: L("Unterminated quoted string."), line: 0)
        }

        /// Flow collection or scalar inside one.
        mutating func flow(_ s: inout Substring) throws -> DataValue {
            func skip() { s = s.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }) }
            skip()
            guard let c = s.first else { return .null }
            if c == "[" {
                s = s.dropFirst()
                var items: [DataValue] = []
                while true {
                    skip()
                    if s.first == "]" { s = s.dropFirst(); return .array(items) }
                    let item = try flowEntry(&s, inMap: false)
                    items.append(item.value)
                    skip()
                    if s.first == "," { s = s.dropFirst(); continue }
                    if s.first == "]" { s = s.dropFirst(); return .array(items) }
                    throw error(L("Expected “,” or “]” in a flow sequence."))
                }
            }
            if c == "{" {
                s = s.dropFirst()
                var pairs: [(String, DataValue)] = []
                while true {
                    skip()
                    if s.first == "}" { s = s.dropFirst(); return .object(pairs) }
                    let entry = try flowEntry(&s, inMap: true)
                    pairs.append((entry.key ?? "", entry.value))
                    skip()
                    if s.first == "," { s = s.dropFirst(); continue }
                    if s.first == "}" { s = s.dropFirst(); return .object(pairs) }
                    throw error(L("Expected “,” or “}” in a flow mapping."))
                }
            }
            return try flowScalar(&s, stopAtColon: false)
        }

        mutating func flowEntry(_ s: inout Substring, inMap: Bool) throws -> (key: String?, value: DataValue) {
            let first: DataValue
            if s.first == "[" || s.first == "{" { first = try flow(&s) } else { first = try flowScalar(&s, stopAtColon: true) }
            s = s.drop(while: { $0 == " " || $0 == "\t" })
            if s.first == ":" {
                s = s.dropFirst()
                s = s.drop(while: { $0 == " " || $0 == "\t" })
                let v: DataValue = (s.first == "," || s.first == "}" || s.first == "]") ? .null : try flow(&s)
                if inMap { return (first.scalarText, v) }
                return (nil, .object([(first.scalarText, v)]))      // [a: 1] = [{a: 1}]
            }
            return (inMap ? first.scalarText : nil, inMap ? .null : first)
        }

        mutating func flowScalar(_ s: inout Substring, stopAtColon: Bool) throws -> DataValue {
            if s.first == "\"" || s.first == "'" { return .string(try Parser.quoted(&s)) }
            if s.first == "*" {
                s = s.dropFirst()
                let name = String(s.prefix(while: { !$0.isWhitespace && !",]}".contains($0) }))
                s = s.dropFirst(name.count)
                guard let v = anchors[name] else { throw error(L("Unknown alias “*%@”.", name)) }
                return v
            }
            var text = ""
            while let c = s.first {
                if c == "," || c == "]" || c == "}" { break }
                if c == ":" && stopAtColon {
                    let next = s.dropFirst().first
                    if next == nil || next == " " || next == "," || next == "]" || next == "}" { break }
                }
                if c == "#" && (text.hasSuffix(" ") || text.isEmpty) { break }
                text.append(c)
                s = s.dropFirst()
            }
            return resolvePlain(text.trimmingCharacters(in: .whitespaces))
        }
    }
}

private extension DataYAML.Line {
    var isBlankOrComment: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("#")
    }
}
