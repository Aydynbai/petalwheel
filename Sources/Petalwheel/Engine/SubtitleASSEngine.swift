import Foundation

/// Advanced SubStation Alpha (ass) and SubStation Alpha (ssa) in and out.
/// - ass / ssa → srt / vtt / txt: dialogue events in time order; bold / italic / underline / strike-out
///   override tags (and styles that set them) become <b> <i> <u> <s>, top alignment becomes {\an8}
///   (and `line:0` in WebVTT), drawings and comments are dropped, other overrides are removed.
/// - srt / vtt (and ass ↔ ssa) → ass / ssa: one Default style (Arial, white with an outline), the cue
///   text with <b> <i> <u> <s> and <font color> turned into override tags, line breaks as \N.
struct SubtitleASSEngine: ConversionEngine {
    static let styled: Set<FileFormat> = [.ass, .ssa]

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        if Self.styled.contains(source) { return [.srt, .vtt, .txt, .ass, .ssa].contains(target) }
        return [.srt, .vtt].contains(source) && Self.styled.contains(target)
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw NurToError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        progress(0.1)
        let text = try DocumentTextDecoder.decode(contentsOf: source)
        let cues = Self.styled.contains(from) ? ASSDocument.parse(text) : SubtitleDocument.parse(text)
        guard !cues.isEmpty else {
            throw NurToError(l: "No subtitles found in “%@”.", source.lastPathComponent)
        }
        progress(0.6)
        let output: String
        switch target {
        case .srt: output = SubtitleDocument.srt(cues)
        case .vtt: output = SubtitleDocument.vtt(cues, sourceIsVTT: false)
        case .txt: output = SubtitleDocument.transcript(cues)
        default:
            output = ASSDocument.write(cues, ssa: target == .ssa, title: source.deletingPathExtension().lastPathComponent,
                                       sourceIsVTT: from == .vtt)
        }
        let url = OutputNaming.url(for: source, ext: target.rawValue)
        // ASS files conventionally carry a UTF-8 BOM (older renderers rely on it).
        var data = Data()
        if Self.styled.contains(target) { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(output.utf8))
        try data.write(to: url, options: .atomic)
        progress(1)
        return [url]
    }
}

/// ASS / SSA parsing and writing. Cue lines use SubRip-style markup (<i>…</i>, {\an8}), the same as
/// `SubtitleDocument`, so the existing SRT / VTT writers can be reused.
enum ASSDocument {
    struct Style { var bold = false, italic = false, underline = false, strike = false, alignment = 2 }

    // MARK: Reading

    static func parse(_ raw: String) -> [SubtitleCue] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var section = ""
        var styleFormat: [String] = []
        var eventFormat: [String] = []
        var styles: [String: Style] = [:]
        var isSSA = false
        var events: [(start: Int, end: Int, order: Int, cue: SubtitleCue)] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix(";") || t.hasPrefix("!:") { continue }
            if t.hasPrefix("[") && t.hasSuffix("]") {
                section = t.lowercased()
                if section == "[v4 styles]" { isSSA = true }
                continue
            }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = t[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "scripttype", value.lowercased().contains("v4.00") && !value.contains("+") { isSSA = true }
            if section.contains("styles") {
                if key == "format" { styleFormat = fields(value, count: nil) }
                else if key == "style" {
                    let f = fields(value, count: styleFormat.count)
                    func field(_ name: String) -> String? {
                        guard let idx = styleFormat.firstIndex(of: name), idx < f.count else { return nil }
                        return f[idx]
                    }
                    var s = Style()
                    s.bold = isOn(field("bold"))
                    s.italic = isOn(field("italic"))
                    s.underline = isOn(field("underline"))
                    s.strike = isOn(field("strikeout"))
                    if let a = field("alignment").flatMap({ Int($0) }) { s.alignment = isSSA ? numpad(fromSSA: a) : a }
                    styles[(field("name") ?? "Default").lowercased()] = s
                }
            } else if section == "[events]" {
                if key == "format" { eventFormat = fields(value, count: nil); continue }
                guard key == "dialogue" else { continue }      // Comment:, Picture:, Sound:, Movie:, Command:
                let format = eventFormat.isEmpty
                    ? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
                    : eventFormat
                let f = fields(value, count: format.count)
                func field(_ name: String) -> String? {
                    guard let idx = format.firstIndex(of: name), idx < f.count else { return nil }
                    return f[idx]
                }
                guard let start = field("start").flatMap(parseTime), let end = field("end").flatMap(parseTime),
                      let body = field("text") else { continue }
                let style = styles[(field("style") ?? "default").trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "*", with: "")]
                    ?? styles["default"] ?? Style()
                let lines = convertText(body, style: style, ssa: isSSA)
                guard !lines.isEmpty else { continue }
                events.append((start, end, events.count, SubtitleCue(identifier: nil, start: start, end: max(end, start),
                                                                     settings: "", lines: lines)))
            }
        }
        return events.sorted { ($0.start, $0.order) < ($1.start, $1.order) }.map(\.cue)
    }

    /// Splits a comma-separated line into at most `count` fields (the last one keeps its commas).
    static func fields(_ s: String, count: Int?) -> [String] {
        if let count, count > 0 {
            let parts = s.split(separator: ",", maxSplits: count - 1, omittingEmptySubsequences: false)
            return parts.enumerated().map { n, part in
                n == count - 1 ? String(part) : part.trimmingCharacters(in: .whitespaces)
            }
        }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func isOn(_ s: String?) -> Bool {
        guard let s, let v = Int(s.trimmingCharacters(in: .whitespaces)) else { return false }
        return v != 0
    }

    /// SSA alignment (1–3 bottom, +4 top, +8 middle) → numpad (1–3 bottom, 4–6 middle, 7–9 top).
    static func numpad(fromSSA a: Int) -> Int {
        let h = ((a - 1) % 4) + 1
        guard (1...3).contains(h) else { return 2 }
        if a >= 9 { return h + 3 }       // middle
        if a >= 5 { return h + 6 }       // top
        return h
    }

    /// "0:01:02.34" (centiseconds) → milliseconds.
    static func parseTime(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let secParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard let sec = Int(secParts[0]) else { return nil }
        var frac = secParts.count > 1 ? String(secParts[1]) : "0"
        while frac.count < 3 { frac += "0" }
        let ms = Int(frac.prefix(3)) ?? 0
        return ((h * 60 + m) * 60 + sec) * 1000 + ms
    }

    /// Dialogue text → SubRip-style lines.
    static func convertText(_ raw: String, style: Style, ssa: Bool) -> [String] {
        var out = ""
        var bold = style.bold, italic = style.italic, underline = style.underline, strike = style.strike
        var alignment = style.alignment
        var drawing = false
        // Open the style's own formatting.
        if bold { out += "<b>" }
        if italic { out += "<i>" }
        if underline { out += "<u>" }
        if strike { out += "<s>" }
        func toggle(_ tag: String, _ state: inout Bool, _ on: Bool) {
            guard state != on else { return }
            out += on ? "<\(tag)>" : "</\(tag)>"
            state = on
        }
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "{", let close = raw[i...].firstIndex(of: "}") {
                let block = raw[raw.index(after: i)..<close]
                if block.contains("\\") {
                    for tag in block.split(separator: "\\").map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty {
                        func flag(_ name: String) -> Bool? {
                            guard tag.hasPrefix(name) else { return nil }
                            let v = tag.dropFirst(name.count)
                            if v.isEmpty { return nil }          // "\b" alone restores the style: treat as off
                            guard let n = Int(v) else { return nil }
                            return n != 0 && !(name == "b" && n < 500 && n > 1)
                        }
                        if tag.hasPrefix("blur") || tag.hasPrefix("bord") || tag.hasPrefix("be") { continue }
                        if tag.hasPrefix("an"), let n = Int(tag.dropFirst(2)) { alignment = n; continue }
                        if tag.hasPrefix("a") && !tag.hasPrefix("alpha"), let n = Int(tag.dropFirst(1)) { alignment = numpad(fromSSA: n); continue }
                        if tag.hasPrefix("p") && !tag.hasPrefix("pos") && !tag.hasPrefix("pbo"), let n = Int(tag.dropFirst(1)) { drawing = n > 0; continue }
                        if tag.hasPrefix("r") {
                            // Reset to the line's style.
                            toggle("s", &strike, style.strike); toggle("u", &underline, style.underline)
                            toggle("i", &italic, style.italic); toggle("b", &bold, style.bold)
                            continue
                        }
                        if let v = flag("b") { toggle("b", &bold, v) }
                        else if tag == "b" { toggle("b", &bold, style.bold) }
                        else if let v = flag("i") { toggle("i", &italic, v) }
                        else if let v = flag("u") { toggle("u", &underline, v) }
                        else if let v = flag("s"), !tag.hasPrefix("shad") { toggle("s", &strike, v) }
                    }
                }
                // Blocks without a backslash are comments; either way the braces go.
                i = raw.index(after: close)
                continue
            }
            if drawing { i = raw.index(after: i); continue }
            if c == "\\", raw.index(after: i) < raw.endIndex {
                let n = raw[raw.index(after: i)]
                if n == "N" { out += "\n"; i = raw.index(i, offsetBy: 2); continue }
                if n == "n" { out += " "; i = raw.index(i, offsetBy: 2); continue }     // soft break
                if n == "h" { out += "\u{00A0}"; i = raw.index(i, offsetBy: 2); continue }
            }
            out.append(c)
            i = raw.index(after: i)
        }
        // Close whatever is still open, innermost first.
        toggle("s", &strike, false); toggle("u", &underline, false); toggle("i", &italic, false); toggle("b", &bold, false)
        // Drop empty tag pairs left by toggles around nothing.
        for tag in ["b", "i", "u", "s"] { out = out.replacingOccurrences(of: "<\(tag)></\(tag)>", with: "") }
        var lines = out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        lines = lines.filter { !SubtitleDocument.plain($0).isEmpty }
        guard !lines.isEmpty else { return [] }
        if (7...9).contains(alignment) { lines[0] = "{\\an8}" + lines[0] }
        return lines
    }

    // MARK: Writing

    static func timestamp(_ ms: Int) -> String {
        let cs = (max(0, ms) + 5) / 10
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
    }

    static func write(_ cues: [SubtitleCue], ssa: Bool, title: String, sourceIsVTT: Bool) -> String {
        var out = """
        [Script Info]
        ; Script generated by NurTo
        Title: \(title.replacingOccurrences(of: "\n", with: " "))
        ScriptType: \(ssa ? "v4.00" : "v4.00+")
        WrapStyle: 0
        PlayResX: 1920
        PlayResY: 1080
        ScaledBorderAndShadow: yes

        """
        if ssa {
            out += """

            [V4 Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
            Style: Default,Arial,64,16777215,255,0,0,0,0,1,3,1,2,40,40,50,0,1

            [Events]
            Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

            """
        } else {
            out += """

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,50,1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

            """
        }
        for cue in cues {
            var lines = cue.lines.map { sourceIsVTT ? SubtitleDocument.vttToSRTText($0) : $0 }
            lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.isEmpty { continue }
            var top = false
            if let first = lines.first, let r = first.range(of: #"\{\\an[789]\}"#, options: .regularExpression) {
                top = true
                lines[0].removeSubrange(r)
            }
            if cue.settings.range(of: #"line:(0|1|2|3)(\s|$)|line:[0-2]?[0-9](\.\d+)?%"#, options: .regularExpression) != nil { top = true }
            var text = lines.map(assText).joined(separator: "\\N")
            if top { text = (ssa ? "{\\a6}" : "{\\an8}") + text }
            let start = timestamp(cue.start), end = timestamp(cue.end)
            out += ssa ? "Dialogue: Marked=0,\(start),\(end),Default,,0,0,0,,\(text)\n"
                       : "Dialogue: 0,\(start),\(end),Default,,0,0,0,,\(text)\n"
        }
        return out
    }

    /// SubRip-style markup → ASS override tags.
    static func assText(_ line: String) -> String {
        var t = SubtitleDocument.decodeEntities(line)
        // Keep existing ASS overrides from SRT files ({\an8} handled separately), drop the rest of the braces.
        let replacements: [(String, String)] = [
            (#"<\s*b\s*>"#, "{\\\\b1}"), (#"<\s*/\s*b\s*>"#, "{\\\\b0}"),
            (#"<\s*i\s*>"#, "{\\\\i1}"), (#"<\s*/\s*i\s*>"#, "{\\\\i0}"),
            (#"<\s*u\s*>"#, "{\\\\u1}"), (#"<\s*/\s*u\s*>"#, "{\\\\u0}"),
            (#"<\s*s\s*>"#, "{\\\\s1}"), (#"<\s*/\s*s\s*>"#, "{\\\\s0}"),
            (#"<\s*/\s*font\s*>"#, "{\\\\c}"),
        ]
        for (pattern, template) in replacements {
            t = t.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        // <font color="#RRGGBB"> → {\c&HBBGGRR&}
        if let re = try? NSRegularExpression(pattern: #"<\s*font[^>]*color\s*=\s*["']?#?([0-9a-fA-F]{6})["']?[^>]*>"#, options: [.caseInsensitive]) {
            let ns = t as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)).uppercased()
                let r = hex.prefix(2), g = hex.dropFirst(2).prefix(2), b = hex.suffix(2)
                result += "{\\c&H\(b)\(g)\(r)&}"
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            t = result
        }
        // Any other HTML-ish tag goes.
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return t.replacingOccurrences(of: "\n", with: "\\N")
    }
}
