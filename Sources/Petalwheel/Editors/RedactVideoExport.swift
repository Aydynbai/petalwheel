import Foundation
import AppKit

// Redact Video: the edit model (one rectangle per region) and the ffmpeg export.

/// sRGB colour of a solid redaction box.
struct RedactVideoRGB: Equatable {
    var r: Double, g: Double, b: Double

    static let black = RedactVideoRGB(r: 0, g: 0, b: 0)

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        r = Double(c.redComponent); g = Double(c.greenComponent); b = Double(c.blueComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    /// `0xRRGGBB` for ffmpeg colour options.
    var ffmpegHex: String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "0x%02X%02X%02X", c(r), c(g), c(b))
    }
}

/// One redaction rectangle with its own time range and style.
struct RedactVideoRegion: Identifiable, Equatable {
    let id: UUID
    /// Display-pixel rectangle of the rotated video (top-left origin).
    var rect: CGRect
    var start: Double
    var end: Double
    var entireVideo: Bool
    var style: RedactionStyle
    /// 0...1, maps to the blur radius / pixel block size.
    var strength: Double
    var color: RedactVideoRGB
    /// Index into the layer palette (stable colour on the timeline).
    var tint: Int

    init(rect: CGRect, start: Double, end: Double, entireVideo: Bool = false,
         style: RedactionStyle = .blur, strength: Double = 0.6,
         color: RedactVideoRGB = .black, tint: Int = 0) {
        id = UUID()
        self.rect = rect
        self.start = start
        self.end = end
        self.entireVideo = entireVideo
        self.style = style
        self.strength = strength
        self.color = color
        self.tint = tint
    }

    /// Effective time range in seconds.
    func range(duration: Double) -> ClosedRange<Double> {
        if entireVideo { return 0...max(duration, 0) }
        let s = max(0, start), e = max(s, end)
        return s...e
    }

    func isVisible(at t: Double, duration: Double) -> Bool {
        let r = range(duration: duration)
        // The last frame of the video sits slightly before `duration`.
        let upper = r.upperBound >= duration - 0.001 ? .infinity : r.upperBound
        return t >= r.lowerBound - 0.0005 && t <= upper
    }
}

/// Integer, even-aligned crop rectangle inside the frame.
struct RedactVideoPixelRect: Equatable {
    var x: Int, y: Int, w: Int, h: Int
}

enum RedactVideoExport {
    /// Immutable snapshot handed to the export closure.
    struct Job {
        let source: URL
        let info: MediaInfo
        let regions: [RedactVideoRegion]
        let duration: Double
    }

    /// Output container: keep mp4 / mov / mkv / webm, everything else becomes mp4.
    static func outputFormat(for source: URL) -> FileFormat {
        switch FileFormat.detect(source) {
        case .mov?: return .mov
        case .mkv?: return .mkv
        case .webm?: return .webm
        default: return .mp4
        }
    }

    /// Even display size the filtergraph works in (rects are in these pixels).
    static func frameSize(width: Int, height: Int) -> (w: Int, h: Int) {
        (max(2, width / 2 * 2), max(2, height / 2 * 2))
    }

    /// Clamps `rect` to the frame and aligns it to even pixels. nil when too small to matter.
    static func pixelRect(_ rect: CGRect, frameWidth fw: Int, frameHeight fh: Int) -> RedactVideoPixelRect? {
        let r = rect.standardized.intersection(CGRect(x: 0, y: 0, width: fw, height: fh))
        guard !r.isNull, r.width >= 2, r.height >= 2 else { return nil }
        var x0 = Int(r.minX.rounded(.down)) / 2 * 2
        var y0 = Int(r.minY.rounded(.down)) / 2 * 2
        var x1 = min(fw, (Int(r.maxX.rounded(.up)) + 1) / 2 * 2)
        var y1 = min(fh, (Int(r.maxY.rounded(.up)) + 1) / 2 * 2)
        // Keep at least 8×8 so boxblur / pixelize have room.
        if x1 - x0 < 8 { x1 = min(fw, x0 + 8); x0 = max(0, x1 - 8) }
        if y1 - y0 < 8 { y1 = min(fh, y0 + 8); y0 = max(0, y1 - 8) }
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { return nil }
        return RedactVideoPixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// Box-blur radius for one pass (three passes are applied, so sigma ≈ radius).
    static func blurRadius(strength: Double, w: Int, h: Int) -> Int {
        let side = Double(min(w, h))
        let desired = Int((2 + max(0, min(1, strength)) * side * 0.22).rounded())
        return max(1, min(desired, min(w, h) / 2))
    }

    /// Pixelate block size in pixels.
    static func pixelBlock(strength: Double, w: Int, h: Int) -> Int {
        let side = Double(min(w, h))
        let s = max(0, min(1, strength))
        return max(2, min(Int((side * (0.04 + 0.21 * s)).rounded()), min(w, h)))
    }

    private static func num(_ v: Double) -> String { String(format: "%.3f", v) }

    /// One filter_complex for all regions; input `[0:<videoIndex>]`, output `[vout]`.
    static func filterGraph(regions: [RedactVideoRegion], videoIndex: Int,
                            width: Int, height: Int, duration: Double) -> String {
        let (fw, fh) = frameSize(width: width, height: height)
        // ffmpeg autorotates before the graph; the scale also squares anamorphic pixels so
        // the graph works in exactly the display pixels the editor used.
        var parts = ["[0:\(videoIndex)]scale=\(fw):\(fh),setsar=1[v0]"]
        var cur = "v0"
        var n = 0
        for region in regions {
            guard let p = pixelRect(region.rect, frameWidth: fw, frameHeight: fh) else { continue }
            let range = region.range(duration: duration)
            guard range.upperBound - range.lowerBound > 0.0005 else { continue }
            let lo = range.lowerBound <= 0.0005 ? "-1" : num(range.lowerBound)
            let hi = range.upperBound >= duration - 0.001 ? num(duration + 3600) : num(range.upperBound)
            let enable = "enable='between(t,\(lo),\(hi))'"
            n += 1
            let next = "v\(n)"
            switch region.style {
            case .solid:
                parts.append("[\(cur)]drawbox=x=\(p.x):y=\(p.y):w=\(p.w):h=\(p.h):color=\(region.color.ffmpegHex)@1.0:t=fill:\(enable)[\(next)]")
            case .blur, .pixelate:
                let effect: String
                if region.style == .blur {
                    let luma = blurRadius(strength: region.strength, w: p.w, h: p.h)
                    let chroma = max(1, min((luma + 1) / 2, min(p.w, p.h) / 4))
                    effect = "boxblur=luma_radius=\(luma):luma_power=3:chroma_radius=\(chroma):chroma_power=3"
                } else {
                    let b = pixelBlock(strength: region.strength, w: p.w, h: p.h)
                    effect = "pixelize=width=\(b):height=\(b):mode=avg"
                }
                parts.append("[\(cur)]split[\(cur)a][\(cur)b]")
                parts.append("[\(cur)b]crop=w=\(p.w):h=\(p.h):x=\(p.x):y=\(p.y),\(effect)[p\(n)]")
                parts.append("[\(cur)a][p\(n)]overlay=x=\(p.x):y=\(p.y):\(enable)[\(next)]")
            }
            cur = next
        }
        parts.append("[\(cur)]format=yuv420p[vout]")
        return parts.joined(separator: ";")
    }

    /// Full ffmpeg argument list (without the standard flags FFmpeg.run adds).
    static func arguments(_ job: Job, output: URL, copyAudio: Bool) throws -> [String] {
        guard let vIdx = job.info.videoIndex else {
            throw PetalwheelError(l: "“%@” has no video track.", job.source.lastPathComponent)
        }
        let target = outputFormat(for: job.source)
        let graph = filterGraph(regions: job.regions, videoIndex: vIdx,
                                width: job.info.width, height: job.info.height, duration: job.duration)
        var a = ["-i", job.source.path, "-filter_complex", graph, "-map", "[vout]"]
        if job.info.hasAudio {
            for i in job.info.audioIndices { a += ["-map", "0:\(i)"] }
            if copyAudio {
                a += ["-c:a", "copy"]
            } else if target == .webm {
                a += ["-c:a", "libopus", "-b:a", "160k"]
            } else {
                a += ["-c:a", FFmpeg.aacEncoder, "-b:a", "256k"]
            }
        }
        a += MediaEncoding.videoCodecArgs(for: target, spec: MediaEncodeSpec(target: target, quality: .high))
        a += ["-sn", "-dn", "-max_muxing_queue_size", "4096"]
        a += MediaEncoding.metadataArgs(preserve: true)
        if target == .mp4 || target == .mov { a += ["-movflags", "+faststart"] }
        a += ["-f", target == .mkv ? "matroska" : target.rawValue, output.path]
        return a
    }

    /// Writes `<name> (redacted).<ext>` next to the source and returns it.
    static func run(_ job: Job, progress: @escaping ProgressHandler) async throws -> [URL] {
        let target = outputFormat(for: job.source)
        let final = OutputNaming.url(for: job.source, ext: target.fileExtension, suffix: "redacted")
        let duration = job.duration > 0 ? job.duration : job.info.duration
        // Copy audio when the container stays the same (avi / wmv etc. become mp4 with AAC).
        let copy = FileFormat.detect(job.source) == target
        progress(0)
        let out = try await MediaOutput.produce(final) { temp in
            do {
                try await FFmpeg.run(try arguments(job, output: temp, copyAudio: copy),
                                     duration: duration, progress: progress)
            } catch is ProcessError where job.info.hasAudio && copy {
                // The source audio codec doesn't fit the container: re-encode it instead.
                try? FileManager.default.removeItem(at: temp)
                try await FFmpeg.run(try arguments(job, output: temp, copyAudio: false),
                                     duration: duration, progress: progress)
            }
        }
        progress(1)
        return [out]
    }
}
