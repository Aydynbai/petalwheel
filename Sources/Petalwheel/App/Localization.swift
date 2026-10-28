import Foundation

// Localization helpers. Strings live in Resources/{en,ru}.lproj/Localizable.strings and are copied into
// Petalwheel.app/Contents/Resources by scripts/build-app.sh. The English text is the key, so a missing
// translation falls back to English. SwiftUI `Text("literal")` looks the literal up by itself; everything
// built from a String (AppKit titles, computed titles, interpolations) goes through `L` / `Lp`.

enum L10n {
    /// Bundle that holds the lproj folders (the app bundle).
    static var bundle: Bundle = .main

    /// The localization actually in use ("en" or "ru").
    static var language: String { bundle.preferredLocalizations.first ?? "en" }

    /// CLDR plural category for `n` in the current language.
    static func pluralCategory(_ n: Int) -> String {
        let n = abs(n)
        if language.hasPrefix("ru") {
            let m10 = n % 10, m100 = n % 100
            if m10 == 1 && m100 != 11 { return "one" }
            if (2...4).contains(m10) && !(12...14).contains(m100) { return "few" }
            return "many"
        }
        return n == 1 ? "one" : "other"
    }

    static func lookup(_ key: String) -> String? {
        let missing = "\u{1}missing\u{1}"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }
}

/// Localized string for an English key.
func L(_ key: String) -> String {
    L10n.lookup(key) ?? key
}

/// Localized format string for an English key (`%@`, `%d`, `%.1f`…), filled with `args`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

/// Plural-aware lookup. `key` is the English format (e.g. "%d files"); the tables hold one entry per
/// plural category as "key#one", "key#few", "key#many", "key#other". `n` is the first format argument.
func Lp(_ key: String, _ n: Int, _ more: CVarArg...) -> String {
    let category = L10n.pluralCategory(n)
    let format = L10n.lookup("\(key)#\(category)") ?? L10n.lookup("\(key)#other")
        ?? L10n.lookup("\(key)#many") ?? key
    return String(format: format, locale: Locale.current, arguments: [n] + more)
}
