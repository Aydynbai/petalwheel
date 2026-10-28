import Foundation

/// Removes references to remote resources from HTML before it is handed to textutil, so a
/// conversion never reaches the network. Local images (relative paths, file: and data: URLs)
/// and ordinary links (`<a href>`, which are never fetched) are kept.
enum HTMLRemoteStripper {
    /// `http:`, `https:` or protocol-relative (`//host`) URLs.
    private static let remote = #"(?:https?:)?//"#

    private static let rules: [(pattern: String, template: String)] = [
        // <link rel="stylesheet|icon|preload…" href="http…">: drop the whole tag.
        (#"<link\b[^>]*\bhref\s*=\s*["']?\s*"# + remote + #"[^>]*>"#, ""),
        // <script src="http…"></script>
        (#"<script\b[^>]*\bsrc\s*=\s*["']?\s*"# + remote + #"[^>]*>\s*</script\s*>"#, ""),
        // src / poster / background / data / lowsrc attributes pointing at remote URLs.
        (#"\b(src|poster|background|data|lowsrc|dynsrc)\s*=\s*(["'])\s*"# + remote + #"[^"']*\2"#, "$1=$2$2"),
        (#"\b(src|poster|background|data|lowsrc|dynsrc)\s*=\s*"# + remote + #"[^\s>]*"#, "$1=\"\""),
        // srcset lists: drop entirely if any candidate is remote.
        (#"\bsrcset\s*=\s*(["'])[^"']*"# + remote + #"[^"']*\1"#, ""),
        // CSS: @import of remote stylesheets and url(…) references.
        (#"@import\s+(?:url\()?\s*["']?\s*"# + remote + #"[^;]*;"#, ""),
        (#"url\(\s*["']?\s*"# + remote + #"[^)]*\)"#, "url()"),
        // <meta http-equiv="refresh" content="0; url=http…">
        (#"<meta\b[^>]*http-equiv\s*=\s*["']?refresh[^>]*>"#, ""),
    ]

    static func strip(_ html: String) -> String {
        var result = html
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: rule.template)
        }
        return result
    }

    /// Writes a stripped copy of `url` into `directory` (keeping the file name) and returns it.
    /// Falls back to the original file if it can't be decoded as text.
    static func strippedCopy(of url: URL, in directory: URL) -> URL {
        guard let data = try? Data(contentsOf: url) else { return url }
        let encoding: String.Encoding
        let text: String
        if let s = String(data: data, encoding: .utf8) { text = s; encoding = .utf8 }
        else if let s = String(data: data, encoding: .windowsCP1251) { text = s; encoding = .windowsCP1251 }
        else if let s = String(data: data, encoding: .isoLatin1) { text = s; encoding = .isoLatin1 }
        else { return url }
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try strip(text).write(to: copy, atomically: true, encoding: encoding)
            return copy
        } catch {
            return url
        }
    }
}
