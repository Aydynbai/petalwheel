import Foundation

// Shared ffmpeg/ffprobe plumbing for MediaEngine and MediaToolsModule.

// MARK: - Probing

/// What ffprobe reports about a media file. Video dimensions are *display* dimensions
/// (already swapped for 90°/270° rotation, matching what ffmpeg's autorotate produces).
struct MediaInfo {
    var duration: Double = 0
    var size: Int64 = 0
    var formatName = ""

    var videoIndex: Int?            // first real video stream (not cover art)
    var videoCodec: String?
    var width = 0
    var height = 0
    var rotation = 0
    var fps: Double = 0
    var videoBitrateKbps = 0
    var pixelFormat: String?
    var colorTransfer: String?
    var audioCodecs: [String] = []

    var audioIndices: [Int] = []
    var audioCodec: String?
    var audioBits = 16              // bits per sample of the first audio stream (16 for lossy sources)
    var sampleRate = 0
    var channels = 0
    var audioBitrateKbps = 0

    var attachedPicIndex: Int?      // embedded cover art

    var hasVideo: Bool { videoIndex != nil }
    var hasAudio: Bool { !audioIndices.isEmpty }
    var isPortrait: Bool { height > width }
}

enum MediaProbe {
    static func probe(_ url: URL) async throws -> MediaInfo {
        let ffprobe = try ExternalTools.shared.require(ExternalTools.shared.ffprobe, "ffprobe")
        let out: String
        do {
            out = try await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json",
                                                        "-show_format", "-show_streams", url.path]).stdout
        } catch let e as ProcessError {
            throw PetalwheelError(l: "“%@” can’t be read as audio or video.\n%@", url.lastPathComponent, e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else {
            throw PetalwheelError(l: "“%@” can’t be read as audio or video.", url.lastPathComponent)
        }
        return parse(root)
    }

    static func parse(_ root: [String: Any]) -> MediaInfo {
        var info = MediaInfo()
        let format = root["format"] as? [String: Any] ?? [:]
        info.duration = double(format["duration"]) ?? 0
        info.size = Int64(double(format["size"]) ?? 0)
        info.formatName = format["format_name"] as? String ?? ""
        var maxStreamDuration = 0.0

        for s in root["streams"] as? [[String: Any]] ?? [] {
            let type = s["codec_type"] as? String
            let index = (s["index"] as? Int) ?? Int(double(s["index"]) ?? 0)
            let disposition = s["disposition"] as? [String: Any] ?? [:]
            if let d = double(s["duration"]) { maxStreamDuration = max(maxStreamDuration, d) }

            if type == "video" {
                if (disposition["attached_pic"] as? Int ?? 0) == 1 {
                    if info.attachedPicIndex == nil { info.attachedPicIndex = index }
                    continue
                }
                guard info.videoIndex == nil else { continue }
                info.videoIndex = index
                info.videoCodec = s["codec_name"] as? String
                info.pixelFormat = s["pix_fmt"] as? String
                info.colorTransfer = s["color_transfer"] as? String
                var w = s["width"] as? Int ?? 0, h = s["height"] as? Int ?? 0
                var rot = 0
                if let tags = s["tags"] as? [String: Any], let r = double(tags["rotate"]) { rot = Int(r) }
                for sd in s["side_data_list"] as? [[String: Any]] ?? [] {
                    if let r = double(sd["rotation"]) { rot = Int(r) }
                }
                rot = ((rot % 360) + 360) % 360
                if rot == 90 || rot == 270 { swap(&w, &h) }
                info.width = w; info.height = h; info.rotation = rot
                // Sample aspect ratio: report display width for anamorphic sources.
                if let sar = s["sample_aspect_ratio"] as? String, let r = ratio(sar), r > 0, abs(r - 1) > 0.01 {
                    if rot == 90 || rot == 270 { info.height = Int((Double(h) / r).rounded()) }
                    else { info.width = Int((Double(w) * r).rounded()) }
                }
                let fps = ratio(s["avg_frame_rate"] as? String ?? "") ?? 0
                let rfps = ratio(s["r_frame_rate"] as? String ?? "") ?? 0
                info.fps = (fps > 0 && fps < 1000) ? fps : ((rfps > 0 && rfps < 1000) ? rfps : 0)
                info.videoBitrateKbps = Int((double(s["bit_rate"]) ?? 0) / 1000)
            } else if type == "audio" {
                info.audioIndices.append(index)
                info.audioCodecs.append(s["codec_name"] as? String ?? "unknown")
                guard info.audioIndices.count == 1 else { continue }
                info.audioCodec = s["codec_name"] as? String
                info.sampleRate = Int(double(s["sample_rate"]) ?? 0)
                info.channels = s["channels"] as? Int ?? 0
                info.audioBitrateKbps = Int((double(s["bit_rate"]) ?? 0) / 1000)
                let raw = Int(double(s["bits_per_raw_sample"]) ?? 0)
                let bps = s["bits_per_sample"] as? Int ?? 0
                let codec = info.audioCodec ?? ""
                let lossless = codec.hasPrefix("pcm_") || codec == "flac" || codec == "alac" || codec == "wavpack" || codec == "ape"
                if lossless {
                    let bits = raw > 0 ? raw : bps
                    info.audioBits = bits > 0 ? bits : 16
                    if codec.hasPrefix("pcm_f") { info.audioBits = 24 }   // float PCM: keep headroom
                }
            }
        }
        if info.duration <= 0 { info.duration = maxStreamDuration }
        return info
    }

    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func ratio(_ s: String) -> Double? {
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 else { return Double(s) }
        return a / b
    }
}

// MARK: - Running ffmpeg

enum FFmpeg {
    /// Runs ffmpeg with the standard flags and reports progress against `duration` seconds,
    /// mapped into `span` of the overall 0...1 range. Returns stderr (useful with loglevel "info").
    @discardableResult
    static func run(_ args: [String], duration: Double, loglevel: String = "error", allowEncoderFallback: Bool = true,
                    progress: ProgressHandler? = nil, span: ClosedRange<Double> = 0...1) async throws -> String {
        let ffmpeg = try ExternalTools.shared.require(ExternalTools.shared.ffmpeg, "ffmpeg")
        try Task.checkCancellation()
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", loglevel,
                    "-progress", "pipe:1", "-nostats"] + args
        let total = max(duration, 0.001)
        do {
            return try await runOnce(ffmpeg, full, total: total, progress: progress, span: span)
        } catch let first as ProcessError where !Task.isCancelled {
            // A hardware (VideoToolbox) encode can fail on sizes or formats the session rejects
            // (e.g. H.264 above 4096 px), or when no encoder session is available: walk the fallback chain.
            var error = first
            for fallback in (allowEncoderFallback ? MediaEncoding.encoderFallbacks(full) : []) {
                try Task.checkCancellation()
                NSLog("Petalwheel: VideoToolbox encode failed, retrying with %@: %@",
                      MediaEncoding.videoEncoder(in: fallback) ?? "?",
                      error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                progress?(span.lowerBound)
                do {
                    return try await runOnce(ffmpeg, fallback, total: total, progress: progress, span: span)
                } catch let e as ProcessError where !Task.isCancelled {
                    error = e
                }
            }
            throw error
        }
    }

    private static func runOnce(_ ffmpeg: URL, _ full: [String], total: Double,
                                progress: ProgressHandler?, span: ClosedRange<Double>) async throws -> String {
        let width = span.upperBound - span.lowerBound
        let result: (stdout: String, stderr: String)
        do {
            result = try await ProcessRunner.run(ffmpeg, full) { line in
            guard let progress else { return }
            if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                // Both keys carry microseconds (out_time_ms is misnamed in ffmpeg).
                guard let us = Double(line.split(separator: "=", maxSplits: 1).last ?? "") else { return }
                let f = min(max(us / 1_000_000 / total, 0), 1)
                progress(span.lowerBound + width * f)
            } else if line == "progress=end" {
                progress(span.upperBound)
            }
            }
        } catch is ProcessError where Task.isCancelled {
            // ffmpeg traps SIGTERM and exits normally with 255.
            throw CancellationError()
        }
        return result.stderr
    }

    /// Encoders compiled into the installed ffmpeg (queried once).
    static let encoders: Set<String> = {
        guard let ffmpeg = ExternalTools.shared.ffmpeg else { return [] }
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var set = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 2, cols[0].count == 6 { set.insert(String(cols[1])) }
        }
        return set
    }()

    static var aacEncoder: String { encoders.contains("aac_at") ? "aac_at" : "aac" }

    /// Escapes a value for use inside an ffmpeg filtergraph option.
    static func filterNumber(_ v: Double) -> String { String(format: "%.3f", v) }
}

// MARK: - Output files

enum MediaOutput {
    /// Writes to a hidden temp file next to `final`, then renames it into place (choosing a free
    /// name at the end). The temp file is removed on failure or cancellation.
    static func produce(_ final: URL, _ body: (URL) async throws -> Void) async throws -> URL {
        let dir = final.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".petalwheel-\(UUID().uuidString.prefix(8)).partial")
            .appendingPathExtension(final.pathExtension)
        do {
            try await body(temp)
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: temp.path) else {
                throw PetalwheelError(l: "ffmpeg produced no output for “%@”.", final.lastPathComponent)
            }
            return try moveIntoPlace(temp, final)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Same as `produce` for a directory of outputs.
    static func produceDirectory(_ final: URL, _ body: (URL) async throws -> Void) async throws -> URL {
        let dir = final.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".petalwheel-\(UUID().uuidString.prefix(8)).partial")
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try await body(temp)
            try Task.checkCancellation()
            return try moveIntoPlace(temp, final)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func moveIntoPlace(_ temp: URL, _ final: URL) throws -> URL {
        let fm = FileManager.default
        for _ in 0..<20 {
            let dest = uniqueName(final)
            // Atomic rename that refuses to overwrite a file that appeared meanwhile.
            if Darwin.renamex_np(temp.path, dest.path, UInt32(RENAME_EXCL)) == 0 { return dest }
            if errno != EEXIST { break }
        }
        let dest = uniqueName(final)
        try fm.moveItem(at: temp, to: dest)
        return dest
    }

    /// Like `OutputNaming.unique`, but also correct for extension-less names (folders).
    static func uniqueName(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        // Treat only short alphanumeric suffixes as extensions ("clip.v2 snapshots" has none).
        let isExt = !ext.isEmpty && ext.count <= 5 && ext.allSatisfy { $0.isLetter || $0.isNumber }
        let dir = url.deletingLastPathComponent()
        let base = isExt ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        var i = 2
        while true {
            let name = isExt ? "\(base) \(i).\(ext)" : "\(base) \(i)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Encoding recipes

/// Describes one transcode; `MediaEncoding.outputArgs` turns it into ffmpeg output options.
struct MediaEncodeSpec {
    var target: FileFormat
    var quality: Quality = .high
    var audioKbps: Int? = nil           // override the quality preset
    var videoBitrateKbps: Int? = nil    // constrained bitrate instead of CRF/quality
    var crfOverride: Int? = nil         // x264-style CRF; mapped to VideoToolbox -q:v when hardware encoding
    var hevc = false                    // H.265 instead of H.264 for mp4/mov/mkv
    var videoFilters: [String] = []     // applied before scaling/even-size/format
    var audioFilters: [String] = []
    var copyVideo = false
    var copyAudio = false
    var dropAudio = false
    var maxHeight: Int? = nil           // limit for the short side ("1080p"), only downscales
    var preserveMetadata = true
    var keepArtwork = true
    var gifFrameRate = 15
    var gifMaxWidth = 640
    var sourceName = L("This file")
    var sourceIsGIF = false
    /// Keep a lossless source codec (e.g. ALAC in .m4a) when re-encoding into the same container.
    var preferLossless = false
}

enum MediaEncoding {
    static let videoTargets: Set<FileFormat> = [.mp4, .mov, .mkv, .webm, .avi, .wmv]
    static let audioTargets: Set<FileFormat> = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]

    static func audioKbps(for target: FileFormat, quality: Quality) -> Int {
        switch target {
        case .ogg, .opus, .webm:
            switch quality { case .compact: return 64; case .balanced: return 96; case .high: return 160 }
        default:
            switch quality { case .compact: return 128; case .balanced: return 192; case .high: return 256 }
        }
    }

    static func crf(for target: FileFormat, quality: Quality) -> Int {
        if target == .webm {
            switch quality { case .compact: return 37; case .balanced: return 33; case .high: return 31 }
        }
        switch quality { case .compact: return 26; case .balanced: return 21; case .high: return 18 }
    }

    /// Output options (maps, filters, codecs, metadata) for one input at index 0.
    static func outputArgs(_ s: MediaEncodeSpec, info: MediaInfo) throws -> [String] {
        var a: [String] = []
        let t = s.target
        if audioTargets.contains(t) {
            guard let aIdx = info.audioIndices.first else {
                throw PetalwheelError(l: "“%@” has no audio track.", s.sourceName)
            }
            a += ["-map", "0:\(aIdx)"]
            let artwork = s.keepArtwork && (t == .mp3 || t == .m4a) ? info.attachedPicIndex : nil
            if let pic = artwork {
                a += ["-map", "0:\(pic)", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
            } else {
                a += ["-vn"]
            }
            a += ["-sn", "-dn"]
            if !s.audioFilters.isEmpty { a += ["-af", s.audioFilters.joined(separator: ",")] }
            a += audioCodecArgs(for: t, spec: s, info: info)
            if t == .mp3 { a += ["-id3v2_version", "3"] }
            if t == .m4a { a += ["-movflags", "+faststart"] }
        } else if videoTargets.contains(t) {
            guard let vIdx = info.videoIndex else {
                throw PetalwheelError(l: "“%@” has no video track.", s.sourceName)
            }
            a += ["-map", "0:\(vIdx)"]
            let includeAudio = !s.dropAudio && info.hasAudio
            if includeAudio {
                let tracks = (t == .avi || t == .wmv) ? Array(info.audioIndices.prefix(1)) : info.audioIndices
                for i in tracks { a += ["-map", "0:\(i)"] }
            }
            if s.copyVideo {
                a += ["-c:v", "copy"]
            } else {
                a += ["-vf", videoChain(s, info: info).joined(separator: ",")]
                a += videoCodecArgs(for: t, spec: s)
            }
            if includeAudio {
                if !s.audioFilters.isEmpty { a += ["-af", s.audioFilters.joined(separator: ",")] }
                a += audioCodecArgs(for: t, spec: s, info: info)
            } else {
                a += ["-an"]
            }
            a += ["-sn", "-dn"]
            if t == .mp4 || t == .mov { a += ["-movflags", "+faststart"] }
        } else if t == .gif {
            guard let vIdx = info.videoIndex else { throw PetalwheelError(l: "“%@” has no video track.", s.sourceName) }
            var chain = s.videoFilters
            chain.append("fps=\(max(1, s.gifFrameRate))")
            // Limit the long side (width for landscape, height for portrait) to gifMaxWidth.
            let m = max(16, s.gifMaxWidth)
            chain.append("scale='if(gte(iw,ih),min(\(m),iw),-2)':'if(gte(iw,ih),-2,min(\(m),ih))':flags=lanczos")
            let graph = "[0:\(vIdx)]" + chain.joined(separator: ",")
                + ",split[k0][k1];[k0]palettegen=stats_mode=diff[kp];[k1][kp]paletteuse=dither=sierra2_4a[kout]"
            a += ["-filter_complex", graph, "-map", "[kout]", "-an", "-sn", "-loop", "0"]
        } else if t == .png || t == .jpg {
            guard let vIdx = info.videoIndex else { throw PetalwheelError(l: "“%@” has no video track.", s.sourceName) }
            a += ["-map", "0:\(vIdx)", "-frames:v", "1", "-update", "1"]
            if !s.videoFilters.isEmpty { a += ["-vf", s.videoFilters.joined(separator: ",")] }
            if t == .jpg { a += ["-c:v", "mjpeg", "-q:v", "2", "-pix_fmt", "yuvj444p"] } else { a += ["-c:v", "png"] }
        } else {
            throw PetalwheelError(l: "Can’t write %@ files with ffmpeg.", t.title)
        }
        a += metadataArgs(preserve: s.preserveMetadata)
        return a
    }

    static func metadataArgs(preserve: Bool) -> [String] {
        preserve ? ["-map_metadata", "0"] : ["-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact"]
    }

    /// Video filters: caller's filters, optional downscale, even dimensions, yuv420p.
    static func videoChain(_ s: MediaEncodeSpec, info: MediaInfo) -> [String] {
        var chain = s.videoFilters
        if let h = s.maxHeight, h > 0, info.width > 0, info.height > 0, s.videoFilters.isEmpty {
            let short = min(info.width, info.height)
            if h < short {
                chain.append(info.isPortrait ? "scale=\(h):-2:flags=lanczos" : "scale=-2:\(h):flags=lanczos")
            }
        }
        if s.sourceIsGIF {
            chain.append("pad=ceil(iw/2)*2:ceil(ih/2)*2")
        } else {
            chain.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        }
        chain.append("format=yuv420p")
        return chain
    }

    static func videoCodecArgs(for t: FileFormat, spec s: MediaEncodeSpec) -> [String] {
        let crf = s.crfOverride ?? crf(for: t, quality: s.quality)
        switch t {
        case .webm:
            var a = ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", "3", "-pix_fmt", "yuv420p"]
            if let br = s.videoBitrateKbps { a += ["-b:v", "\(br)k"] } else { a += ["-crf", "\(crf)", "-b:v", "0"] }
            return a
        case .avi:
            let q: Int = { switch s.quality { case .compact: return 5; case .balanced: return 4; case .high: return 3 } }()
            var a = ["-c:v", "mpeg4", "-tag:v", "XVID", "-pix_fmt", "yuv420p"]
            if let br = s.videoBitrateKbps { a += ["-b:v", "\(br)k"] } else { a += ["-q:v", "\(q)"] }
            return a
        case .wmv:
            let q: Int = { switch s.quality { case .compact: return 8; case .balanced: return 5; case .high: return 4 } }()
            var a = ["-c:v", "wmv2", "-pix_fmt", "yuv420p"]
            if let br = s.videoBitrateKbps { a += ["-b:v", "\(br)k"] } else { a += ["-q:v", "\(q)"] }
            return a
        default: // mp4, mov, mkv
            let tagged = t == .mp4 || t == .mov
            let hevc = s.hevc && (usesHardwareVideo(hevc: true) || FFmpeg.encoders.contains("libx265"))
            var a: [String]
            if usesHardwareVideo(hevc: hevc) {
                // VideoToolbox (Apple Silicon media engine). -allow_sw lets VT use Apple's software
                // encoder when no hardware session is free; FFmpeg.run falls back to libx264/mpeg4 if
                // the VT session can't be created at all.
                a = ["-c:v", hevc ? "hevc_videotoolbox" : "h264_videotoolbox", "-allow_sw", "1",
                     "-profile:v", hevc ? "main" : "high", "-pix_fmt", "yuv420p",
                     "-g", "\(keyframeInterval)", "-bf", "2"]
                if let br = s.videoBitrateKbps {
                    a += bitrateArgs(br)
                } else {
                    a += ["-q:v", "\(vtQuality(crf: crf, hevc: hevc))"]
                }
            } else {
                a = ["-c:v", hevc ? "libx265" : "libx264", "-preset", "medium", "-pix_fmt", "yuv420p"]
                if let br = s.videoBitrateKbps { a += bitrateArgs(br) } else { a += ["-crf", "\(crf)"] }
                if hevc { a += ["-x265-params", "log-level=error"] }
            }
            if tagged { a += ["-tag:v", hevc ? "hvc1" : "avc1"] }
            return a
        }
    }

    // MARK: Hardware (VideoToolbox) H.264 / HEVC

    /// libx264's default keyint; VideoToolbox would otherwise insert a keyframe every 12 frames.
    static let keyframeInterval = 250

    /// Set PETALWHEEL_SOFTWARE_VIDEO=1 to force libx264/libx265 (debugging, benchmarks).
    static let forceSoftwareVideo = ProcessInfo.processInfo.environment["PETALWHEEL_SOFTWARE_VIDEO"] == "1"

    static func usesHardwareVideo(hevc: Bool) -> Bool {
        guard !forceSoftwareVideo || !FFmpeg.encoders.contains(hevc ? "libx265" : "libx264") else { return false }
        return FFmpeg.encoders.contains(hevc ? "hevc_videotoolbox" : "h264_videotoolbox")
    }

    /// True when a two-pass encode is possible for `target` (VideoToolbox is single-pass only).
    static func supportsTwoPass(_ target: FileFormat, spec: MediaEncodeSpec) -> Bool {
        switch target {
        case .mp4, .mov, .mkv: return !usesHardwareVideo(hevc: spec.hevc)
        default: return true
        }
    }

    /// Constrained average bitrate (target-size compression).
    static func bitrateArgs(_ kbps: Int) -> [String] {
        ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k"]
    }

    /// Maps an x264-style CRF to VideoToolbox constant quality (-q:v 1–100, Apple Silicon), calibrated by
    /// VMAF against libx264 -preset medium on a 45 s 1080p30 clip: same VMAF within ~1 point; VT files come
    /// out ~0–40% larger at equal quality (largest gap at the compact end). Anchors: `vtQualityAnchors`.
    static func vtQuality(crf: Int, hevc: Bool) -> Int {
        let anchors: [(crf: Double, q: Double)] = vtQualityAnchors
        let c = Double(crf)
        var q: Double
        if c <= anchors.first!.crf {
            q = anchors.first!.q + (anchors.first!.crf - c) * 2
        } else if c >= anchors.last!.crf {
            q = anchors.last!.q - (c - anchors.last!.crf) * 2
        } else {
            let hi = anchors.firstIndex { $0.crf >= c }!
            let a = anchors[hi - 1], b = anchors[hi]
            q = a.q + (c - a.crf) / (b.crf - a.crf) * (b.q - a.q)
        }
        // VT HEVC scores lower than VT H.264 at the same q (q64 ≈ VMAF 89.4 vs H.264 q62 ≈ 91.1);
        // +5 keeps the H.264 look at roughly 15–25% smaller files.
        if hevc { q += 5 }
        return Int(min(max(q.rounded(), 1), 100))
    }

    /// (CRF, VideoToolbox q) pairs, ascending CRF.
    static let vtQualityAnchors: [(crf: Double, q: Double)] = [(18, 77), (21, 73), (23, 68), (26, 62), (28, 57), (32, 48)]

    /// Inverse of `vtQuality` (used by the software fallback).
    static func crf(fromVTQuality q: Int) -> Int {
        (10...45).min { abs(vtQuality(crf: $0, hevc: false) - q) < abs(vtQuality(crf: $1, hevc: false) - q) } ?? 23
    }

    static let vtEncoders: Set<String> = ["h264_videotoolbox", "hevc_videotoolbox"]

    /// The video encoder named by `-c:v`/`-vcodec` in an argument list.
    static func videoEncoder(in args: [String]) -> String? {
        guard let i = args.firstIndex(where: { $0.hasPrefix("-c:v") || $0 == "-vcodec" }), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Alternatives to try, in order, when an ffmpeg run using a VideoToolbox encoder fails:
    /// VT H.264 → VT HEVC (handles up to 8K on Apple Silicon, where VT H.264 stops at 4096 px) →
    /// libx264/libx265 when compiled in (Homebrew GPL build) → the LGPL mpeg4 encoder.
    /// Empty when the arguments contain no VideoToolbox encoder.
    static func encoderFallbacks(_ args: [String]) -> [[String]] {
        guard let current = videoEncoder(in: args), vtEncoders.contains(current) else { return [] }
        var chain: [String] = []
        if current == "h264_videotoolbox", FFmpeg.encoders.contains("hevc_videotoolbox") { chain.append("hevc_videotoolbox") }
        if current == "hevc_videotoolbox", FFmpeg.encoders.contains("libx265") { chain.append("libx265") }
        if FFmpeg.encoders.contains("libx264") { chain.append("libx264") }
        chain.append("mpeg4")
        return chain.map { rewrite(args, to: $0) }
    }

    /// Rewrites a full ffmpeg argument list that uses a VideoToolbox encoder to use `encoder` instead,
    /// translating the quality options (VT -q:v ↔ x264 CRF ↔ mpeg4 qscale) and the mp4/mov codec tag.
    static func rewrite(_ args: [String], to encoder: String) -> [String] {
        let toVT = vtEncoders.contains(encoder)
        // Options only VideoToolbox understands.
        let vtOnly: Set<String> = ["-allow_sw", "-realtime", "-prio_speed", "-spatial_aq", "-constant_bit_rate",
                                   "-require_sw", "-power_efficient", "-max_ref_frames"]
        var out: [String] = []
        var inVideo = false, i = 0
        while i < args.count {
            let a = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            if a.hasPrefix("-c:v") || a == "-vcodec", let n = next, vtEncoders.contains(n) {
                inVideo = true
                out += [a, encoder]
                if encoder == "libx264" || encoder == "libx265" { out += ["-preset", "medium"] }
                i += 2; continue
            }
            guard inVideo, let n = next else { out.append(a); i += 1; continue }
            switch a {
            case _ where vtOnly.contains(a) && !toVT:
                break
            case "-q:v":
                let q = Int(n) ?? 60
                switch encoder {
                case "hevc_videotoolbox": out += ["-q:v", "\(min(q + 5, 100))"]
                case "mpeg4": out += ["-q:v", q >= 65 ? "3" : q >= 55 ? "4" : "5"]
                case "h264_videotoolbox": out += [a, n]
                default: out += ["-crf", "\(crf(fromVTQuality: q))"]
                }
            case "-profile:v":
                switch encoder {
                case "hevc_videotoolbox", "libx265": out += [a, "main"]
                case "h264_videotoolbox", "libx264": out += [a, "high"]
                default: break
                }
            case "-tag:v" where n == "hvc1" || n == "avc1":
                out += [a, encoder.contains("hevc") || encoder == "libx265" ? "hvc1" : encoder == "mpeg4" ? "mp4v" : "avc1"]
            default:
                out.append(a); i += 1; continue
            }
            i += 2
        }
        if encoder == "libx265", !out.contains("-x265-params") {
            if let o = out.firstIndex(of: "libx265") { out.insert(contentsOf: ["-x265-params", "log-level=error"], at: o + 1) }
        }
        return out
    }

    static func audioCodecArgs(for t: FileFormat, spec s: MediaEncodeSpec, info: MediaInfo) -> [String] {
        if s.copyAudio { return ["-c:a", "copy"] }
        let kbps = s.audioKbps ?? audioKbps(for: t, quality: s.quality)
        let hiRes = info.audioBits > 16
        let stereoCap = info.channels > 2 ? ["-ac", "2"] : []
        // Lossy encoders top out at 48 kHz.
        let rateCap = info.sampleRate > 48000 ? ["-ar", "48000"] : []
        switch t {
        case .mp3, .avi:
            return ["-c:a", "libmp3lame", "-b:a", "\(min(kbps, 320))k"] + stereoCap + rateCap
        case .m4a where s.preferLossless && info.audioCodec == "alac":
            return ["-c:a", "alac"]
        case .m4a, .mp4, .mov, .mkv:
            return ["-c:a", FFmpeg.aacEncoder, "-b:a", "\(min(kbps, 320))k"] + rateCap
        case .wav:
            return ["-c:a", hiRes ? "pcm_s24le" : "pcm_s16le"]
        case .aiff:
            return ["-c:a", hiRes ? "pcm_s24be" : "pcm_s16be"]
        case .flac:
            return ["-c:a", "flac", "-compression_level", "8", "-sample_fmt", hiRes ? "s32" : "s16"]
                + (hiRes ? ["-bits_per_raw_sample", "24"] : [])
        case .ogg, .opus, .webm:
            return ["-c:a", "libopus", "-b:a", "\(min(kbps, 256))k", "-vbr", "on"]
        case .wma, .wmv:
            return ["-c:a", "wmav2", "-b:a", "\(min(kbps, 192))k"] + stereoCap + rateCap
        default:
            return []
        }
    }
}
