import AppKit
import Combine

enum ModifierKey: String, CaseIterable, Identifiable {
    case option, command, control, shift
    var id: String { rawValue }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .command: return .command
        case .control: return .control
        case .shift: return .shift
        }
    }
    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }
    var title: String { "\(symbol) \(rawValue.capitalized)" }
}

/// Persistent user settings (UserDefaults-backed).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    /// The single key that opens the wheel while dragging.
    @Published var triggerKey: ModifierKey { didSet { d.set(triggerKey.rawValue, forKey: "triggerKey") } }
    @Published var soundsEnabled: Bool { didSet { d.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var revealOutputs: Bool { didSet { d.set(revealOutputs, forKey: "revealOutputs") } }
    @Published var conversionQuality: Quality { didSet { d.set(conversionQuality.rawValue, forKey: "conversionQuality") } }
    @Published var preserveMetadata: Bool { didSet { d.set(preserveMetadata, forKey: "preserveMetadata") } }
    @Published var hasCompletedWelcome: Bool { didSet { d.set(hasCompletedWelcome, forKey: "hasCompletedWelcome") } }

    private init() {
        triggerKey = ModifierKey(rawValue: d.string(forKey: "triggerKey") ?? "") ?? .shift
        soundsEnabled = d.object(forKey: "soundsEnabled") as? Bool ?? true
        revealOutputs = d.object(forKey: "revealOutputs") as? Bool ?? false
        conversionQuality = Quality(rawValue: d.string(forKey: "conversionQuality") ?? "") ?? .high
        preserveMetadata = d.object(forKey: "preserveMetadata") as? Bool ?? true
        hasCompletedWelcome = d.bool(forKey: "hasCompletedWelcome")
    }

    func mode(for key: ModifierKey) -> FanMode? {
        key == triggerKey ? .categories : nil
    }

    var conversionOptions: ConversionOptions {
        var o = ConversionOptions()
        o.quality = conversionQuality
        o.preserveMetadata = preserveMetadata
        return o
    }
}
