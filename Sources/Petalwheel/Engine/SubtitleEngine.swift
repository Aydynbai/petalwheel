import Foundation

/// SubRip (srt) ↔ WebVTT (vtt), and either → plain text transcript.
struct SubtitleEngine: ConversionEngine {
    init() {}

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        [.srt, .vtt].contains(source) && [.srt, .vtt, .txt].contains(target)
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw NurToError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        progress(0.1)
        let text = try DocumentTextDecoder.decode(contentsOf: source)
        let cues = SubtitleDocument.parse(text)
        guard !cues.isEmpty else {
            throw NurToError(l: "No subtitles found in “%@”.", source.lastPathComponent)
        }
        progress(0.6)
        let output: String
        switch target {
        case .srt: output = SubtitleDocument.srt(cues)
        case .vtt: output = SubtitleDocument.vtt(cues, sourceIsVTT: from == .vtt)
        default: output = SubtitleDocument.transcript(cues)
        }
        let url = OutputNaming.url(for: source, ext: target.rawValue)
        try output.write(to: url, atomically: true, encoding: .utf8)
        progress(1)
        return [url]
    }
}

struct SubtitleCue: Equatable {
    var identifier: String?
    var start: Int        // milliseconds
    var end: Int
    var settings: String  // WebVTT cue settings ("align:start line:0" …)
    var lines: [String]
}

enum SubtitleDocument {
    // MARK: Parsing

    static func parse(_ raw: String) -> [SubtitleCue] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard line.contains("-->"), let timing = parseTiming(line) else { i += 1; continue }
            // The identifier is the previous non-empty line if it directly precedes the timing.
            var identifier: String?
            if i > 0 {
                let prev = lines[i - 1].trimmingCharacters(in: .whitespaces)
                if !prev.isEmpty && !prev.contains("-->") && !prev.hasPrefix("WEBVTT") && !prev.hasPrefix("NOTE") {
                    identifier = prev
                }
            }
            var body: [String] = []
            i += 1
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty {
                    // An SRT cue may (rarely) contain an empty line; it continues only if the
                    // following text isn't a new cue (number + timing, or a timing line).
                    if i + 1 < lines.count, !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty,
                       !lines[i + 1].contains("-->"),
                       !(i + 2 < lines.count && lines[i + 2].contains("-->")),
                       !lines[i + 1].hasPrefix("NOTE") {
                        let lookahead = lines[i + 1]
                        if Int(lookahead.trimmingCharacters(in: .whitespaces)) == nil { i += 1; continue }
                    }
                    break
                }
                if l.contains("-->"), parseTiming(l) != nil { break }
                body.append(l)
                i += 1
            }
            // Drop a trailing numeric line that is really the next SRT cue's index.
            if let last = body.last, Int(last.trimmingCharacters(in: .whitespaces)) != nil,
               i < lines.count, lines[i].contains("-->") {
                body.removeLast()
            }
            cues.append(SubtitleCue(identifier: identifier, start: timing.0, end: timing.1, settings: timing.2, lines: body))
        }
        return cues
    }

    static func parseTiming(_ line: String) -> (Int, Int, String)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2, let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let rest = parts[1].trimmingCharacters(in: .whitespaces)
        let endToken = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = endToken.first, let end = parseTimestamp(String(first)) else { return nil }
        let settings = endToken.count > 1 ? String(endToken[1]).trimmingCharacters(in: .whitespaces) : ""
        // SRT coordinates ("X1:… Y2:…") aren't WebVTT settings.
        let cleaned = settings.split(separator: " ").filter { !$0.hasPrefix("X") && !$0.hasPrefix("Y") }.joined(separator: " ")
        return (start, end, cleaned)
    }

    /// "01:02:03,456", "02:03.456", "1:02:03.4" → milliseconds.
    static func parseTimestamp(_ s: String) -> Int? {
        guard let m = MarkdownToHTML.match(#"^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[,.:](\d{1,3}))?$"#, s) else { return nil }
        let h = Int(m[1]) ?? 0, mi = Int(m[2]) ?? 0, sec = Int(m[3]) ?? 0
        var frac = m[4]
        while frac.count < 3 { frac += "0" }
        return ((h * 60 + mi) * 60 + sec) * 1000 + (Int(frac) ?? 0)
    }

    static func timestamp(_ ms: Int, separator: Character) -> String {
        let v = max(0, ms)
        let h = v / 3_600_000, m = v / 60_000 % 60, s = v / 1000 % 60, f = v % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, String(separator), f)
    }

    // MARK: Writing

    static func srt(_ cues: [SubtitleCue]) -> String {
        var out = ""
        var n = 0
        for cue in cues {
            var lines = cue.lines.map(vttToSRTText).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.isEmpty { continue }
            if isTopPositioned(cue.settings) { lines[0] = "{\\an8}" + lines[0] }
            n += 1
            out += "\(n)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n"
            out += lines.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    static func vtt(_ cues: [SubtitleCue], sourceIsVTT: Bool = false) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            var settings = cue.settings
            var lines = cue.lines
            if let first = lines.first, first.contains("{\\an8}") || first.contains("{\\an7}") || first.contains("{\\an9}") {
                if !settings.contains("line:") { settings = (settings + " line:0").trimmingCharacters(in: .whitespaces) }
            }
            lines = (sourceIsVTT ? lines : lines.map(srtToVTTText)).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.isEmpty { continue }
            if let id = cue.identifier, Int(id) == nil, !id.contains("-->") { out += id + "\n" }
            out += "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))"
            if !settings.isEmpty { out += " " + settings }
            out += "\n" + lines.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    /// Plain transcript: no tags, no timings, consecutive duplicate lines (rolling captions) removed.
    static func transcript(_ cues: [SubtitleCue]) -> String {
        var out: [String] = []
        for cue in cues {
            for raw in cue.lines {
                let line = plain(raw)
                if line.isEmpty { continue }
                if out.suffix(3).contains(line) { continue }
                out.append(line)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Text conversion

    private static func isTopPositioned(_ settings: String) -> Bool {
        guard let m = MarkdownToHTML.match(#"line:(-?\d+(?:\.\d+)?)(%?)"#, settings) else { return false }
        let v = Double(m[1]) ?? 100
        return m[2] == "%" ? v < 30 : (v >= 0 && v <= 3)
    }

    /// WebVTT cue text → SubRip: keep b/i/u, drop voice/class/lang/ruby/timestamp tags, decode entities.
    static func vttToSRTText(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"<v(?:\.[^ >]*)?\s+([^>]*)>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"</?(?:c|v|lang|ruby|rt)(?:[.\s][^>]*)?>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<\d{1,2}:\d{2}(?::\d{2})?[.,]\d{3}>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<(/?)([biu])\.[^>]*>"#, with: "<$1$2>", options: .regularExpression)
        return decodeEntities(t)
    }

    /// SubRip text → WebVTT: drop ASS overrides and <font>, keep b/i/u, escape stray & and <.
    static func srtToVTTText(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"</?font[^>]*>"#, with: "", options: .regularExpression)
        // Protect allowed tags, escape the rest.
        t = t.replacingOccurrences(of: #"&(?![a-zA-Z]+;|#\d+;)"#, with: "&amp;", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<(?!/?[biu]>)"#, with: "&lt;", options: .regularExpression)
        t = t.replacingOccurrences(of: "-->", with: "--&gt;")
        return t
    }

    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<(/?[A-Za-z][^<>]*|\d[\d:.,]*)>"#, with: "", options: .regularExpression)
        t = decodeEntities(t)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", "\u{00A0}"), ("&lrm;", "\u{200E}"), ("&rlm;", "\u{200F}"),
                       ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }
}
