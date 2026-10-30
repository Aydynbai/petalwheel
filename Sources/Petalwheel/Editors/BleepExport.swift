import Foundation

enum BleepStyle: String, CaseIterable, Identifiable {
    case tone, silence
    var id: String { rawValue }
    var title: String { self == .tone ? L("1 kHz tone") : L("Silence") }
}

/// Immutable snapshot of a bleep edit. Mutes the ranges with `volume=…:enable=` and, for the tone style,
/// mixes in a 1 kHz sine gated to the same ranges (`aevalsrc` + `amix=normalize=0`).
struct BleepExportPlan {
    struct Range: Equatable { var start: Double; var end: Double }

    let source: URL
    let info: MediaInfo
    /// Sorted, merged, clamped to the duration.
    let ranges: [Range]
    let entire: Bool
    let style: BleepStyle
    /// Linear tone amplitude, 0...1.
    let volume: Double

    static let toneFrequency = 1000.0

    init(source: URL, info: MediaInfo, ranges: [Range], entire: Bool, style: BleepStyle, volume: Double) {
        self.source = source
        self.info = info
        self.ranges = Self.normalize(ranges, duration: info.duration)
        self.entire = entire
        self.style = style
        self.volume = min(max(volume, 0), 1)
    }

    var isEmpty: Bool { !entire && ranges.isEmpty }

    static func normalize(_ ranges: [Range], duration: Double) -> [Range] {
        let clamped = ranges.map { Range(start: max(0, min($0.start, $0.end)), end: min(duration, max($0.start, $0.end))) }
            .filter { $0.end - $0.start > 0.005 }
            .sorted { $0.start < $1.start }
        var merged: [Range] = []
        for r in clamped {
            if let last = merged.last, r.start <= last.end {
                merged[merged.count - 1].end = max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Gate expression in the filter's own time base (input time minus `offset`); nil = nothing in the window.
    func gate(offset: Double = 0, length: Double? = nil) -> String? {
        if entire { return "1" }
        let window = length.map { offset + $0 } ?? .greatestFiniteMagnitude
        let parts = ranges.filter { $0.end > offset && $0.start < window }.map { r in
            "between(t,\(FFmpeg.filterNumber(r.start - offset)),\(FFmpeg.filterNumber(r.end - offset)))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }

    /// Filtergraph from `[0:<audio>]` to `[aout]`. `offset`/`length` describe a preview window cut with input -ss/-t.
    func filterGraph(offset: Double = 0, length: Double? = nil) throws -> String {
        guard let aIdx = info.audioIndices.first else {
            throw NurToError(l: "“%@” has no audio track.", source.lastPathComponent)
        }
        let input = "[0:\(aIdx)]"
        guard let g = gate(offset: offset, length: length) else {
            return input + "anull[aout]"
        }
        // Small frames so the timeline `enable` switches close to the exact range edges.
        let muted = "asetnsamples=n=256:p=0,volume=0:enable='\(g)'"
        if style == .silence || volume <= 0 {
            return input + muted + "[aout]"
        }
        let sr = info.sampleRate > 0 ? info.sampleRate : 48000
        let channels = max(1, min(info.channels, 8))
        let toneDuration = (length ?? info.duration) + 1
        let expr = "\(FFmpeg.filterNumber(volume))*sin(2*PI*\(Int(Self.toneFrequency))*t)*gt(\(g),0)"
        let exprs = Array(repeating: expr, count: channels).joined(separator: "|")
        return input + muted + "[m];"
            + "aevalsrc='\(exprs)':s=\(sr):d=\(FFmpeg.filterNumber(toneDuration))[b];"
            + "[m][b]amix=inputs=2:normalize=0:duration=first:dropout_transition=0[aout]"
    }

    func export(progress: @escaping ProgressHandler) async throws -> [URL] {
        guard info.hasAudio else { throw NurToError(l: "“%@” has no audio track.", source.lastPathComponent) }
        progress(0)
        let target = TimelineOutput.target(for: source, info: info)
        let ext = TimelineOutput.ext(for: source, target: target)
        var spec = MediaEncodeSpec(target: target)
        spec.quality = .high
        spec.sourceName = source.lastPathComponent
        spec.preferLossless = true

        var args = ["-i", source.path, "-filter_complex", try filterGraph()]
        let isVideo = info.hasVideo && MediaEncoding.videoTargets.contains(target)
        if isVideo, let v = info.videoIndex {
            // Video untouched: stream copy; only the audio is re-encoded.
            args += ["-map", "0:\(v)", "-map", "[aout]", "-c:v", "copy"]
        } else {
            args += ["-map", "[aout]"]
            if let pic = info.attachedPicIndex, target == .mp3 || target == .m4a {
                args += ["-map", "0:\(pic)", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
            } else {
                args += ["-vn"]
            }
        }
        args += MediaEncoding.audioCodecArgs(for: target, spec: spec, info: info)
        args += ["-sn", "-dn"]
        if target == .mp4 || target == .mov || target == .m4a { args += ["-movflags", "+faststart"] }
        if target == .mp3 { args += ["-id3v2_version", "3"] }
        args += MediaEncoding.metadataArgs(preserve: true)

        let final = OutputNaming.url(for: source, ext: ext, suffix: "bleeped")
        let out = try await MediaOutput.produce(final) { temp in
            try await FFmpeg.run(args + [temp.path], duration: info.duration, progress: progress)
        }
        progress(1)
        return [out]
    }

    /// Renders [start, start + length) of the bleeped audio to a WAV for preview playback.
    func renderPreview(from start: Double, length: Double, to url: URL) async throws {
        let graph = try filterGraph(offset: start, length: length)
        try await FFmpeg.run(["-ss", TimelineOutput.seconds(start), "-t", TimelineOutput.seconds(length),
                              "-i", source.path, "-filter_complex", graph, "-map", "[aout]", "-vn", "-sn",
                              "-ac", "\(min(max(info.channels, 1), 2))", "-c:a", "pcm_s16le", url.path],
                             duration: length)
    }
}
