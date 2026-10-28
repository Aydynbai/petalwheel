import AVFoundation
import AVKit
import AppKit
import SwiftUI

// Core timeline infrastructure shared by the Trim and Bleep editors: visible-range state, playhead,
// scroll / pinch routing and small AppKit bridges. The window itself is an `EditorWindowHost`.

// MARK: - Visible range

@MainActor
final class TimelineState: ObservableObject {
    let duration: Double
    /// 1 = whole file visible.
    @Published var zoom: Double = 1
    /// Left edge of the visible window, seconds.
    @Published var viewStart: Double = 0
    /// Frame of the track area in window content coordinates (top-left origin), for scroll/pinch routing.
    var trackFrame: CGRect = .zero

    init(duration: Double) { self.duration = max(duration, 0.01) }

    var maxZoom: Double { max(1, min(1000, duration / 0.4)) }
    var visibleDuration: Double { duration / zoom }
    var viewEnd: Double { viewStart + visibleDuration }

    func x(for t: Double, width: CGFloat) -> CGFloat {
        CGFloat((t - viewStart) / visibleDuration) * width
    }

    func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return viewStart }
        return min(max(viewStart + Double(x / width) * visibleDuration, 0), duration)
    }

    func seconds(forPixels px: CGFloat, width: CGFloat) -> Double {
        width > 0 ? Double(px / width) * visibleDuration : 0
    }

    /// Changes zoom keeping `anchor` (seconds) at the same screen position.
    func setZoom(_ z: Double, anchor: Double? = nil) {
        let newZoom = min(max(z, 1), maxZoom)
        let a = anchor ?? (viewStart + visibleDuration / 2)
        let frac = visibleDuration > 0 ? (a - viewStart) / visibleDuration : 0.5
        zoom = newZoom
        setViewStart(a - frac * visibleDuration)
    }

    func setViewStart(_ s: Double) {
        viewStart = min(max(s, 0), max(0, duration - visibleDuration))
    }

    func pan(by seconds: Double) { setViewStart(viewStart + seconds) }

    /// Pages the view so `t` is visible (used while playing and when nudging).
    func reveal(_ t: Double) {
        guard zoom > 1.0001 else { return }
        if t < viewStart || t > viewEnd {
            setViewStart(t - visibleDuration * 0.1)
        }
    }

    /// Log-scale binding for the zoom slider.
    var zoomSlider: Binding<Double> {
        Binding(get: { log(self.zoom) }, set: { self.setZoom(exp($0)) })
    }
}

@MainActor
final class TimelinePlayhead: ObservableObject {
    @Published var time: Double = 0
    @Published var isPlaying = false
}

// MARK: - Scroll / pinch routing

/// Turns scroll and pinch gestures over `timeline.trackFrame` into zoom / pan of the timeline.
@MainActor
final class TimelineGestureRouter {
    private weak var window: NSWindow?
    private var monitor: Any?
    weak var timeline: TimelineState?

    init(window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] ev in
            (self?.handle(ev) ?? false) ? nil : ev
        }
    }

    func invalidate() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ ev: NSEvent) -> Bool {
        guard let window, ev.window === window, let tl = timeline, let content = window.contentView else { return false }
        var p = content.convert(ev.locationInWindow, from: nil)
        if !content.isFlipped { p.y = content.bounds.height - p.y }
        let frame = tl.trackFrame
        guard frame.width > 0, frame.contains(p) else { return false }
        let anchor = tl.time(at: p.x - frame.minX, width: frame.width)
        if ev.type == .magnify {
            tl.setZoom(tl.zoom * (1 + ev.magnification), anchor: anchor)
            return true
        }
        // ⌘ / ⌥ + scroll zooms; plain scroll pans (horizontal or vertical wheel).
        let dx = ev.scrollingDeltaX, dy = ev.scrollingDeltaY
        if ev.modifierFlags.contains(.command) || ev.modifierFlags.contains(.option) {
            let factor = pow(1.01, Double(ev.hasPreciseScrollingDeltas ? dy : dy * 8))
            tl.setZoom(tl.zoom * factor, anchor: anchor)
        } else {
            let delta = abs(dx) > abs(dy) ? dx : dy
            let px = ev.hasPreciseScrollingDeltas ? delta : delta * 12
            tl.pan(by: -tl.seconds(forPixels: px, width: frame.width))
        }
        return true
    }
}

// MARK: - Track frame reporting

private struct TrackFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

extension View {
    /// Reports this view's frame (global = window content coordinates) as the timeline's scroll/pinch area.
    func timelineTrackArea(_ state: TimelineState) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: TrackFrameKey.self, value: g.frame(in: .global)) })
            .onPreferenceChange(TrackFrameKey.self) { f in
                MainActor.assumeIsolated { state.trackFrame = f }
            }
    }
}

// MARK: - AppKit bridges

/// AVPlayerView without controls (the editor has its own transport).
struct TimelinePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// Time entry field: accepts 1:23.45, commits on Return / focus loss, shows the model value otherwise.
struct TimelineTimeField: NSViewRepresentable {
    var value: Double
    var onCommit: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: TimelineClockText.format(value))
        f.delegate = context.coordinator
        f.alignment = .right
        f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        f.bezelStyle = .roundedBezel
        f.controlSize = .regular
        f.target = context.coordinator
        f.action = #selector(Coordinator.commit(_:))
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil {
            let s = TimelineClockText.format(value)
            if f.stringValue != s { f.stringValue = s }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimelineTimeField
        init(_ p: TimelineTimeField) { parent = p }

        @objc func commit(_ sender: NSTextField) {
            apply(sender)
            sender.window?.makeFirstResponder(nil)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let f = obj.object as? NSTextField { apply(f) }
        }

        private func apply(_ f: NSTextField) {
            if let v = TimelineClockText.parse(f.stringValue) { parent.onCommit(v) }
            f.stringValue = TimelineClockText.format(parent.value)
        }
    }
}

// MARK: - Playback clock

/// Periodic time observer around an AVPlayer.
@MainActor
final class TimelineClock {
    let player: AVPlayer
    private var token: Any?

    init(player: AVPlayer, onTime: @escaping @MainActor (Double) -> Void) {
        self.player = player
        token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
            MainActor.assumeIsolated { onTime(t.seconds) }
        }
    }

    func invalidate() {
        if let token { player.removeTimeObserver(token) }
        token = nil
        player.pause()
    }

    func seek(_ t: Double, exact: Bool = true) {
        let time = CMTime(seconds: max(0, t), preferredTimescale: 600)
        if exact {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: time)
        }
    }
}

// MARK: - Editor controller

/// A Trim / Bleep document: the edit state for one opened media file.
@MainActor
protocol TimelineEditorDocument: ObservableObject {
    init(session: TimelineSession)
    var session: TimelineSession { get }
    /// Throws when this editor can't work on the file (e.g. Bleep without audio).
    static func validate(_ session: TimelineSession) throws
    /// Wires save / unsaved-changes / undo / playback / shortcuts into the window host.
    func attach(to host: EditorWindowHost)
    func teardown()
}

/// Opens the media file in the background, then hands it to a document of type `Doc`.
@MainActor
final class TimelineEditorController<Doc: TimelineEditorDocument>: ObservableObject {
    let url: URL
    private(set) weak var host: EditorWindowHost?
    @Published private(set) var doc: Doc?
    @Published private(set) var error: String?
    private var loadTask: Task<Void, Never>?
    private let gestures: TimelineGestureRouter

    init(url: URL, host: EditorWindowHost) {
        self.url = url
        self.host = host
        gestures = TimelineGestureRouter(window: host.window)
        host.teardown = { [weak self] in
            guard let self else { return }
            self.loadTask?.cancel()
            self.doc?.teardown()
            self.gestures.invalidate()
        }
        host.owner = self
    }

    func load() {
        loadTask = Task { [weak self] in
            guard let url = self?.url else { return }
            do {
                let session = try await TimelineSession.open(url)
                do { try Doc.validate(session) } catch { session.cancel(); throw error }
                guard let self, let host = self.host, !host.isFinished, !Task.isCancelled else { session.cancel(); return }
                let doc = Doc(session: session)
                self.doc = doc
                self.gestures.timeline = session.timeline
                doc.attach(to: host)
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    func cancel() { host?.requestCancel() }
}
