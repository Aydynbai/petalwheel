import Foundation

/// One-time copy of preferences from the pre-rename bundle id (dev.kumquat.Kumquat → studio.kipper.Kumquat).
enum PreferencesMigration {
    private static let oldDomain = "dev.kumquat.Kumquat"
    private static let doneKey = "migratedFromDevKumquat"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey),
              let old = UserDefaults.standard.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }
}
