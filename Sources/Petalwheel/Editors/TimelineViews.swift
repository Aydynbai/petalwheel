import AVFoundation
import AppKit
import SwiftUI

// Reusable timeline lanes: ruler, waveform, filmstrip, playhead, scroller, preview pane.

enum TimelineStyle {
    static let rulerHeight: CGFloat = 22
    static let laneBackground = Color.primary.opacity(0.06)
    static let waveColor = KQTheme.accent
    static let playheadColor = KQTheme.danger
}

// MARK: - Ruler

struct TimelineRuler: View {
    @ObservedObject var state: TimelineState
    /// Scrub callback (seconds). `ended` is true on mouse-up.
    var onScrub: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                let w = size.width
                guard w > 0 else { return }
                let step = Self.step(visible: state.visibleDuration, width: w)
                let minor = step / 5
                var t = (state.viewStart / minor).rounded(.down) * minor
                let tickColor = Color.primary.opacity(0.35)
                while t <= state.viewEnd + minor {
                    let x = state.x(for: t, width: w)
                    let major = abs((t / step).rounded() * step - t) < minor * 0.1
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x, y: size.height - (major ? 9 : 4)))
                    ctx.stroke(p, with: .color(tickColor), lineWidth: 1)
                    if major && t >= -0.0001 {
                        let label = Text(Self.label(t, step: step))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundColor(.secondary)
                        ctx.draw(label, at: CGPoint(x: x + 3, y: 1), anchor: .topLeading)
                    }
                    t += minor
                }
            }
            .background(Color.primary.opacity(0.04))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in onScrub(state.time(at: v.location.x, width: g.size.width), false) }
                .onEnded { v in onScrub(state.time(at: v.location.x, width: g.size.width), true) })
        }
        .frame(height: TimelineStyle.rulerHeight)
    }

    static func step(visible: Double, width: CGFloat) -> Double {
        let steps: [Double] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let perPixel = visible / Double(max(width, 1))
        return steps.first { $0 / perPixel >= 70 } ?? 7200
    }

    static func label(_ t: Double, step: Double) -> String {
        let v = max(0, t)
        let whole = Int((v + 0.00001).rounded(.down))
        let m = whole / 60, s = whole % 60
        var str = m >= 60 ? String(format: "%d:%02d:%02d", m / 60, m % 60, s) : String(format: "%d:%02d", m, s)
        if step < 1 {
            let digits = step < 0.1 ? 2 : 1
            let frac = v - Double(whole)
            let scaled = Int((frac * pow(10, Double(digits))).rounded())
            str += digits == 2 ? String(format: ".%02d", scaled) : ".\(scaled)"
        }
        return str
    }
}

// MARK: - Waveform

struct WaveformLane: View {
    let peaks: WaveformPeaks
    let channel: Int
    @ObservedObject var state: TimelineState
    var color: Color = TimelineStyle.waveColor

    var body: some View {
        Canvas { ctx, size in
            WaveformLane.draw(peaks: peaks, channel: channel, start: state.viewStart,
                              span: state.visibleDuration, in: &ctx, size: size, color: color)
        }
        .background(TimelineStyle.laneBackground)
    }

    static func draw(peaks: WaveformPeaks, channel: Int, start: Double, span: Double,
                     in ctx: inout GraphicsContext, size: CGSize, color: Color) {
        let w = Int(size.width.rounded(.up))
        guard w > 0, span > 0 else { return }
        let mid = size.height / 2
        let amp = size.height / 2 - 1
        var path = Path()
        let perPx = span / Double(w)
        for px in 0..<w {
            let t0 = start + Double(px) * perPx
            guard t0 < peaks.duration else { break }
            let (lo, hi) = peaks.extent(channel: channel, from: t0, to: t0 + perPx)
            let g = peaks.displayGain
            let top = mid - CGFloat(min(hi * g, 1)) * amp
            let bottom = mid - CGFloat(max(lo * g, -1)) * amp
            path.addRect(CGRect(x: CGFloat(px), y: top, width: 1, height: max(1, bottom - top)))
        }
        ctx.fill(path, with: .color(color.opacity(0.85)))
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: mid)); axis.addLine(to: CGPoint(x: size.width, y: mid))
        ctx.stroke(axis, with: .color(color.opacity(0.35)), lineWidth: 0.5)
    }
}

/// One waveform lane per channel (or a placeholder while loading / when there's no audio).
struct WaveformStack: View {
    let peaks: WaveformPeaks?
    let loading: Bool
    @ObservedObject var state: TimelineState
    var laneHeight: CGFloat = 56
    /// Lanes grow into spare vertical space (audio-only layouts).
    var flexible = false

    var body: some View {
        if let peaks, peaks.channelCount > 0 {
            VStack(spacing: 2) {
                ForEach(0..<peaks.channelCount, id: \.self) { ch in
                    let h = peaks.channelCount > 1 ? laneHeight * 0.75 : laneHeight
                    WaveformLane(peaks: peaks, channel: ch, state: state)
                        .frame(minHeight: h, maxHeight: flexible ? h * 4 : h)
                }
            }
        } else {
            ZStack {
                TimelineStyle.laneBackground
                if loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading audio…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No audio").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: laneHeight * 0.6)
        }
    }
}

// MARK: - Filmstrip

struct FilmstripLane: View {
    let frames: FilmstripFrames?
    @ObservedObject var state: TimelineState
    var height: CGFloat = 48

    var body: some View {
        Canvas { ctx, size in
            guard let frames, !frames.images.isEmpty, size.width > 0 else { return }
            let tileW = max(16, size.height * CGFloat(frames.aspect))
            var x: CGFloat = 0
            while x < size.width {
                let t = state.time(at: x + tileW / 2, width: size.width)
                if let img = frames.image(near: t) {
                    ctx.draw(Image(decorative: img, scale: 1), in: CGRect(x: x, y: 0, width: tileW, height: size.height))
                }
                x += tileW
            }
        }
        .background(TimelineStyle.laneBackground)
        .overlay {
            if frames == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading frames…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: height)
        .clipped()
    }
}

// MARK: - Playhead

struct TimelinePlayheadOverlay: View {
    @ObservedObject var state: TimelineState
    @ObservedObject var playhead: TimelinePlayhead

    var body: some View {
        GeometryReader { g in
            let x = state.x(for: playhead.time, width: g.size.width)
            if x >= -1 && x <= g.size.width + 1 {
                ZStack(alignment: .top) {
                    Rectangle().fill(TimelineStyle.playheadColor).frame(width: 1.5)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 11, y: 0))
                        p.addLine(to: CGPoint(x: 11, y: 6)); p.addLine(to: CGPoint(x: 5.5, y: 11))
                        p.addLine(to: CGPoint(x: 0, y: 6)); p.closeSubpath()
                    }
                    .fill(TimelineStyle.playheadColor)
                    .frame(width: 11, height: 11)
                }
                .frame(width: 11, height: g.size.height)
                .position(x: x, y: g.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Scroller

/// Thin overview bar: the thumb shows the visible window, drag it to pan.
struct TimelineScroller: View {
    @ObservedObject var state: TimelineState

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let thumbW = max(24, w / CGFloat(state.zoom))
            let maxX = w - thumbW
            let span = state.duration - state.visibleDuration
            let x = span > 0 ? CGFloat(state.viewStart / span) * maxX : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule().fill(Color.primary.opacity(state.zoom > 1.001 ? 0.28 : 0.12))
                    .frame(width: thumbW)
                    .offset(x: x)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard maxX > 0 else { return }
                let pos = min(max(v.location.x - thumbW / 2, 0), maxX)
                state.setViewStart(Double(pos / maxX) * span)
            })
        }
        .frame(height: 7)
    }
}

// MARK: - Transport pieces

struct TimelineTimeReadout: View {
    @ObservedObject var playhead: TimelinePlayhead
    let duration: Double

    var body: some View {
        HStack(spacing: 3) {
            Text(TimelineClockText.format(playhead.time)).foregroundStyle(.primary)
            Text(verbatim: "/ \(TimelineClockText.format(duration))").foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
    }
}

struct TimelinePlayButton: View {
    @ObservedObject var playhead: TimelinePlayhead
    var busy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: playhead.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(width: 34, height: 26)
        }
        .buttonStyle(KQProminentButtonStyle())
        .help("Play / Pause (Space)")
    }
}

struct TimelineZoomControl: View {
    @ObservedObject var state: TimelineState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: state.zoomSlider, in: 0...log(state.maxZoom))
                .frame(width: 120)
                .controlSize(.small)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .help("Zoom (pinch or ⌘-scroll on the timeline)")
    }
}

// MARK: - Preview pane

/// Video player, a still frame from the filmstrip when AVFoundation can't play the file, or an audio card.
struct TimelinePreviewPane: View {
    let url: URL
    let hasVideo: Bool
    let player: AVPlayer?
    /// nil while still checking.
    let playable: Bool?
    let frames: FilmstripFrames?
    @ObservedObject var playhead: TimelinePlayhead
    var unavailableText = "Preview unavailable, you can still scrub and export"

    var body: some View {
        ZStack {
            Color.black.opacity(hasVideo ? 0.9 : 0)
            if hasVideo {
                if let player, playable == true {
                    TimelinePlayerView(player: player)
                } else if let img = frames?.image(near: playhead.time) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
            } else {
                audioCard
            }
            if playable == false {
                VStack {
                    Spacer()
                    Label(L(unavailableText), systemImage: "eye.slash")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var audioCard: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(L("%@ audio", url.pathExtension.uppercased())).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// "Loading…" / error screen shown before the media has been probed.
struct TimelineLoadingView: View {
    let name: String
    let error: String?
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(KQTheme.warning)
                Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Close", action: onCancel).buttonStyle(KQSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            } else {
                ProgressView()
                Text(L("Opening “%@”…", name)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// Small key-cap hint used in footers.
struct TimelineKeyHint: View {
    let key: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(L(key))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5)))
            Text(L(text)).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}
