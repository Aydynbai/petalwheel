import AppKit
import SwiftUI

// Trim editor views: layout, transport, options, footer and the clip timeline.

// MARK: - Views

struct TrimRootView: View {
    @ObservedObject var controller: TimelineEditorController<TrimDocument>
    let host: EditorWindowHost

    var body: some View {
        Group {
            if let doc = controller.doc {
                TrimEditorView(doc: doc, session: doc.session, host: host)
            } else {
                TimelineLoadingView(name: controller.url.lastPathComponent, error: controller.error) {
                    controller.cancel()
                }
            }
        }
        .frame(minWidth: 700, minHeight: 440)
    }
}

struct TrimEditorView: View {
    @ObservedObject var doc: TrimDocument
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
            TimelinePreviewPane(url: session.url, hasVideo: session.hasVideo, player: doc.player,
                                playable: session.playable, frames: session.frames, playhead: session.playhead)
                .frame(minHeight: session.hasVideo ? 220 : 80, maxHeight: .infinity)
            transport
            TrimTimelineView(doc: doc, session: session, timeline: session.timeline)
            optionsRow
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            TimelinePlayButton(playhead: session.playhead) { doc.togglePlay() }
            Button { doc.playSelection() } label: { Label("Play Selection", systemImage: "play.square") }
                .buttonStyle(KQSecondaryButtonStyle()).help("Play the result, skipping removed clips (P)")
            TimelineTimeReadout(playhead: session.playhead, duration: session.duration)
            Spacer(minLength: 8)
            ImageCanvasIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: doc.canUndo) { doc.undo() }
            ImageCanvasIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: doc.canRedo) { doc.redo() }
            Button { doc.split() } label: { Label("Split", systemImage: "scissors") }
                .buttonStyle(KQSecondaryButtonStyle()).help("Split at the playhead (S)")
            Button { doc.deleteSelected() } label: { Label("Delete Clip", systemImage: "trash") }
                .buttonStyle(KQSecondaryButtonStyle()).disabled(doc.selectedClip == nil)
                .help("Remove the selected clip (Delete)")
            TimelineZoomControl(state: session.timeline)
        }
    }

    private var optionsRow: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 6) {
                Text("Start").foregroundStyle(.secondary)
                TimelineTimeField(value: doc.inPoint) { doc.setIn($0) }.frame(width: 92)
                Button { doc.setIn(session.playhead.time) } label: { Image(systemName: "arrow.right.to.line") }
                    .buttonStyle(.borderless).help("Set start to playhead (I)")
            }
            HStack(spacing: 6) {
                Text("End").foregroundStyle(.secondary)
                TimelineTimeField(value: doc.outPoint) { doc.setOut($0) }.frame(width: 92)
                Button { doc.setOut(session.playhead.time) } label: { Image(systemName: "arrow.left.to.line") }
                    .buttonStyle(.borderless).help("Set end to playhead (O)")
            }
            Text(L("Result %@", TimelineClockText.format(doc.resultDuration)))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if doc.segments.count > 1 {
                Picker("", selection: $doc.separate) {
                    Text("Join clips into one file").tag(false)
                    Text("Export each clip separately").tag(true)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 220)
            }
            if doc.isAudioOnly && session.info.hasAudio {
                Toggle("Trim silent ends automatically", isOn: $doc.autoSilence)
                    .toggleStyle(.checkbox)
                if doc.autoSilence {
                    Slider(value: $doc.silenceDB, in: -80 ... -10, step: 1).frame(width: 100).controlSize(.small)
                    Text(verbatim: "\(Int(doc.silenceDB)) dB").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                }
            }
        }
        .font(.system(size: 12))
    }

    private var footer: some View {
        EditorFooter(host: host, saveTitle: saveTitle, saveHelp: "Save (⌘S or Return)", canSave: doc.canSave) {
            EditorFileInfo(name: session.url.lastPathComponent,
                           detail: Text(TimelineFileInfo.detail(session.info)))
        } accessory: {
            HStack(spacing: 14) {
                TimelineKeyHint(key: "Space", text: "Play")
                TimelineKeyHint(key: "I / O", text: "In / Out")
                TimelineKeyHint(key: "S", text: "Split")
                TimelineKeyHint(key: "⌫", text: "Delete clip")
                TimelineKeyHint(key: "← →", text: session.hasVideo ? L("Frame") : L("0.1 s"))
            }
            .padding(.trailing, 12)
        }
    }

    private var saveTitle: String {
        let n = doc.segments.count
        return doc.separate && n > 1 ? Lp("Save %d Clips", n) : "Save"
    }
}

/// Ruler + filmstrip + waveform with clip blocks, in/out handles and the playhead.
struct TrimTimelineView: View {
    @ObservedObject var doc: TrimDocument
    @ObservedObject var session: TimelineSession
    @ObservedObject var timeline: TimelineState

    private static let space = "trimTrack"

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 0) {
                    TimelineRuler(state: timeline) { t, _ in doc.seek(t) }
                    VStack(spacing: 2) {
                        if session.hasVideo {
                            FilmstripLane(frames: session.frames, state: timeline, height: 52)
                        }
                        if session.info.hasAudio {
                            WaveformStack(peaks: session.peaks, loading: session.peaksLoading, state: timeline,
                                          laneHeight: session.hasVideo ? 44 : 70, flexible: !session.hasVideo)
                        }
                    }
                    .overlay(clipOverlay)
                    .coordinateSpace(name: Self.space)
                    .timelineTrackArea(timeline)
                    .padding(.top, 2)
            }
            .overlay(TimelinePlayheadOverlay(state: timeline, playhead: session.playhead))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            TimelineScroller(state: timeline)
        }
    }

    private var clipOverlay: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let inX = timeline.x(for: doc.inPoint, width: w)
            let outX = timeline.x(for: doc.outPoint, width: w)
            ZStack(alignment: .topLeading) {
                // Scrub / select surface.
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { v in doc.seek(timeline.time(at: v.location.x, width: w)) }
                        .onEnded { v in
                            let t = timeline.time(at: v.location.x, width: w)
                            if abs(v.translation.width) < 3 {
                                doc.selectedClip = doc.clip(at: t)?.id
                            }
                        })

                // Removed parts (gaps between clips).
                ForEach(gaps(), id: \.0) { gap in
                    let x0 = timeline.x(for: gap.0, width: w), x1 = timeline.x(for: gap.1, width: w)
                    removedPattern
                        .frame(width: max(0, x1 - x0), height: h)
                        .offset(x: x0)
                        .allowsHitTesting(false)
                }

                // Outside the in/out range.
                Rectangle().fill(Color.black.opacity(0.45))
                    .frame(width: max(0, min(inX, w)), height: h)
                    .allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.45))
                    .frame(width: max(0, w - max(outX, 0)), height: h)
                    .offset(x: max(outX, 0))
                    .allowsHitTesting(false)

                // Clip outlines.
                ForEach(doc.clips) { clip in
                    let x0 = timeline.x(for: clip.start, width: w), x1 = timeline.x(for: clip.end, width: w)
                    let selected = doc.selectedClip == clip.id
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(selected ? KQTheme.accent : Color.white.opacity(0.55), lineWidth: selected ? 2.5 : 1)
                        .background(selected ? KQTheme.accent.opacity(0.12) : Color.clear)
                        .frame(width: max(2, x1 - x0), height: h)
                        .offset(x: x0)
                        .allowsHitTesting(false)
                }

                handle(isIn: true, x: inX, width: w, height: h)
                handle(isIn: false, x: outX, width: w, height: h)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
        }
    }

    private var removedPattern: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.55)))
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 8
            }
            ctx.stroke(p, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
        }
    }

    private func gaps() -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        var cursor = 0.0
        for c in doc.clips.sorted(by: { $0.start < $1.start }) {
            if c.start - cursor > 0.001 { result.append((cursor, c.start)) }
            cursor = max(cursor, c.end)
        }
        if session.duration - cursor > 0.001 { result.append((cursor, session.duration)) }
        return result
    }

    private func handle(isIn: Bool, x: CGFloat, width w: CGFloat, height h: CGFloat) -> some View {
        let bracket = Path { p in
            if isIn {
                p.move(to: CGPoint(x: 9, y: 0)); p.addLine(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 9, y: h))
            } else {
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 9, y: 0))
                p.addLine(to: CGPoint(x: 9, y: h)); p.addLine(to: CGPoint(x: 0, y: h))
            }
        }
        return ZStack(alignment: isIn ? .leading : .trailing) {
            bracket.stroke(KQTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: 9, height: h)
            Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: min(18, h / 3))
                .padding(isIn ? .leading : .trailing, 4)
        }
        .frame(width: 18, height: h, alignment: isIn ? .leading : .trailing)
        .contentShape(Rectangle())
        .offset(x: isIn ? min(max(x - 2, 0), w - 18) : max(min(x - 16, w - 18), 0))
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                let t = timeline.time(at: v.location.x, width: w)
                if isIn { doc.setIn(t) } else { doc.setOut(t) }
                doc.seek(isIn ? doc.inPoint : doc.outPoint)
            })
        .help(isIn ? L("Drag to set the start (I)") : L("Drag to set the end (O)"))
    }
}
