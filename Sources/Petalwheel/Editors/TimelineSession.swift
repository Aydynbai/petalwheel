import AVFoundation
import Foundation

/// One opened media file for a timeline editor: probe info plus asynchronously loaded waveform,
/// filmstrip and playability.
@MainActor
final class TimelineSession: ObservableObject {
    let url: URL
    let info: MediaInfo
    let timeline: TimelineState
    let playhead = TimelinePlayhead()

    @Published private(set) var peaks: WaveformPeaks?
    @Published private(set) var peaksLoading: Bool
    @Published private(set) var frames: FilmstripFrames?
    /// nil while checking.
    @Published private(set) var playable: Bool?

    private var tasks: [Task<Void, Never>] = []
    private var onPeaks: [(WaveformPeaks) -> Void] = []

    var hasVideo: Bool { info.hasVideo }
    var duration: Double { max(info.duration, 0.01) }
    /// One frame for video, 0.1 s for audio.
    var nudgeStep: Double { info.hasVideo && info.fps > 0 ? 1 / info.fps : 0.1 }

    init(url: URL, info: MediaInfo) {
        self.url = url
        self.info = info
        timeline = TimelineState(duration: info.duration)
        peaksLoading = info.hasAudio
    }

    /// Probes `url` (ffprobe) and returns a session that starts loading peaks / frames immediately.
    static func open(_ url: URL) async throws -> TimelineSession {
        let info = try await MediaProbe.probe(url)
        guard info.duration > 0.05 else {
            throw NurToError(l: "“%@” has no playable duration.", url.lastPathComponent)
        }
        guard info.hasAudio || info.hasVideo else {
            throw NurToError(l: "“%@” has no audio or video.", url.lastPathComponent)
        }
        let s = TimelineSession(url: url, info: info)
        s.startLoading()
        return s
    }

    /// Unit tests / harness: wait for all background loads.
    func waitUntilLoaded() async {
        for t in tasks { await t.value }
    }

    /// Calls `body` once peaks are available (immediately if already loaded).
    func whenPeaksLoaded(_ body: @escaping (WaveformPeaks) -> Void) {
        if let peaks { body(peaks) } else { onPeaks.append(body) }
    }

    private func startLoading() {
        let url = self.url, info = self.info
        if info.hasAudio {
            tasks.append(Task { [weak self] in
                let p = await Task.detached(priority: .userInitiated) {
                    try? await TimelineMediaLoader.peaks(for: url, info: info)
                }.value
                guard let self else { return }
                self.peaks = p
                self.peaksLoading = false
                if let p { self.onPeaks.forEach { $0(p) } }
                self.onPeaks = []
            })
        }
        if info.hasVideo {
            let count = min(80, max(12, Int(info.duration * 2)))
            tasks.append(Task { [weak self] in
                let f = await Task.detached(priority: .userInitiated) {
                    await TimelineMediaLoader.filmstrip(for: url, info: info, count: count)
                }.value
                self?.frames = f
            })
        }
        tasks.append(Task { [weak self] in
            let ok = await TimelineMediaLoader.isPlayable(url)
            self?.playable = ok
        })
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
    }
}
