import AppKit
import SwiftUI

// Shared window infrastructure for every interactive editor: one window class that routes keyboard
// shortcuts itself (the app has no main menu), one host that owns the window, calls the completion
// exactly once and asks before throwing away unsaved changes, and the common footer.

// MARK: - Keys

enum EditorKeys {
    static let escape: UInt16 = 53, space: UInt16 = 49, returnKey: UInt16 = 36, enter: UInt16 = 76
    static let delete: UInt16 = 51, forwardDelete: UInt16 = 117
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let home: UInt16 = 115, end: UInt16 = 119

    /// Command / shift / option / control only.
    static func modifiers(_ ev: NSEvent) -> NSEvent.ModifierFlags {
        ev.modifierFlags.intersection([.command, .shift, .option, .control])
    }

    /// No command / control / option (shift allowed).
    static func isPlain(_ ev: NSEvent) -> Bool {
        ev.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    /// Letter typed (lowercased), ignoring modifiers.
    static func letter(_ ev: NSEvent) -> String {
        (ev.charactersIgnoringModifiers ?? "").lowercased()
    }
}

// MARK: - Window

/// Editor window: every key event goes through its host before the responder chain.
final class EditorWindow: NSWindow {
    weak var host: EditorWindowHost?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if host?.route(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp, host?.route(event) == true { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { host?.requestCancel() }
}

// MARK: - Host

/// Owns an editor window. Calls the completion exactly once (Save → export, anything else → nil),
/// handles ⌘S / ⌘W / Esc / ⌘Z / ⇧⌘Z / Space, and shows a "Discard your changes?" sheet before
/// closing an edited document.
@MainActor
final class EditorWindowHost: NSObject, NSWindowDelegate, ObservableObject {
    private static var live: [ObjectIdentifier: EditorWindowHost] = [:]

    let window: EditorWindow
    private var completion: EditorCompletion?

    /// True while Save is building its export (the Save button is disabled).
    @Published private(set) var isSaving = false

    /// Whether closing now would lose edits.
    var hasUnsavedChanges: () -> Bool = { false }
    /// Whether Save would produce anything.
    var canSave: () -> Bool = { true }
    /// Builds the export on Save. Returning nil keeps the window open.
    var makeExport: (() -> EditorExport?)?
    /// Called right before Save builds its export (e.g. to commit inline text editing).
    var willSave: (() -> Void)?
    var undo: (() -> Void)?
    var redo: (() -> Void)?
    /// Media editors: Space toggles playback.
    var playPause: (() -> Void)?
    /// Called on Esc before the cancel guard; return true to consume it (e.g. to close an inner preview).
    var escapeHandler: (() -> Bool)?
    /// Editor-specific shortcuts (key down). Return true when handled. Not called while a text view has focus.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Editor-specific key-up handling (hold-to-compare and the like).
    var keyUpHandler: ((NSEvent) -> Bool)?
    /// Called once when the window goes away (stop playback, cancel tasks…).
    var teardown: (() -> Void)?
    /// Editor object kept alive while the window is open.
    var owner: AnyObject?

    /// The open "Discard your changes?" sheet, if any (exposed for tests).
    private(set) var discardAlert: NSAlert?
    var isFinished: Bool { completion == nil }

    init(title: String, minSize: NSSize, completion: @escaping EditorCompletion) {
        self.completion = completion
        window = EditorWindow(contentRect: NSRect(origin: .zero, size: minSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.host = self
    }

    /// ~85 % of the visible area of the screen under the mouse, never below the minimum size.
    static func defaultFrame(minSize: NSSize) -> NSRect {
        let vf = KQWindowing.mouseScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(vf.width, max(minSize.width, (vf.width * 0.85).rounded()))
        let h = min(vf.height, max(minSize.height, (vf.height * 0.85).rounded()))
        return NSRect(x: (vf.midX - w / 2).rounded(), y: (vf.midY - h / 2).rounded(), width: w, height: h)
    }

    func show<V: View>(_ content: V) {
        let hosting = NSHostingView(rootView: content)
        // The window size is ours; SwiftUI only contributes its minimum size.
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.setFrame(Self.defaultFrame(minSize: window.contentMinSize), display: false)
        Self.live[ObjectIdentifier(self)] = self
        KQWindowing.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Save / cancel

    func save() {
        // The discard sheet's own Save button calls this while the sheet is still winding down.
        guard completion != nil, !isSaving, discardAlert == nil else { return }
        guard canSave() else { NSSound.beep(); return }
        // Commit a time / text field that is still being edited.
        if let text = window.firstResponder as? NSTextView, text.isFieldEditor { window.makeFirstResponder(nil) }
        willSave?()
        isSaving = true
        guard let export = makeExport?() else {
            isSaving = false
            NSSound.beep()
            return
        }
        finish(export)
    }

    /// Esc, ⌘W, Cancel: closes right away, or asks first when there are unsaved changes.
    func requestCancel() {
        guard completion != nil, window.attachedSheet == nil else { return }
        if hasUnsavedChanges() { confirmDiscard() } else { finish(nil) }
    }

    /// Ends the session: the first call wins, later calls do nothing.
    func finish(_ export: EditorExport?) {
        guard let c = completion else { return }
        completion = nil
        cleanUp()
        if window.isVisible { window.close() }
        c(export)
    }

    private func confirmDiscard() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Discard your changes?")
        alert.informativeText = L("Your edits will be lost if you close the editor without saving.")
        alert.addButton(withTitle: L("Keep Editing"))
        let discard = alert.addButton(withTitle: L("Discard"))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = [.command]
        if canSave() { alert.addButton(withTitle: L("Save")) }
        discardAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.discardAlert = nil
                switch response {
                case .alertSecondButtonReturn: self.finish(nil)
                case .alertThirdButtonReturn: self.save()
                default: break
                }
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard completion != nil, hasUnsavedChanges() else { return true }
        if window.attachedSheet == nil { confirmDiscard() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func cleanUp() {
        if let alert = discardAlert, let sheet = window.attachedSheet, sheet === alert.window {
            window.endSheet(sheet, returnCode: .cancel)
        }
        discardAlert = nil
        teardown?()
        teardown = nil
        keyHandler = nil
        keyUpHandler = nil
        escapeHandler = nil
        makeExport = nil
        willSave = nil
        undo = nil
        redo = nil
        playPause = nil
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        let id = ObjectIdentifier(self)
        // Keep the host (and the editor it owns) alive until the close animation has finished.
        DispatchQueue.main.async {
            Self.live[id]?.owner = nil
            Self.live[id] = nil
        }
    }

    // MARK: Key routing

    /// Returns true when the event was handled.
    func route(_ event: NSEvent) -> Bool {
        guard completion != nil, window.attachedSheet == nil else { return false }
        if event.type == .keyUp {
            guard !(window.firstResponder is NSTextView) else { return false }
            return keyUpHandler?(event) ?? false
        }
        guard event.type == .keyDown else { return false }
        let mods = EditorKeys.modifiers(event)
        let key = EditorKeys.letter(event)

        if let text = window.firstResponder as? NSTextView {
            // A text field / inline text box is being edited: give it the standard editing shortcuts.
            if mods.contains(.command) {
                switch key {
                case "z":
                    if mods.contains(.shift) { text.undoManager?.redo() } else { text.undoManager?.undo() }
                    return true
                case "x": text.cut(nil); return true
                case "c": text.copy(nil); return true
                case "v": text.pasteAsPlainText(nil); return true
                case "a": text.selectAll(nil); return true
                case "s": save(); return true
                case "w": requestCancel(); return true
                default: return false
                }
            }
            // Esc leaves a field; inline text boxes handle Esc themselves.
            if event.keyCode == EditorKeys.escape, text.isFieldEditor {
                window.makeFirstResponder(nil)
                return true
            }
            return false
        }

        if mods == [.command] || mods == [.command, .shift] {
            switch key {
            case "s" where mods == [.command]: save(); return true
            case "w" where mods == [.command]: requestCancel(); return true
            case "z":
                let action = mods.contains(.shift) ? redo : undo
                if let action { action(); return true }
            default: break
            }
        }
        if event.keyCode == EditorKeys.escape, !mods.contains(.command) {
            if escapeHandler?() == true { return true }
            requestCancel()
            return true
        }
        if event.keyCode == EditorKeys.space, mods.isEmpty, let playPause {
            playPause()
            return true
        }
        return keyHandler?(event) ?? false
    }
}

// MARK: - Footer

/// File name plus one line of detail, shown at the left of every editor footer.
struct EditorFileInfo: View {
    let name: String
    var detail: Text? = nil
    var highlightDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                detail
                    .font(.system(size: 11))
                    .foregroundStyle(highlightDetail ? KQTheme.accentText : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .layoutPriority(-1)
    }
}

/// Common footer: file info on the left, optional accessories, then Cancel and Save on the right.
struct EditorFooter<Leading: View, Accessory: View>: View {
    @ObservedObject var host: EditorWindowHost
    var saveTitle: String = "Save"
    var saveHelp: String = "Save (⌘S)"
    var canSave = true
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        let enabled = canSave && !host.isSaving
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 12)
            accessory()
            Button("Cancel") { host.requestCancel() }
                .buttonStyle(KQSecondaryButtonStyle())
            Button(action: { host.save() }) { Text(L(saveTitle)) }
                .buttonStyle(KQProminentButtonStyle())
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
                .help(L(saveHelp))
        }
        .padding(.horizontal, KQTheme.padding)
        .padding(.vertical, 10)
    }
}

extension EditorFooter where Accessory == EmptyView {
    init(host: EditorWindowHost, saveTitle: String = "Save", saveHelp: String = "Save (⌘S)",
         canSave: Bool = true, @ViewBuilder leading: @escaping () -> Leading) {
        self.init(host: host, saveTitle: saveTitle, saveHelp: saveHelp, canSave: canSave, leading: leading, accessory: { EmptyView() })
    }
}
