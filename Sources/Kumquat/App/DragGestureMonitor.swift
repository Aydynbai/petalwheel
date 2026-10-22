import AppKit
import os

/// `log stream --predicate 'subsystem == "studio.kipper.Kumquat"' --level debug` shows gesture decisions.
let gestureLog = Logger(subsystem: "studio.kipper.Kumquat", category: "gesture")

/// Detects "files are being dragged + a modifier key was tapped" without Accessibility permission,
/// by polling the global mouse/modifier state and the system drag pasteboard.
@MainActor
final class DragGestureMonitor {
    /// mode, cursor location (screen coordinates), dragged file URLs
    var onTrigger: ((FanMode, NSPoint, [URL]) -> Void)?
    /// The mouse button was released after a file drag.
    var onDragEnded: (() -> Void)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private let idleInterval: TimeInterval = 0.12
    private let activeInterval: TimeInterval = 1.0 / 60
    private var isPollingActively = false

    private var wasMouseDown = false
    private var changeCountAtMouseDown = 0
    private var isDraggingFiles = false
    private var draggedURLs: [URL] = []

    // Modifier tap tracking
    private var previousModifiers: NSEvent.ModifierFlags = []
    private var pressStarted: TimeInterval = 0
    private var pressedUnion: NSEvent.ModifierFlags = []
    private let tapGraceInterval: TimeInterval = 0.6
    private let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    func start() {
        schedule(interval: idleInterval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        isPollingActively = interval == activeInterval
    }

    private func tick() {
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0

        if mouseDown && !wasMouseDown {
            changeCountAtMouseDown = dragPasteboard.changeCount
            isDraggingFiles = false
            draggedURLs = []
            if !isPollingActively { schedule(interval: activeInterval) }
        }

        if mouseDown && !isDraggingFiles && dragPasteboard.changeCount != changeCountAtMouseDown {
            let urls = readFileURLs()
            if !urls.isEmpty {
                isDraggingFiles = true
                draggedURLs = urls
                gestureLog.debug("file drag started: \(urls.count) item(s)")
                previousModifiers = NSEvent.modifierFlags.intersection(relevantFlags)
                pressedUnion = []
            } else {
                // Not a file drag; ignore until next mouse down.
                changeCountAtMouseDown = dragPasteboard.changeCount
            }
        }

        if isDraggingFiles && mouseDown {
            trackModifierTap()
        }

        if !mouseDown && wasMouseDown {
            if isDraggingFiles {
                gestureLog.debug("file drag ended")
                onDragEnded?()
            }
            isDraggingFiles = false
            draggedURLs = []
            if isPollingActively { schedule(interval: idleInterval) }
        }
        wasMouseDown = mouseDown
    }

    private func trackModifierTap() {
        let now = ProcessInfo.processInfo.systemUptime
        let mods = NSEvent.modifierFlags.intersection(relevantFlags)
        defer { previousModifiers = mods }
        guard mods != previousModifiers else { return }

        if previousModifiers.isEmpty && !mods.isEmpty {
            pressStarted = now
            pressedUnion = mods
        } else if !mods.isEmpty {
            pressedUnion.formUnion(mods)
        } else if !previousModifiers.isEmpty && mods.isEmpty {
            // Released: a tap if it was short and exactly one modifier key was involved.
            defer { pressedUnion = [] }
            let held = now - pressStarted
            guard held <= tapGraceInterval else {
                gestureLog.debug("modifier ignored: held \(held, format: .fixed(precision: 2))s > \(self.tapGraceInterval)s")
                return
            }
            guard let key = ModifierKey.allCases.first(where: { pressedUnion == $0.flag }),
                  let mode = AppSettings.shared.mode(for: key) else {
                gestureLog.debug("modifier ignored: combination \(self.pressedUnion.rawValue) is not the wheel key")
                return
            }
            gestureLog.debug("wheel triggered by \(key.rawValue) tap (\(held, format: .fixed(precision: 2))s)")
            // Re-read in case more files were added to the drag.
            let urls = readFileURLs()
            onTrigger?(mode, NSEvent.mouseLocation, urls.isEmpty ? draggedURLs : urls)
        }
    }

    private func readFileURLs() -> [URL] {
        let objects = dragPasteboard.readObjects(forClasses: [NSURL.self],
                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return objects ?? []
    }
}
