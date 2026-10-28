import AVFoundation
import AppKit
import SwiftUI

/// Interactive bleep editor (audio redaction) for audio and video files.
@MainActor
enum BleepEditor {
    /// Opens the editor window for `inputs`. Calls `completion` exactly once (nil = cancelled).
    static func present(inputs: [URL], completion: @escaping EditorCompletion) {
        guard let url = inputs.first else { completion(nil); return }
        let host = EditorWindowHost(title: L("Bleep – %@", url.lastPathComponent),
                                    minSize: NSSize(width: 720, height: 440), completion: completion)
        let controller = TimelineEditorController<BleepDocument>(url: url, host: host)
        host.show(BleepRootView(controller: controller, host: host).tint(KQTheme.accent))
        controller.load()
    }
}

// MARK: - Document

struct BleepRange: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    init(id: UUID = UUID(), start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
    var length: Double { end - start }
}

@MainActor
final class BleepDocument: TimelineEditorDocument {
    let session: TimelineSession
    var timeline: TimelineState { session.timeline }
    var playhead: TimelinePlayhead { session.playhead }
    var duration: Double { session.duration }

    @Published var ranges: [BleepRange] = [] { didSet { if ranges != oldValue { invalidatePreview() } } }
    @Published var selected: UUID?
    @Published var style: BleepStyle = .tone { didSet { if style != oldValue { invalidatePreview() } } }
    @Published var volume: Double = 0.5 { didSet { if volume != oldValue { invalidatePreview() } } }
    @Published var entire = false { didSet { if entire != oldValue { invalidatePreview() } } }
    @Published private(set) var renderingPreview = false
    @Published private(set) var previewError: String?

    /// Return / Enter save (set by `attach`).
    private var saveAction: (() -> Void)?

    /// Muted source player used for video frames (nil for audio or unplayable files).
    private(set) var videoPlayer: AVPlayer?
    private var videoClock: TimelineClock?
    /// Plays the rendered preview chunk.
    private var audioPlayer: AVPlayer?
    private var audioClock: TimelineClock?
    private var chunkStart = 0.0
    private var chunkEnd = 0.0
    private var renderToken = 0
    private var tempDir: URL?
    private var playableSink: Any?
    private var renderTask: Task<Void, Never>?

    static let previewLength = 30.0
    static let minLength = 0.05

    static func validate(_ session: TimelineSession) throws {
        guard session.info.hasAudio else {
            throw PetalwheelError(l: "“%@” has no audio track to bleep.", session.url.lastPathComponent)
        }
    }

    init(session: TimelineSession) {
        self.session = session
        playableSink = session.$playable.sink { [weak self] ok in
            guard ok == true else { return }
            MainActor.assumeIsolated { self?.makeVideoPlayer() }
        }
    }

    private func makeVideoPlayer() {
        guard videoPlayer == nil, session.hasVideo else { return }
        let p = AVPlayer(url: session.url)
        p.isMuted = true
        p.actionAtItemEnd = .pause
        videoPlayer = p
        videoClock = TimelineClock(player: p) { _ in }
        videoClock?.seek(playhead.time)
        objectWillChange.send()
    }

    func teardown() {
        stopPlayback()
        renderTask?.cancel()
        videoClock?.invalidate(); videoClock = nil
        videoPlayer?.replaceCurrentItem(with: nil); videoPlayer = nil
        audioClock?.invalidate(); audioClock = nil
        audioPlayer = nil
        playableSink = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        session.cancel()
    }

    func attach(to host: EditorWindowHost) {
        host.hasUnsavedChanges = { [weak self] in self?.hasUnsavedChanges ?? false }
        host.canSave = { [weak self] in self?.canSave ?? false }
        host.makeExport = { [weak self] in self?.makeExport() }
        host.playPause = { [weak self] in self?.togglePlay() }
        host.keyHandler = { [weak self] ev in self?.handleKey(ev) ?? false }
        saveAction = { [weak host] in host?.save() }
    }

    /// Any bleep added (or the whole track bleeped).
    var hasUnsavedChanges: Bool { entire || !ranges.isEmpty }

    // MARK: Ranges

    var totalBleeped: Double {
        entire ? duration : BleepExportPlan.normalize(ranges.map { .init(start: $0.start, end: $0.end) }, duration: duration)
            .reduce(0) { $0 + $1.end - $1.start }
    }

    func range(at t: Double) -> BleepRange? {
        ranges.last { t >= $0.start && t <= $0.end }
    }

    @discardableResult
    func addRange(start: Double, end: Double, select: Bool = true) -> UUID {
        let a = max(0, min(start, end)), b = min(duration, max(start, end))
        let r = BleepRange(start: a, end: max(b, min(duration, a + Self.minLength)))
        ranges.append(r)
        if select { selected = r.id }
        return r.id
    }

    func addAtPlayhead() {
        let t = playhead.time
        let start = min(t, max(0, duration - 0.5))
        addRange(start: start, end: start + 0.5)
    }

    func deleteSelected() {
        guard let id = selected else { NSSound.beep(); return }
        ranges.removeAll { $0.id == id }
        selected = nil
    }

    func update(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let i = ranges.firstIndex(where: { $0.id == id }) else { return }
        var r = ranges[i]
        if let start { r.start = min(max(0, start), r.end - Self.minLength) }
        if let end { r.end = max(min(duration, end), r.start + Self.minLength) }
        ranges[i] = r
    }

    func move(_ id: UUID, toStart s: Double) {
        guard let i = ranges.firstIndex(where: { $0.id == id }) else { return }
        let len = ranges[i].length
        let start = min(max(0, s), duration - len)
        ranges[i].start = start
        ranges[i].end = start + len
    }

    /// I: start of the selected range at the playhead (or a new 0.5 s range).
    func markIn() {
        let t = playhead.time
        if let id = selected, let r = ranges.first(where: { $0.id == id }), t < r.end - Self.minLength {
            update(id, start: t)
        } else {
            addRange(start: t, end: t + 0.5)
        }
    }

    /// O: end of the selected range at the playhead.
    func markOut() {
        let t = playhead.time
        if let id = selected, let r = ranges.first(where: { $0.id == id }), t > r.start + Self.minLength {
            update(id, end: t)
        } else {
            addRange(start: max(0, t - 0.5), end: t)
        }
    }

    // MARK: Playback (rendered preview with bleeps applied)

    func seek(_ t: Double) {
        let v = min(max(0, t), duration)
        if playhead.isPlaying { stopPlayback() }
        playhead.time = v
        timeline.reveal(v)
        videoClock?.seek(v)
    }

    func nudge(_ direction: Double, big: Bool) {
        seek(playhead.time + direction * (big ? 1 : session.nudgeStep))
    }

    func togglePlay() {
        if playhead.isPlaying || renderingPreview { stopPlayback(); return }
        if playhead.time >= duration - 0.05 { seek(0) }
        startPreview(at: playhead.time)
    }

    func makePlan() -> BleepExportPlan {
        BleepExportPlan(source: session.url, info: session.info,
                        ranges: ranges.map { .init(start: $0.start, end: $0.end) },
                        entire: entire, style: style, volume: volume)
    }

    private func startPreview(at start: Double) {
        let plan = makePlan()
        let length = min(Self.previewLength, duration - start)
        guard length > 0.05 else { return }
        renderToken += 1
        let token = renderToken
        renderingPreview = true
        previewError = nil
        let dir: URL
        do {
            if tempDir == nil { tempDir = try OutputNaming.tempDirectory() }
            dir = tempDir!
        } catch {
            renderingPreview = false
            previewError = error.localizedDescription
            return
        }
        let file = dir.appendingPathComponent("preview-\(token).wav")
        renderTask = Task { [weak self] in
            do {
                try await plan.renderPreview(from: start, length: length, to: file)
                guard let self, token == self.renderToken else { return }
                self.renderingPreview = false
                self.beginPlayback(file: file, start: start, length: length)
            } catch {
                guard let self, token == self.renderToken else { return }
                self.renderingPreview = false
                if !(error is CancellationError) { self.previewError = error.localizedDescription }
            }
        }
    }

    private func beginPlayback(file: URL, start: Double, length: Double) {
        audioClock?.invalidate()
        let p = AVPlayer(url: file)
        p.actionAtItemEnd = .pause
        audioPlayer = p
        chunkStart = start
        chunkEnd = start + length
        audioClock = TimelineClock(player: p) { [weak self] t in self?.tick(t) }
        videoClock?.seek(start)
        p.play()
        videoPlayer?.play()
        playhead.isPlaying = true
    }

    private func tick(_ t: Double) {
        guard playhead.isPlaying, t.isFinite else { return }
        let now = chunkStart + t
        if now >= chunkEnd - 0.03 || (audioPlayer?.rate ?? 0) == 0 && t > 0.1 {
            stopPlayback()
            playhead.time = min(chunkEnd, duration)
            return
        }
        playhead.time = now
        timeline.reveal(now)
    }

    func stopPlayback() {
        renderToken += 1
        renderTask?.cancel()
        renderingPreview = false
        audioPlayer?.pause()
        videoPlayer?.pause()
        audioClock?.invalidate()
        audioClock = nil
        audioPlayer = nil
        if playhead.isPlaying {
            playhead.isPlaying = false
            videoClock?.seek(playhead.time)
        }
    }

    /// Edits make the rendered chunk stale.
    private func invalidatePreview() {
        if playhead.isPlaying || renderingPreview { stopPlayback() }
    }

    // MARK: Keys

    /// Space, ⌘S and Esc are handled by the window host.
    func handleKey(_ ev: NSEvent) -> Bool {
        guard EditorKeys.isPlain(ev) else { return false }
        let shift = ev.modifierFlags.contains(.shift)
        switch ev.keyCode {
        case EditorKeys.returnKey, EditorKeys.enter: saveAction?(); return true
        case EditorKeys.left: nudge(-1, big: shift); return true
        case EditorKeys.right: nudge(1, big: shift); return true
        case EditorKeys.delete, EditorKeys.forwardDelete: deleteSelected(); return true
        case EditorKeys.home: seek(0); return true
        case EditorKeys.end: seek(duration); return true
        default: break
        }
        switch EditorKeys.letter(ev) {
        case "b": addAtPlayhead(); return true
        case "i": markIn(); return true
        case "o": markOut(); return true
        default: return false
        }
    }

    // MARK: Export

    var canSave: Bool { entire || !ranges.isEmpty }

    func makeExport() -> EditorExport? {
        guard canSave else { return nil }
        stopPlayback()
        let plan = makePlan()
        return { progress in try await plan.export(progress: progress) }
    }

    // MARK: Drag on the waveform

    enum DragMode { case none, create(anchor: Double, id: UUID?), move(id: UUID, grab: Double), resizeStart(UUID), resizeEnd(UUID) }
    var drag: DragMode = .none

    func dragChanged(start: CGPoint, location: CGPoint, width w: CGFloat) {
        let t0 = timeline.time(at: start.x, width: w)
        let t = timeline.time(at: location.x, width: w)
        if case .none = drag {
            let edge = timeline.seconds(forPixels: 6, width: w)
            if let r = ranges.last(where: { abs($0.start - t0) <= edge }) {
                drag = .resizeStart(r.id); selected = r.id
            } else if let r = ranges.last(where: { abs($0.end - t0) <= edge }) {
                drag = .resizeEnd(r.id); selected = r.id
            } else if let r = range(at: t0) {
                drag = .move(id: r.id, grab: t0 - r.start); selected = r.id
            } else {
                drag = .create(anchor: t0, id: nil)
            }
            if playhead.isPlaying || renderingPreview { stopPlayback() }
        }
        switch drag {
        case .none: break
        case .create(let anchor, let id):
            guard abs(location.x - start.x) >= 3 else { return }
            if let id, let i = ranges.firstIndex(where: { $0.id == id }) {
                let a = max(0, min(anchor, t))
                ranges[i] = BleepRange(id: id, start: a, end: min(duration, max(max(anchor, t), a + Self.minLength)))
            } else {
                let new = addRange(start: min(anchor, t), end: max(anchor, t))
                drag = .create(anchor: anchor, id: new)
            }
        case .move(let id, let grab):
            move(id, toStart: t - grab)
        case .resizeStart(let id):
            update(id, start: t)
        case .resizeEnd(let id):
            update(id, end: t)
        }
    }

    func dragEnded(start: CGPoint, location: CGPoint, width w: CGFloat) {
        defer { drag = .none }
        guard abs(location.x - start.x) < 3 else { return }
        // A click: select the range under the pointer, or move the playhead.
        let t = timeline.time(at: location.x, width: w)
        if let r = range(at: t) {
            selected = r.id
        } else {
            selected = nil
            seek(t)
        }
    }
}
