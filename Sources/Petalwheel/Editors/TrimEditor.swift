import AVFoundation
import AppKit
import SwiftUI

/// Interactive trim editor for audio and video: in/out handles, split into clips, delete clips,
/// join or export separately, automatic silent-end trimming.
@MainActor
enum TrimEditor {
    /// Opens the editor window for `inputs`. Calls `completion` exactly once (nil = cancelled).
    static func present(inputs: [URL], completion: @escaping EditorCompletion) {
        guard let url = inputs.first else { completion(nil); return }
        let host = EditorWindowHost(title: L("Trim – %@", url.lastPathComponent),
                                    minSize: NSSize(width: 720, height: 460), completion: completion)
        let controller = TimelineEditorController<TrimDocument>(url: url, host: host)
        host.show(TrimRootView(controller: controller, host: host).tint(KQTheme.accent))
        controller.load()
    }
}

// MARK: - Document

struct TrimClip: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    init(id: UUID = UUID(), start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
}

@MainActor
final class TrimDocument: TimelineEditorDocument {
    let session: TimelineSession
    var timeline: TimelineState { session.timeline }
    var playhead: TimelinePlayhead { session.playhead }
    var duration: Double { session.duration }

    @Published var inPoint: Double = 0
    @Published var outPoint: Double
    /// The source cut at split points; removed clips leave gaps.
    @Published private(set) var clips: [TrimClip]
    @Published var selectedClip: UUID?
    @Published var separate = false
    @Published var autoSilence = false {
        didSet {
            guard autoSilence != oldValue else { return }
            if !suppressUndo {
                var before = snapshot
                before.autoSilence = oldValue
                recordUndo(before: before)
            }
            applySilence()
        }
    }
    @Published var silenceDB: Double = -45 { didSet { if autoSilence { applySilence() } } }
    @Published private(set) var playingSelection = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Return / Enter save (set by `attach`).
    private var saveAction: (() -> Void)?

    private(set) var player: AVPlayer?
    private var clock: TimelineClock?
    private var endObserver: NSObjectProtocol?
    private var playableSink: Any?
    private var skipTarget: Double?

    /// Snapshot-based undo of the cut (in/out, clips, automatic silence trimming).
    struct Snapshot: Equatable {
        var inPoint: Double
        var outPoint: Double
        var clips: [TrimClip]
        var autoSilence: Bool
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var coalesceKey: String?
    private var coalesceTime: CFTimeInterval = 0
    private var suppressUndo = false

    static func validate(_ session: TimelineSession) throws {}

    init(session: TimelineSession) {
        self.session = session
        outPoint = session.duration
        clips = [TrimClip(start: 0, end: session.duration)]
        playableSink = session.$playable.sink { [weak self] ok in
            guard ok == true else { return }
            MainActor.assumeIsolated { self?.makePlayer() }
        }
    }

    var isAudioOnly: Bool { !session.hasVideo }

    func attach(to host: EditorWindowHost) {
        host.hasUnsavedChanges = { [weak self] in self?.hasUnsavedChanges ?? false }
        host.canSave = { [weak self] in self?.canSave ?? false }
        host.makeExport = { [weak self] in self?.makeExport() }
        host.undo = { [weak self] in self?.undo() }
        host.redo = { [weak self] in self?.redo() }
        host.playPause = { [weak self] in self?.togglePlay() }
        host.keyHandler = { [weak self] ev in self?.handleKey(ev) ?? false }
        saveAction = { [weak host] in host?.save() }
    }

    private func makePlayer() {
        guard player == nil else { return }
        let p = AVPlayer(url: session.url)
        p.actionAtItemEnd = .pause
        player = p
        clock = TimelineClock(player: p) { [weak self] t in self?.tick(t) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: p.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPlayback() }
        }
        clock?.seek(playhead.time)
        objectWillChange.send()
    }

    func teardown() {
        clock?.invalidate()
        clock = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playableSink = nil
        session.cancel()
    }

    // MARK: Segments

    /// Kept clips clipped to [in, out].
    var segments: [TrimExportPlan.Segment] {
        clips.compactMap { c in
            let a = max(c.start, inPoint), b = min(c.end, outPoint)
            return b - a > 0.02 ? TrimExportPlan.Segment(start: a, end: b) : nil
        }
    }

    var resultDuration: Double { segments.reduce(0) { $0 + $1.length } }

    func clip(at t: Double) -> TrimClip? { clips.first { t >= $0.start && t < $0.end } }

    // MARK: Editing

    func setIn(_ t: Double, manual: Bool = true) {
        let v = min(max(0, t), outPoint - 0.05)
        if manual {
            guard v != inPoint || autoSilence else { return }
            recordUndo(coalesce: "in")
            autoSilenceOffSilently()
        }
        inPoint = v
    }

    func setOut(_ t: Double, manual: Bool = true) {
        let v = max(min(duration, t), inPoint + 0.05)
        if manual {
            guard v != outPoint || autoSilence else { return }
            recordUndo(coalesce: "out")
            autoSilenceOffSilently()
        }
        outPoint = v
    }

    private func autoSilenceOffSilently() {
        guard autoSilence else { return }
        withoutUndo { autoSilence = false }
    }

    /// In/out points or clips differ from the whole file.
    var hasUnsavedChanges: Bool {
        inPoint > 0.0005 || outPoint < duration - 0.0005
            || clips.count != 1 || clips.first.map { $0.start > 0.0005 || $0.end < duration - 0.0005 } == true
    }

    /// Splits the clip under the playhead.
    func split() {
        let t = playhead.time
        guard let i = clips.firstIndex(where: { t > $0.start + 0.02 && t < $0.end - 0.02 }) else { NSSound.beep(); return }
        recordUndo()
        let c = clips[i]
        clips.replaceSubrange(i...i, with: [TrimClip(id: c.id, start: c.start, end: t), TrimClip(start: t, end: c.end)])
        selectedClip = clips[i + 1].id
    }

    func deleteSelected() {
        guard let id = selectedClip, let i = clips.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        recordUndo()
        clips.remove(at: i)
        selectedClip = nil
    }

    /// Programmatic split points (harness / tests).
    func split(at times: [Double]) {
        recordUndo()
        for t in times.sorted() {
            if let i = clips.firstIndex(where: { t > $0.start + 0.02 && t < $0.end - 0.02 }) {
                let c = clips[i]
                clips.replaceSubrange(i...i, with: [TrimClip(id: c.id, start: c.start, end: t), TrimClip(start: t, end: c.end)])
            }
        }
    }

    func applySilence() {
        guard autoSilence, !suppressUndo else { return }
        guard let peaks = session.peaks else {
            session.whenPeaksLoaded { [weak self] _ in self?.applySilence() }
            return
        }
        guard let r = peaks.audibleRange(thresholdDB: silenceDB) else { return }
        setIn(max(0, r.start - 0.05), manual: false)
        setOut(min(duration, r.end + 0.1), manual: false)
    }

    // MARK: Undo

    var snapshot: Snapshot { Snapshot(inPoint: inPoint, outPoint: outPoint, clips: clips, autoSilence: autoSilence) }

    /// Records the state before a change. Repeated changes with the same key within a second
    /// (dragging a handle) form one step.
    private func recordUndo(coalesce key: String? = nil, before: Snapshot? = nil) {
        guard !suppressUndo else { return }
        let now = CACurrentMediaTime()
        if let key, key == coalesceKey, now - coalesceTime < 1 {
            coalesceTime = now
            return
        }
        coalesceKey = key
        coalesceTime = now
        undoStack.append(before ?? snapshot)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoFlags()
    }

    private func withoutUndo(_ body: () -> Void) {
        let was = suppressUndo
        suppressUndo = true
        body()
        suppressUndo = was
    }

    func undo() {
        guard let prev = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(snapshot)
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(snapshot)
        restore(next)
    }

    private func restore(_ s: Snapshot) {
        withoutUndo {
            autoSilence = s.autoSilence
            inPoint = s.inPoint
            outPoint = s.outPoint
            clips = s.clips
        }
        if let id = selectedClip, !clips.contains(where: { $0.id == id }) { selectedClip = nil }
        coalesceKey = nil
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Playback

    func seek(_ t: Double) {
        let v = min(max(0, t), duration)
        playhead.time = v
        timeline.reveal(v)
        clock?.seek(v)
    }

    func nudge(_ direction: Double, big: Bool) {
        seek(playhead.time + direction * (big ? 1 : session.nudgeStep))
    }

    func togglePlay() {
        if playhead.isPlaying { stopPlayback(); return }
        guard let player else { NSSound.beep(); return }
        playingSelection = false
        if playhead.time >= duration - 0.02 { seek(0) }
        player.play()
        playhead.isPlaying = true
    }

    /// Plays the edited result: from the in point (or the playhead if inside), skipping removed clips.
    func playSelection() {
        if playhead.isPlaying { stopPlayback() }
        guard let player, let first = segments.first else { NSSound.beep(); return }
        let t = playhead.time
        let inside = segments.contains { t >= $0.start && t < $0.end - 0.05 }
        seek(inside ? t : first.start)
        playingSelection = true
        player.play()
        playhead.isPlaying = true
    }

    func stopPlayback() {
        skipTarget = nil
        player?.pause()
        playhead.isPlaying = false
        playingSelection = false
    }

    private func tick(_ t: Double) {
        guard playhead.isPlaying, t.isFinite else { return }
        if let target = skipTarget {
            // Ignore stale times reported while the jump over a removed clip is in flight.
            guard t >= target - 0.05 else { return }
            skipTarget = nil
        }
        if playingSelection {
            let segs = segments
            if segs.contains(where: { t >= $0.start - 0.02 && t < $0.end }) {
                // inside a kept clip
            } else if let next = segs.first(where: { $0.start > t }) {
                skipTarget = next.start
                clock?.seek(next.start)
                playhead.time = next.start
                return
            } else {
                stopPlayback()
                seek(segs.last?.end ?? t)
                return
            }
        }
        playhead.time = t
        timeline.reveal(t)
    }

    // MARK: Keys

    /// Space, ⌘S, Esc and ⌘Z are handled by the window host.
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
        case "i": setIn(playhead.time); return true
        case "o": setOut(playhead.time); return true
        case "s": split(); return true
        case "p": playSelection(); return true
        default: return false
        }
    }

    // MARK: Export

    var canSave: Bool { !segments.isEmpty }

    func makePlan() -> TrimExportPlan {
        TrimExportPlan(source: session.url, info: session.info, segments: segments, separate: separate)
    }

    func makeExport() -> EditorExport? {
        guard canSave else { return nil }
        stopPlayback()
        let plan = makePlan()
        return { progress in try await plan.export(progress: progress) }
    }
}
