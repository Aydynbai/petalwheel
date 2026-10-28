import Foundation

/// Immutable snapshot of a trim edit, exported with a frame-accurate ffmpeg re-encode.
struct TrimExportPlan {
    struct Segment: Equatable { var start: Double; var end: Double; var length: Double { end - start } }

    let source: URL
    let info: MediaInfo
    /// Kept parts of the timeline, in order.
    let segments: [Segment]
    /// true = one file per segment, false = join into one file.
    let separate: Bool

    func export(progress: @escaping ProgressHandler) async throws -> [URL] {
        guard !segments.isEmpty else { throw PetalwheelError(l: "Nothing is left to export: every part was removed.") }
        progress(0)
        let target = TimelineOutput.target(for: source, info: info)
        let ext = TimelineOutput.ext(for: source, target: target)
        if separate || segments.count == 1 {
            let total = segments.reduce(0) { $0 + $1.length }
            var done = 0.0
            var outputs: [URL] = []
            do {
                for (i, seg) in segments.enumerated() {
                    try Task.checkCancellation()
                    let suffix = segments.count == 1 ? "trimmed" : "part \(i + 1)"
                    let final = OutputNaming.url(for: source, ext: ext, suffix: suffix)
                    let span = (done / total)...((done + seg.length) / total)
                    outputs.append(try await encodeSegment(seg, target: target, to: final, progress: progress, span: span))
                    done += seg.length
                }
            } catch {
                outputs.forEach { try? FileManager.default.removeItem(at: $0) }
                throw error
            }
            progress(1)
            return outputs
        }
        let out = try await encodeJoined(target: target,
                                         to: OutputNaming.url(for: source, ext: ext, suffix: "trimmed"),
                                         progress: progress)
        progress(1)
        return [out]
    }

    private func spec(_ target: FileFormat) -> MediaEncodeSpec {
        var s = MediaEncodeSpec(target: target)
        s.quality = .high
        s.sourceName = source.lastPathComponent
        s.sourceIsGIF = FileFormat.detect(source) == .gif
        s.preferLossless = true
        if target == .gif, info.fps > 0 {
            s.gifFrameRate = Int(info.fps.rounded())
            s.gifMaxWidth = max(info.width, info.height, 16)
        }
        return s
    }

    /// `-ss` before `-i` with a re-encode is frame accurate (ffmpeg decodes and drops up to the cut).
    private func encodeSegment(_ seg: Segment, target: FileFormat, to final: URL,
                               progress: @escaping ProgressHandler, span: ClosedRange<Double>) async throws -> URL {
        let args = try MediaEncoding.outputArgs(spec(target), info: info)
        let input = ["-ss", TimelineOutput.seconds(seg.start), "-t", TimelineOutput.seconds(seg.length), "-i", source.path]
        return try await MediaOutput.produce(final) { temp in
            try await FFmpeg.run(input + args + [temp.path], duration: seg.length, progress: progress, span: span)
        }
    }

    /// trim/atrim every kept segment and concat them in one filtergraph.
    private func encodeJoined(target: FileFormat, to final: URL, progress: @escaping ProgressHandler) async throws -> URL {
        let s = spec(target)
        let audioOut = MediaEncoding.audioTargets.contains(target)
        let useVideo = !audioOut && info.hasVideo
        let aIdx = info.audioIndices.first
        let useAudio = aIdx != nil && target != .gif
        guard useVideo || useAudio else { throw PetalwheelError(l: "“%@” has no audio or video to trim.", source.lastPathComponent) }

        var graph = ""
        var inputs = ""
        for (i, seg) in segments.enumerated() {
            let a = TimelineOutput.seconds(seg.start), b = TimelineOutput.seconds(seg.end)
            if useVideo, let v = info.videoIndex {
                graph += "[0:\(v)]trim=start=\(a):end=\(b),setpts=PTS-STARTPTS[v\(i)];"
                inputs += "[v\(i)]"
            }
            if useAudio, let ai = aIdx {
                graph += "[0:\(ai)]atrim=start=\(a):end=\(b),asetpts=PTS-STARTPTS[a\(i)];"
                inputs += "[a\(i)]"
            }
        }
        graph += inputs + "concat=n=\(segments.count):v=\(useVideo ? 1 : 0):a=\(useAudio ? 1 : 0)"
        graph += useVideo && useAudio ? "[vc][ac]" : (useVideo ? "[vc]" : "[ac]")

        var args = ["-i", source.path]
        var maps: [String] = []
        var codec: [String] = []
        if useVideo {
            if target == .gif {
                graph += ";[vc]fps=\(max(1, s.gifFrameRate)),split[k0][k1];[k0]palettegen=stats_mode=diff[kp];"
                    + "[k1][kp]paletteuse=dither=sierra2_4a[vout]"
                codec += ["-loop", "0"]
            } else {
                graph += ";[vc]" + MediaEncoding.videoChain(s, info: info).joined(separator: ",") + "[vout]"
                codec += MediaEncoding.videoCodecArgs(for: target, spec: s)
            }
            maps += ["-map", "[vout]"]
        }
        if useAudio {
            maps += ["-map", "[ac]"]
            codec += MediaEncoding.audioCodecArgs(for: target, spec: s, info: info)
        }
        if !useVideo { codec += ["-vn"] }
        if !useAudio { codec += ["-an"] }
        codec += ["-sn", "-dn"]
        if target == .mp4 || target == .mov || target == .m4a { codec += ["-movflags", "+faststart"] }
        if target == .mp3 { codec += ["-id3v2_version", "3"] }
        args += ["-filter_complex", graph] + maps + codec + MediaEncoding.metadataArgs(preserve: true)
        let total = segments.reduce(0) { $0 + $1.length }
        return try await MediaOutput.produce(final) { temp in
            try await FFmpeg.run(args + [temp.path], duration: total, progress: progress)
        }
    }
}
