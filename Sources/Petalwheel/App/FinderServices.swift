import AppKit

/// The Finder Services Petalwheel registers (NSServices in Info.plist, see scripts/build-app.sh).
/// `message` must match the NSMessage key and the @objc selector prefix below.
enum PetalwheelService: String, CaseIterable, Identifiable {
    case openInWheel, convertToJPG, compress, convertToMP4

    var id: String { rawValue }
    var message: String { rawValue }

    var menuTitle: String {
        switch self {
        case .openInWheel: return "Petalwheel: Open in Wheel"
        case .convertToJPG: return "Petalwheel: Convert to JPG"
        case .compress: return "Petalwheel: Compress"
        case .convertToMP4: return "Petalwheel: Convert to MP4"
        }
    }

    /// Title shown in Petalwheel's own UI (the Services menu itself is localized by ServicesMenu.strings).
    var localizedTitle: String {
        switch self {
        case .openInWheel: return L("Petalwheel: Open in Wheel")
        case .convertToJPG: return L("Petalwheel: Convert to JPG")
        case .compress: return L("Petalwheel: Compress")
        case .convertToMP4: return L("Petalwheel: Convert to MP4")
        }
    }

    var symbol: String {
        switch self {
        case .openInWheel: return "circle.hexagongrid.circle"
        case .convertToJPG: return "photo"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .convertToMP4: return "film"
        }
    }

    /// Key pbs uses in its NSServicesStatus preference for this service.
    var statusKey: String {
        "\(Bundle.main.bundleIdentifier ?? "studio.kipper.Petalwheel") - \(menuTitle) - \(message)"
    }
}

/// `NSApp.servicesProvider`. Each method receives the Finder selection on the pasteboard.
@MainActor
final class FinderServicesProvider: NSObject {
    @objc(openInWheel:userData:error:)
    func openInWheel(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform(.openInWheel, pboard, error)
    }

    @objc(convertToJPG:userData:error:)
    func convertToJPG(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform(.convertToJPG, pboard, error)
    }

    @objc(compress:userData:error:)
    func compress(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform(.compress, pboard, error)
    }

    @objc(convertToMP4:userData:error:)
    func convertToMP4(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform(.convertToMP4, pboard, error)
    }

    private func perform(_ service: PetalwheelService, _ pboard: NSPasteboard,
                         _ error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pboard)
        NSLog("Petalwheel: service %@ invoked with %ld file(s)", service.message, urls.count)
        guard !urls.isEmpty else {
            error.pointee = L("Petalwheel: no files were passed to the service.") as NSString
            return
        }
        // Let the Services menu close before the wheel / HUD takes over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            switch service {
            case .openInWheel:
                Integrations.showFan?(urls)
            case .convertToJPG:
                Integrations.runItem?(FanItem(kind: .format(.jpg), title: FileFormat.jpg.title, symbol: nil), urls)
            case .convertToMP4:
                Integrations.runItem?(FanItem(kind: .format(.mp4), title: FileFormat.mp4.title, symbol: nil), urls)
            case .compress:
                Integrations.runItem?(FanItem(kind: .tool(.compress), title: FileTool.compress.title,
                                              symbol: FileTool.compress.symbol), urls)
            }
        }
    }

    static func fileURLs(from pboard: NSPasteboard) -> [URL] {
        if let urls = pboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.standardizedFileURL)
        }
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pboard.propertyList(forType: legacy) as? [String] {
            return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        return []
    }
}

/// Read-only status of the services for the Settings tab.
enum FinderServicesStatus {
    /// Whether the running bundle declares NSServices (false when run via `swift run`).
    static var declaredInBundle: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [Any])?.isEmpty == false
    }

    /// nil = user never changed it (on by default, thanks to NSRequiredContext); otherwise the context-menu switch.
    static func userEnabled(_ service: PetalwheelService) -> Bool? {
        guard let all = UserDefaults(suiteName: "pbs")?.dictionary(forKey: "NSServicesStatus"),
              let entry = all[service.statusKey] as? [String: Any] else { return nil }
        if let v = entry["enabled_context_menu"] as? Bool { return v }
        if let v = entry["enabled_services_menu"] as? Bool { return v }
        return nil
    }

    static func openKeyboardShortcutsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Services",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Re-registers the services with pbs (equivalent to `pbs -update`).
    static func refresh() {
        NSUpdateDynamicServices()
    }
}
