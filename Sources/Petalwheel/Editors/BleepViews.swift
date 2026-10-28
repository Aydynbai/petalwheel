import AppKit
import SwiftUI

// Bleep editor views: layout, transport, options, footer and the range timeline.

// MARK: - Views

struct BleepRootView: View {
    @ObservedObject var controller: TimelineEditorController<BleepDocument>
    let host: EditorWindowHost

    var body: some View {
        Group {
            if let doc = controller.doc {
                BleepEditorView(doc: doc, session: doc.session, host: host)
            } else {
                TimelineLoadingView(name: controller.url.lastPathComponent, error: controller.error) {
                    controller.cancel()
                }
            }
        }
        .frame(minWidth: 700, minHeight: 420)
    }
}

struct BleepEditorView: View {
    @ObservedObject var doc: BleepDocument
    @ObservedObject var session: TimelineSession
    let host: EditorWindowHost

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(KQTheme.padding)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var content: some View {
        VStack(spacing: 10) {
            if session.hasVideo {
                TimelinePreviewPane(url: session.url, hasVideo: true, player: doc.videoPlayer,
                                    playable: session.playable, frames: session.frames, playhead: session.playhead,
                                    unavailableText: "Video preview unavailable, audio preview and export still work")
                    .frame(minHeight: 200, maxHeight: .infinity)
            }
            transport
            BleepTimelineView(doc: doc, session: session, timeline: session.timeline)
                .frame(maxHeight: session.hasVideo ? nil : .infinity)
            optionsRow
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            TimelinePlayButton(playhead: session.playhead, busy: doc.renderingPreview) { doc.togglePlay() }
            TimelineTimeReadout(playhead: session.playhead, duration: session.duration)
            if let err = doc.previewError {
                Text(err).font(.caption).foregroundStyle(KQTheme.danger).lineLimit(1).help(err)
            }
            Spacer(minLength: 8)
            Button { doc.addAtPlayhead() } label: { Label("Add Bleep at Playhead", systemImage: "plus.rectangle") }
                .buttonStyle(KQSecondaryButtonStyle()).help("Adds a 0.5 s bleep (B)")
            Button { doc.deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                .buttonStyle(KQSecondaryButtonStyle()).disabled(doc.selected == nil)
                .help("Remove the selected bleep (Delete)")
            TimelineZoomControl(state: session.timeline)
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 16) {
            Picker("Style", selection: $doc.style) {
                ForEach(BleepStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $doc.volume, in: 0.05...1).frame(width: 120).controlSize(.small)
                Text(volumeText).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }
            .disabled(doc.style == .silence)
            .opacity(doc.style == .silence ? 0.45 : 1)
            .help("Beep volume")
            Toggle("Bleep entire audio", isOn: $doc.entire).toggleStyle(.checkbox)
            Spacer()
            Text(summary).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    private var volumeText: String {
        let db = 20 * log10(max(doc.volume, 0.0001))
        return String(format: "%.0f dB", db)
    }

    private var summary: String {
        if doc.entire { return L("Whole track") }
        let n = doc.ranges.count
        if n == 0 { return L("Drag on the waveform to add a bleep") }
        return Lp("%d bleeps", n) + " · " + L("%.1f s", doc.totalBleeped)
    }

    private var footer: some View {
        EditorFooter(host: host, saveHelp: "Save (⌘S or Return)", canSave: doc.canSave) {
            EditorFileInfo(name: session.url.lastPathComponent,
                           detail: Text(TimelineFileInfo.detail(session.info)))
        } accessory: {
            HStack(spacing: 14) {
                TimelineKeyHint(key: "Space", text: "Preview")
                TimelineKeyHint(key: "B", text: "Bleep at playhead")
                TimelineKeyHint(key: "I / O", text: "Bleep start / end")
                TimelineKeyHint(key: "⌫", text: "Delete")
            }
            .padding(.trailing, 12)
        }
    }
}

struct BleepTimelineView: View {
    @ObservedObject var doc: BleepDocument
    @ObservedObject var session: TimelineSession
    @ObservedObject var timeline: TimelineState

    private static let space = "bleepTrack"
    static let rangeColor = KQTheme.danger

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 0) {
                    TimelineRuler(state: timeline) { t, _ in doc.seek(t) }
                    VStack(spacing: 2) {
                        if session.hasVideo {
                            FilmstripLane(frames: session.frames, state: timeline, height: 36)
                        }
                        waveform
                    }
                    .overlay(rangeOverlay)
                    .coordinateSpace(name: Self.space)
                    .timelineTrackArea(timeline)
                    .padding(.top, 2)
            }
            .overlay(TimelinePlayheadOverlay(state: timeline, playhead: session.playhead))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            TimelineScroller(state: timeline)
        }
    }

    @ViewBuilder private var waveform: some View {
        if let peaks = session.peaks, peaks.channelCount > 0 {
            VStack(spacing: 2) {
                ForEach(0..<peaks.channelCount, id: \.self) { ch in
                    WaveformLane(peaks: peaks, channel: ch, state: timeline)
                        .frame(minHeight: 50, maxHeight: session.hasVideo ? 56 : .infinity)
                }
            }
        } else {
            WaveformStack(peaks: nil, loading: session.peaksLoading, state: timeline, laneHeight: 90)
        }
    }

    private var rangeOverlay: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                if doc.entire {
                    Self.rangeColor.opacity(0.28)
                        .overlay(Text("Entire audio bleeped").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white).shadow(radius: 2))
                        .allowsHitTesting(false)
                }
                ForEach(doc.ranges) { r in
                    let x0 = timeline.x(for: r.start, width: w), x1 = timeline.x(for: r.end, width: w)
                    let sel = doc.selected == r.id
                    ZStack {
                        Rectangle().fill(Self.rangeColor.opacity(sel ? 0.5 : 0.32))
                        Rectangle().strokeBorder(sel ? Color.white : Self.rangeColor, lineWidth: sel ? 2 : 1)
                        if x1 - x0 > 46 {
                            Text(doc.style == .tone ? L("BEEP") : L("MUTE"))
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.top, 3)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                        HStack {
                            Capsule().fill(Color.white.opacity(sel ? 0.95 : 0.6)).frame(width: 3, height: min(22, h / 3))
                            Spacer(minLength: 0)
                            Capsule().fill(Color.white.opacity(sel ? 0.95 : 0.6)).frame(width: 3, height: min(22, h / 3))
                        }
                        .padding(.horizontal, 2)
                        .opacity(x1 - x0 > 14 ? 1 : 0)
                    }
                    .frame(width: max(2, x1 - x0), height: h)
                    .offset(x: x0)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { v in doc.dragChanged(start: v.startLocation, location: v.location, width: w) }
                .onEnded { v in doc.dragEnded(start: v.startLocation, location: v.location, width: w) })
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                updateCursor(phase, width: w)
            }
        }
    }

    private func updateCursor(_ phase: HoverPhase, width w: CGFloat) {
        switch phase {
        case .active(let p):
            let t = timeline.time(at: p.x, width: w)
            let edge = timeline.seconds(forPixels: 6, width: w)
            if doc.ranges.contains(where: { abs($0.start - t) <= edge || abs($0.end - t) <= edge }) {
                NSCursor.resizeLeftRight.set()
            } else if doc.range(at: t) != nil {
                NSCursor.openHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        case .ended:
            NSCursor.arrow.set()
        }
    }
}
