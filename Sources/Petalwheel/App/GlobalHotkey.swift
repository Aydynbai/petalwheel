import AppKit
import Carbon.HIToolbox
import Combine

// MARK: - Key combination

/// A Carbon hotkey: virtual key code + Carbon modifier mask (cmdKey, optionKey, …).
struct HotkeyCombo: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = HotkeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey | optionKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// From a key-down event. Requires ⌘, ⌥ or ⌃ (⇧ alone would steal typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: m)
    }

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: L("Space"), kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Character for the key in the current keyboard layout.
    static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

// MARK: - Global hotkey

private let hotkeySignature: OSType = 0x4B51_484B   // 'KQHK'

/// System-wide hotkey via Carbon `RegisterEventHotKey` (no Accessibility / Input Monitoring permission needed).
@MainActor
final class GlobalHotkey: ObservableObject {
    static let shared = GlobalHotkey()
    private let d = UserDefaults.standard

    @Published var enabled: Bool {
        didSet { d.set(enabled, forKey: "hotkeyEnabled"); reregister() }
    }
    @Published var combo: HotkeyCombo {
        didSet {
            d.set(Int(combo.keyCode), forKey: "hotkeyKeyCode")
            d.set(Int(combo.carbonModifiers), forKey: "hotkeyModifiers")
            reregister()
        }
    }
    @Published private(set) var isRegistered = false
    @Published private(set) var lastError: String?
    /// True while the Settings recorder is capturing (the hotkey is paused).
    @Published var isRecording = false { didSet { reregister() } }

    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var started = false

    private init() {
        enabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        if let code = d.object(forKey: "hotkeyKeyCode") as? Int, let mods = d.object(forKey: "hotkeyModifiers") as? Int {
            combo = HotkeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(mods))
        } else {
            combo = .default
        }
    }

    func start() {
        guard !started else { return }
        started = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr, id.signature == hotkeySignature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotkey.shared.fire() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        if status != noErr { NSLog("NurTo: InstallEventHandler failed (%d)", status) }
        reregister()
    }

    func resetToDefault() { combo = .default }

    private func fire() {
        NSLog("NurTo: global hotkey %@ pressed", combo.displayString)
        onPress?()
    }

    private func reregister() {
        guard started else { return }
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        isRegistered = false
        lastError = nil
        guard enabled, !isRecording else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotkeySignature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            isRegistered = true
            NSLog("NurTo: global hotkey %@ registered", combo.displayString)
        } else {
            lastError = status == OSStatus(eventHotKeyExistsErr)
                ? L("%@ is already used by another app. Pick another shortcut.", combo.displayString)
                : L("Couldn't register %@ (error %d).", combo.displayString, Int(status))
            NSLog("NurTo: global hotkey %@ registration failed (%d)", combo.displayString, status)
        }
    }
}

// MARK: - Finder selection

/// Reads the Finder selection with AppleScript (asks for Automation permission once).
enum FinderSelection {
    enum Result { case files([URL]), empty, finderNotRunning, notAuthorized, failed(String) }
    enum Permission { case allowed, notDetermined, denied, finderNotRunning, unknown }

    static let finderBundleID = "com.apple.finder"
    private static let queue = DispatchQueue(label: "app.nurto.mac.finder-selection")

    static var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleID
    }

    static let script = """
    tell application "Finder"
        set sel to selection as alias list
    end tell
    set out to ""
    repeat with a in sel
        set out to out & POSIX path of a & linefeed
    end repeat
    return out
    """

    /// Runs off the main thread (the first run blocks on the consent prompt); completes on main.
    static func fetch(completion: @escaping @MainActor (Result) -> Void) {
        queue.async {
            var errorInfo: NSDictionary?
            let output = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
            let result: Result
            if let errorInfo {
                let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "error \(code)"
                switch code {
                case -1743, -1744: result = .notAuthorized
                case -600: result = .finderNotRunning
                default: result = .failed(message)
                }
                NSLog("NurTo: Finder selection failed (%ld) %@", code, message)
            } else {
                let paths = (output?.stringValue ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
                result = urls.isEmpty ? .empty : .files(urls)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Checks Automation permission for Finder without prompting.
    static func permission(completion: @escaping @MainActor (Permission) -> Void) {
        queue.async {
            var addr = AEAddressDesc()
            let id = Array(finderBundleID.utf8)
            var status = OSStatus(id.withUnsafeBytes { AECreateDesc(typeApplicationBundleID, $0.baseAddress, $0.count, &addr) })
            if status == noErr {
                status = AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, false)
                AEDisposeDesc(&addr)
            }
            let p: Permission
            switch Int(status) {
            case Int(noErr): p = .allowed
            case -1744: p = .notDetermined     // errAEEventWouldRequireUserConsent
            case -1743: p = .denied            // errAEEventNotPermitted
            case -600: p = .finderNotRunning   // procNotFound
            default: p = .unknown
            }
            DispatchQueue.main.async { completion(p) }
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func presentPermissionHelp() {
        KQWindowing.activate()
        let alert = NSAlert()
        alert.messageText = L("NurTo can't read the Finder selection")
        alert.informativeText = L("To open the wheel for files selected in Finder, allow NurTo to control Finder in System Settings › Privacy & Security › Automation › NurTo › Finder.\n\nYou can still drag files and tap the trigger key, or use Finder's right-click › Quick Actions / Services.")
        alert.addButton(withTitle: L("Open Automation Settings"))
        alert.addButton(withTitle: L("Not Now"))
        if alert.runModal() == .alertFirstButtonReturn { openAutomationSettings() }
    }
}
