import AppKit
import SwiftUI

/// State for the Integrations tab that isn't owned by a long-lived service (recorder, permission status).
@MainActor
final class IntegrationsSettingsModel: ObservableObject {
    @Published var finderPermission: FinderSelection.Permission = .unknown
    @Published var servicesState: [NurToService: Bool?] = [:]
    private var keyMonitor: Any?

    func refresh() {
        FinderSelection.permission { [weak self] p in self?.finderPermission = p }
        var states: [NurToService: Bool?] = [:]
        for s in NurToService.allCases { states[s] = FinderServicesStatus.userEnabled(s) }
        servicesState = states
    }

    // MARK: Shortcut recorder

    func startRecording() {
        guard keyMonitor == nil else { return }
        GlobalHotkey.shared.isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {                         // Escape: cancel
                self.stopRecording()
            } else if let combo = HotkeyCombo(event: event) {
                GlobalHotkey.shared.combo = combo
                self.stopRecording()
            } else {
                NSSound.beep()                               // needs ⌘, ⌥ or ⌃
            }
            return nil
        }
    }

    func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        GlobalHotkey.shared.isRecording = false
    }
}

/// Settings › Integrations: Finder Services, global hotkey, watch folders.
struct IntegrationsSettingsView: View {
    @ObservedObject var hotkey = GlobalHotkey.shared
    @ObservedObject var store = WatchFolderStore.shared
    @StateObject private var model = IntegrationsSettingsModel()

    var body: some View {
        Form {
            servicesSection
            hotkeySection
            watchFoldersSection
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        .onDisappear { model.stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    // MARK: Services

    private var servicesSection: some View {
        Section {
            ForEach(NurToService.allCases) { service in
                HStack(spacing: 8) {
                    Image(systemName: service.symbol)
                        .foregroundStyle(KQTheme.accentText)
                        .frame(width: 18)
                    Text(service.localizedTitle).font(.system(size: 12))
                    Spacer()
                    statusDot(serviceStatus(service))
                }
            }
            HStack {
                Text(FinderServicesStatus.declaredInBundle
                     ? L("Right-click files in Finder › Quick Actions or Services. If an item is missing, turn it on under Keyboard › Keyboard Shortcuts › Services › Files and Folders.")
                     : L("Services are available when running the bundled NurTo.app."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open Keyboard Shortcuts…") { FinderServicesStatus.openKeyboardShortcutsSettings() }
                    .controlSize(.small)
            }
        } header: {
            Text("Finder Services")
        }
    }

    private func serviceStatus(_ service: NurToService) -> (String, Color) {
        guard FinderServicesStatus.declaredInBundle else { return (L("Not registered"), .secondary) }
        switch model.servicesState[service] ?? nil {
        case .some(false): return (L("Off in System Settings"), KQTheme.warning)
        default: return (L("On"), KQTheme.success)
        }
    }

    // MARK: Hotkey

    private var hotkeySection: some View {
        Section {
            Toggle("Open the wheel for the Finder selection", isOn: $hotkey.enabled)
            HStack {
                Text("Shortcut")
                Spacer()
                Button {
                    hotkey.isRecording ? model.stopRecording() : model.startRecording()
                } label: {
                    Text(hotkey.isRecording ? L("Type shortcut…") : hotkey.combo.displayString)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 96)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hotkey.isRecording ? KQTheme.accent.opacity(0.18) : Color.primary.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(hotkey.isRecording ? KQTheme.accent : Color.primary.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!hotkey.enabled)
                .help("Click, then press a key with ⌘, ⌥ or ⌃. Escape cancels.")
                if hotkey.combo != .default {
                    Button { hotkey.resetToDefault() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help(L("Reset to %@", HotkeyCombo.default.displayString))
                }
            }
            if let error = hotkey.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(KQTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                statusDot(permissionStatus)
                Spacer()
                if model.finderPermission == .denied {
                    Button("Open Automation Settings…") { FinderSelection.openAutomationSettings() }
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Global Shortcut")
        } footer: {
            Text("Select files in Finder and press the shortcut. The first time, macOS asks to let NurTo control Finder.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var permissionStatus: (String, Color) {
        switch model.finderPermission {
        case .allowed: return (L("Finder access allowed"), KQTheme.success)
        case .notDetermined: return (L("Finder access: asked on first use"), .secondary)
        case .denied: return (L("Finder access denied"), KQTheme.danger)
        case .finderNotRunning: return (L("Finder isn't running"), KQTheme.warning)
        case .unknown: return (L("Finder access: unknown"), .secondary)
        }
    }

    // MARK: Watch folders

    private var watchFoldersSection: some View {
        Section {
            if let err = store.loadError {
                Text(err).font(.system(size: 11)).foregroundStyle(KQTheme.danger)
            }
            if store.folders.isEmpty {
                Text("No watch folders yet. New files dropped into a watched folder are converted automatically.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.folders) { folder in
                WatchFolderRow(folder: folder, status: store.status[folder.id] ?? WatchFolderStatus(), store: store)
            }
            HStack {
                Button { store.chooseAndAdd() } label: { Label("Add Folder…", systemImage: "plus") }
                Spacer()
            }
        } header: {
            Text("Watch Folders")
        } footer: {
            Text("Only files added after watching starts are processed, once they stop changing for 2 seconds. Results are saved next to the originals; NurTo's own outputs are ignored.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func statusDot(_ status: (String, Color)) -> some View {
        HStack(spacing: 5) {
            Circle().fill(status.1).frame(width: 7, height: 7)
            Text(status.0).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct WatchFolderRow: View {
    let folder: WatchFolder
    let status: WatchFolderStatus
    let store: WatchFolderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: status.missing ? "folder.badge.questionmark" : "folder.fill")
                    .foregroundStyle(status.missing ? KQTheme.danger : KQTheme.accentText)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name).font(.system(size: 12, weight: .semibold))
                        .strikethrough(status.missing)
                    Text((folder.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Toggle("", isOn: binding(\.enabled)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Button { store.reveal(folder) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder").disabled(status.missing)
                Button { store.remove(folder.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Stop watching")
            }
            HStack(spacing: 8) {
                Picker("Action", selection: binding(\.action)) {
                    Section("Convert") {
                        ForEach(WatchAction.all.filter { if case .format = $0 { return true } else { return false } }) {
                            Text($0.title).tag($0)
                        }
                    }
                    Section("Tools") {
                        ForEach(WatchAction.allowedTools.map(WatchAction.tool)) { Text($0.title).tag($0) }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                Picker("Originals", selection: binding(\.originals)) {
                    ForEach(OriginalsPolicy.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            .controlSize(.small)
            Text(statusLine)
                .font(.system(size: 10))
                .foregroundStyle(status.missing ? KQTheme.danger : Color.secondary)
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, 30)
        }
        .padding(.vertical, 2)
        .opacity(folder.enabled ? 1 : 0.6)
    }

    private var statusLine: String {
        if status.missing { return L("Missing: the folder was moved or deleted") }
        if !folder.enabled { return L("Paused") }
        var parts: [String] = []
        if let msg = status.lastMessage { parts.append(msg) } else { parts.append(L("Watching")) }
        if status.processed > 0 { parts.append(L("%d processed", status.processed)) }
        if let date = status.lastDate {
            parts.append(date.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private func binding<T>(_ keyPath: WritableKeyPath<WatchFolder, T>) -> Binding<T> {
        Binding(get: { folder[keyPath: keyPath] }, set: { value in
            var f = folder
            f[keyPath: keyPath] = value
            store.update(f)
        })
    }
}
