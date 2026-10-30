import Foundation

/// One-time migration from the app's earlier names:
/// preferences from `dev.kumquat.Kumquat` and `studio.kipper.Kumquat` (Kumquat 1.0.x), and the
/// `~/Library/Application Support/Kumquat` folder (history, presets, watch folders).
enum PreferencesMigration {
    private static let oldDomains = ["studio.kipper.Petalwheel", "studio.kipper.Kumquat", "dev.kumquat.Kumquat"]
    private static let doneKey = "migratedToNurToV1"

    static func run() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "nurtoEnglishV1") {
            defaults.set(["en"], forKey: "AppleLanguages")
            defaults.set(true, forKey: "nurtoEnglishV1")
        }
        if !defaults.bool(forKey: "nurtoCtrlWheelV1") {
            defaults.set("control", forKey: "triggerKey")
            defaults.set(true, forKey: "nurtoCtrlWheelV1")
        }
        guard !defaults.bool(forKey: doneKey) else { return }
        for domain in oldDomains {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set("control", forKey: "triggerKey")
        migrateSupportFolder()
        defaults.set(true, forKey: doneKey)
    }

    private static func migrateSupportFolder() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let petalwheel = base.appendingPathComponent("Petalwheel", isDirectory: true)
        let old = fm.fileExists(atPath: petalwheel.path) ? petalwheel : base.appendingPathComponent("Kumquat", isDirectory: true)
        let new = base.appendingPathComponent("NurTo", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.copyItem(at: old, to: new)
    }
}
