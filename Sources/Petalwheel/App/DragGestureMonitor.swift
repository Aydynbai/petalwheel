import AppKit
import os

let gestureLog = Logger(subsystem: "app.nurto.mac", category: "gesture")

/// A hold is deliberate: no open before 1.3 s, one request per hold, release closes.
struct WheelHoldGate {
    enum Event: Equatable { case none, open, close }
    static let delay: TimeInterval = 1.3
    private var began: TimeInterval?
    private(set) var requested = false
    private(set) var session = UUID()

    mutating func update(down: Bool, now: TimeInterval) -> Event {
        if !down {
            let wasRequested = requested
            began = nil; requested = false
            return wasRequested ? .close : .none
        }
        if began == nil { began = now; session = UUID() }
        if !requested, now - (began ?? now) >= Self.delay {
            requested = true
            return .open
        }
        return .none
    }
}

/// Polls modifier state without a keyboard listener. Supports a file drag or Finder selection.
@MainActor
final class DragGestureMonitor {
    var onTrigger: ((FanMode, NSPoint, [URL]) -> Void)?
    var onDragEnded: (() -> Void)?
    var onModifierReleased: (() -> Void)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var active = false
    private var wasMouseDown = false
    private var isDraggingFiles = false
    private var lastIdleCount = 0
    private var downCount = 0
    private var heldURLs: [URL] = []
    private var gate = WheelHoldGate()

    func start() {
        lastIdleCount = dragPasteboard.changeCount
        schedule(active: false)
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func schedule(active: Bool) {
        timer?.invalidate(); self.active = active
        let t = Timer(timeInterval: active ? 1.0 / 60 : 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func tick() {
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        let key = AppSettings.shared.triggerKey
        let mods = NSEvent.modifierFlags.intersection([.control, .shift, .command, .option])
        let keyDown = gate.requested ? mods.contains(key.flag) : mods == key.flag

        if mouseDown && !wasMouseDown {
            downCount = lastIdleCount; isDraggingFiles = false
        }
        if mouseDown && !isDraggingFiles && dragPasteboard.changeCount != downCount {
            let urls = readFileURLs()
            if !urls.isEmpty { isDraggingFiles = true; heldURLs = urls }
            else { downCount = dragPasteboard.changeCount }
        }
        if isDraggingFiles && mouseDown {
            let current = readFileURLs()
            if !current.isEmpty { heldURLs = current }
        }

        switch gate.update(down: keyDown, now: ProcessInfo.processInfo.systemUptime) {
        case .open:
            let session = gate.session
            if !heldURLs.isEmpty {
                onTrigger?(.categories, NSEvent.mouseLocation, heldURLs)
            } else if FinderSelection.finderIsFrontmost {
                FinderSelection.fetch { [weak self] result in
                    guard let self, self.gate.requested, self.gate.session == session,
                          NSEvent.modifierFlags.contains(key.flag) else { return }
                    if case .files(let urls) = result, !urls.isEmpty {
                        self.onTrigger?(.categories, NSEvent.mouseLocation, urls)
                    } else if case .notAuthorized = result {
                        IntegrationsToast.show("Allow Finder access in Settings", symbol: "lock")
                    }
                }
            }
        case .close:
            onModifierReleased?(); heldURLs = []
        case .none: break
        }

        if !mouseDown && wasMouseDown {
            onDragEnded?(); isDraggingFiles = false
        }
        if !mouseDown {
            lastIdleCount = dragPasteboard.changeCount
            if !keyDown { heldURLs = [] }
        }
        wasMouseDown = mouseDown
        if active != (mouseDown || keyDown) { schedule(active: mouseDown || keyDown) }
    }

    private func readFileURLs() -> [URL] {
        dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
