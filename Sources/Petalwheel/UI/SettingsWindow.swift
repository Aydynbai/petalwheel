import AppKit
import SwiftUI
import ServiceManagement

/// Settings window (General / Conversion / About).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = KQWindowing.makeWindow(title: L("Petalwheel Settings"), size: NSSize(width: 560, height: 520),
                                           content: SettingsView())
            w.titlebarAppearsTransparent = false
            w.styleMask.remove(.fullSizeContentView)
            w.collectionBehavior = [.moveToActiveSpace]
            window = w
        }
        KQWindowing.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Launch at login

final class LoginItemModel: ObservableObject {
    @Published var status: SMAppService.Status = .notRegistered
    @Published var errorMessage: String?

    var isInAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() { refresh() }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    var statusText: String {
        if !isInAppBundle { return L("Available when running from Petalwheel.app") }
        switch status {
        case .enabled: return L("Petalwheel opens when you log in")
        case .requiresApproval: return L("Needs approval in System Settings → General → Login Items")
        case .notRegistered: return L("Off")
        case .notFound: return L("Not available for this copy of the app")
        @unknown default: return L("Unknown")
        }
    }

    func set(_ on: Bool) {
        errorMessage = nil
        guard isInAppBundle else {
            errorMessage = L("Launch at login only works from the bundled Petalwheel.app (build it with scripts/build-app.sh).")
            return
        }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Language

/// Interface language override, stored as the app's own `AppleLanguages` default.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("language.system")   // "System"
        case .en: return "English"
        case .ru: return "Русский"
        }
    }

    private static var domain: String { Bundle.main.bundleIdentifier ?? "studio.kipper.Petalwheel" }

    /// The saved choice (ignores a one-off `-AppleLanguages` launch argument).
    static var saved: AppLanguage {
        let langs = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String]
        guard let first = langs?.first else { return .system }
        if first.hasPrefix("ru") { return .ru }
        if first.hasPrefix("en") { return .en }
        return .system
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Starts a fresh instance of the app, then quits this one.
    @MainActor static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NSLog("Petalwheel: relaunch failed: %@", error.localizedDescription)
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}

final class LanguageModel: ObservableObject {
    @Published var selection: AppLanguage = AppLanguage.saved

    @MainActor func choose(_ language: AppLanguage) {
        guard language != selection else { return }
        selection = language
        language.save()
        // Let the picker's menu close before the alert appears.
        DispatchQueue.main.async { Self.offerRestart() }
    }

    @MainActor private static func offerRestart() {
        let alert = NSAlert()
        alert.messageText = L("Restart Petalwheel now?")
        alert.informativeText = L("The new language is used after Petalwheel restarts.")
        alert.addButton(withTitle: L("Restart Now"))
        alert.addButton(withTitle: L("Later"))
        KQWindowing.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            AppLanguage.relaunch()
        }
    }
}

// MARK: - Views

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ConversionSettingsView()
                .tabItem { Label("Conversion", systemImage: "arrow.triangle.2.circlepath") }
            PresetsSettingsView()
                .padding(16)
                .tabItem { Label("Presets", systemImage: "star") }
            IntegrationsSettingsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .tint(KQTheme.accent)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var login = LoginItemModel()
    @StateObject private var language = LanguageModel()

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: Binding(get: { language.selection }, set: { language.choose($0) })) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Picker("Wheel key", selection: $settings.triggerKey) {
                    ForEach(ModifierKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
            } header: {
                Text("While dragging files, tap this key to open the wheel")
            } footer: {
                Text("Hover a category (Convert, Optimize, Edit…) to open it; hover the centre to go back.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Sounds and haptics", isOn: $settings.soundsEnabled)
                Toggle("Reveal results in Finder", isOn: $settings.revealOutputs)
            }

            GeneralExtrasSettingsSection()

            Section {
                Toggle("Launch at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                    .disabled(!login.isInAppBundle)
                HStack(spacing: 6) {
                    Circle()
                        .fill(login.status == .enabled ? KQTheme.success : (login.status == .requiresApproval ? KQTheme.warning : Color.secondary))
                        .frame(width: 7, height: 7)
                    Text(login.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if login.status == .requiresApproval {
                        Button("Open Login Items…") { login.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }
                if let err = login.errorMessage {
                    Text(err).font(.system(size: 11)).foregroundStyle(KQTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}

struct ConversionSettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Default quality", selection: $settings.conversionQuality) {
                    ForEach(Quality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(qualityHint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Preserve metadata", isOn: $settings.preserveMetadata)
                Text("Keep EXIF, dates and location in converted files when the format allows it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                Label("Converted files are saved next to the originals.", systemImage: "folder")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var qualityHint: String {
        switch settings.conversionQuality {
        case .compact: return L("Smallest files, visibly lower quality.")
        case .balanced: return L("Good quality at a reasonable size.")
        case .high: return L("Best quality, larger files.")
        }
    }
}

struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = info?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    var body: some View {
        VStack(spacing: 14) {
            PetalwheelMark()
                .frame(width: 72, height: 72)
            VStack(spacing: 2) {
                Text("Petalwheel").font(.system(size: 22, weight: .bold, design: .rounded))
                Text(L("Version %@", version)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("Drag, tap a key, drop on a petal. Files convert right where they are.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Helpers").font(.system(size: 12, weight: .semibold))
                helperRow("ffmpeg", path: ExternalTools.shared.ffmpeg, purpose: L("video & audio"))
                helperRow("ffprobe", path: ExternalTools.shared.ffprobe, purpose: L("media info"))
                helperRow("cwebp", path: ExternalTools.shared.cwebp, purpose: L("WebP export"))
                if !ExternalTools.shared.hasFFmpeg || !ExternalTools.shared.hasWebPEncoder {
                    HStack(spacing: 6) {
                        Text("Install missing helpers:").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("brew install ffmpeg webp")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                        Button {
                            TextResultsWindow.copy("brew install ffmpeg webp")
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy command")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            Spacer(minLength: 0)
            CreditsView()
            HStack(spacing: 12) {
                Text(Credits.copyright).font(.system(size: 11)).foregroundStyle(.tertiary)
                Button("Licenses…") { Credits.showLicenses() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func helperRow(_ name: String, path: URL?, purpose: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: path != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(path != nil ? KQTheme.success : KQTheme.danger)
            Text(name).font(.system(size: 12, weight: .medium, design: .monospaced))
            Text(purpose).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(path?.path ?? L("not found"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        }
    }
}

// MARK: - Credits

enum Credits {
    static let copyright = "© 2026 kipperstudio"

    /// Contents/Resources/Tools/licenses (ffmpeg LGPL, libwebp, lame, opus, libvpx, dav1d, SVT-AV1…).
    static var licensesURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Tools/licenses", isDirectory: true),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    @MainActor static func showLicenses() {
        if let url = licensesURL {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("No licenses folder")
        alert.informativeText = L("This copy of Petalwheel doesn't include the bundled helpers, so there are no third-party licenses to show.")
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}

/// "Made by kipperstudio & Claude" with the Claude attribution underneath (About and Welcome).
struct CreditsView: View {
    var compact = false

    var body: some View {
        VStack(spacing: 2) {
            (Text(L("Made by")) + Text(verbatim: " ")
                + Text(verbatim: "kipperstudio").fontWeight(.semibold)
                + Text(verbatim: " ") + Text(L("credits.and")) + Text(verbatim: " ")
                + Text(verbatim: "Claude").fontWeight(.semibold).foregroundColor(KQTheme.accentText))
                .font(.system(size: compact ? 11 : 12, design: .rounded))
                .foregroundStyle(.secondary)
            if !compact {
                Text(L("Claude by Anthropic"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

/// Small Petalwheel glyph drawn in SwiftUI (used in About and Welcome): the app icon's wheel of petals.
struct PetalwheelMark: View {
    private static let petals: [UInt32] = [0xF07A22, 0x4F8A5B, 0xE3A72F, 0xC45A3C, 0x4A78A6, 0x3E8C86]

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(nsColor: KQPalette.rgb(0x362F29)),
                                                  Color(nsColor: KQPalette.rgb(0x1C1916))],
                                         startPoint: .top, endPoint: .bottom))
                ForEach(0..<Self.petals.count, id: \.self) { i in
                    PetalShape(index: i, count: Self.petals.count, inner: 0.17, outer: i == 0 ? 0.42 : 0.38)
                        .fill(Color(nsColor: KQPalette.rgb(Self.petals[i])))
                }
                Circle()
                    .fill(Color(nsColor: KQPalette.rgb(0xFBF4EA)))
                    .frame(width: s * 0.26, height: s * 0.26)
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// One annular-sector petal of the mark; radii are fractions of the view's size.
private struct PetalShape: Shape {
    let index: Int, count: Int
    let inner: CGFloat, outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let step = 2 * Double.pi / Double(count), gap = 0.09
        let mid = -Double.pi / 2 + Double(index) * step          // top first, clockwise (y grows down)
        let a0 = Angle(radians: mid - step / 2 + gap / 2), a1 = Angle(radians: mid + step / 2 - gap / 2)
        var p = Path()
        p.addArc(center: c, radius: s * outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: s * inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}
