import Foundation

/// One-time migration from the app's earlier names:
/// preferences from `dev.kumquat.Kumquat` and `studio.kipper.Kumquat` (Kumquat 1.0.x), and the
/// `~/Library/Application Support/Kumquat` folder (history, presets, watch folders).
enum PreferencesMigration {
    private static let oldDomains = ["studio.kipper.Kumquat", "dev.kumquat.Kumquat"]
    private static let doneKey = "migratedFromKumquat"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        for domain in oldDomains {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        migrateSupportFolder()
        defaults.set(true, forKey: doneKey)
    }

    private static func migrateSupportFolder() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent("Kumquat", isDirectory: true)
        let new = base.appendingPathComponent("Petalwheel", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.copyItem(at: old, to: new)
    }
}
