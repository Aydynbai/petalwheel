import Foundation

/// Audio / video tools built on ffmpeg.
struct MediaToolsModule: ToolModule {
    private static let handled: Set<FileTool> = [
        .compress, .removeMetadata, .trimMedia, .muteVideo, .changeVideoSpeed, .cropVideo, .joinVideos,
        .videoSnapshots, .splitVideo, .normalizeAudio, .audioChannels, .trimSilence, .audioToVideo,
    ]

    func canRun(_ tool: FileTool, format: FileFormat?) -> Bool {
        guard let format, Self.handled.contains(tool),
              format.group == .audio || format.group == .video else { return false }
        return tool.accepts(format)
    }

    func run(_ tool: FileTool, inputs: [URL], options: ToolOptions,
             progress: @escaping ProgressHandler) async throws -> ToolResult {
        guard !inputs.isEmpty else { throw KumquatError(l: "No files to process.") }
        if tool == .joinVideos {
            return try await joinVideos(inputs, options: options, progress: progress)
        }
        var result = ToolResult()
        for url in inputs {
            try Task.checkCancellation()
            progress(0)
            let r = try await runOne(tool, url, options: options, progress: progress)
            result.outputs += r.outputs
            result.messages += r.messages
            progress(1)
        }
        return result
    }

    // MARK: - Dispatch

    private func runOne(_ tool: FileTool, _ url: URL, options: ToolOptions,
                        progress: @escaping ProgressHandler) async throws -> ToolResult {
        let info = try await MediaProbe.probe(url)
        let job = Job(url: url, info: info)
        switch tool {
        case .compress: return try await compress(job, options: options, progress: progress)
        case .removeMetadata: return try await removeMetadata(job, progress: progress)
        case .trimMedia: return try await trim(job, options: options, progress: progress)
        case .muteVideo: return try await mute(job, progress: progress)
        case .changeVideoSpeed: return try await changeSpeed(job, options: options, progress: progress)
        case .cropVideo: return try await crop(job, options: options, progress: progress)
        case .videoSnapshots: return try await snapshots(job, options: options, progress: progress)
        case .splitVideo: return try await split(job, options: options, progress: progress)
        case .normalizeAudio: return try await normalize(job, options: options, progress: progress)
        case .audioChannels: return try await channels(job, options: options, progress: progress)
        case .trimSilence: return try await trimSilence(job, options: options, progress: progress)
        case .audioToVideo: return try await visualize(job, progress: progress)
        default: throw KumquatError(l: "%@ isn’t available for “%@”.", tool.title, url.lastPathComponent)
        }
    }

    /// One input file plus helpers for "same format out" naming.
    private struct Job {
        let url: URL
        let info: MediaInfo
        var name: String { url.lastPathComponent }
        var base: String { url.deletingPathExtension().lastPathComponent }
        var dir: URL { url.deletingLastPathComponent() }

        /// Format to re-encode into when the tool keeps the source format.
        var sameFormat: FileFormat {
            if let f = FileFormat.detect(url),
               MediaEncoding.audioTargets.contains(f) || MediaEncoding.videoTargets.contains(f) || f == .gif {
                return f
            }
            return info.hasVideo ? .mp4 : .m4a
        }

        /// Extension for an output in `target` (keeps e.g. ".m4v" / ".aif" spellings of the same format).
        func ext(for target: FileFormat) -> String {
            FileFormat.detect(url) == target && !url.pathExtension.isEmpty ? url.pathExtension : target.fileExtension
        }

        func output(_ target: FileFormat, suffix: String) -> URL {
            OutputNaming.url(for: url, ext: ext(for: target), suffix: suffix)
        }

        func spec(_ target: FileFormat) -> MediaEncodeSpec {
            var s = MediaEncodeSpec(target: target)
            s.sourceName = name
            s.sourceIsGIF = FileFormat.detect(url) == .gif
            s.preferLossless = true
            return s
        }

        func requireAudio() throws {
            guard info.hasAudio else { throw KumquatError(l: "“%@” has no audio track.", name) }
        }

        func requireVideo() throws {
            guard info.hasVideo else { throw KumquatError(l: "“%@” has no video track.", name) }
        }
    }

    /// Single-input encode: `[inputOptions] -i src [output args] temp`.
    private func encode(_ job: Job, spec: MediaEncodeSpec, to final: URL, inputOptions: [String] = [],
                        extraOutput: [String] = [], duration: Double,
                        progress: @escaping ProgressHandler, span: ClosedRange<Double> = 0...1) async throws -> URL {
        let args = try MediaEncoding.outputArgs(spec, info: job.info)
        return try await MediaOutput.produce(final) { temp in
            try await FFmpeg.run(inputOptions + ["-i", job.url.path] + args + extraOutput + [temp.path],
                                 duration: duration, progress: progress, span: span)
        }
    }

    private static func seconds(_ v: Double) -> String { String(format: "%.3f", v) }

    // MARK: - Compress

    private func compress(_ job: Job, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        let info = job.info
        let source = FileFormat.detect(job.url)
        let inputSize = MediaOutput.fileSize(job.url)
        let out: URL

        if source?.group == .video {
            try job.requireVideo()
            if source == .gif {
                var spec = job.spec(.gif)
                switch options.quality {
                case .compact: spec.gifFrameRate = 8; spec.gifMaxWidth = 320
                case .balanced: spec.gifFrameRate = 10; spec.gifMaxWidth = 480
                case .high: spec.gifFrameRate = 12; spec.gifMaxWidth = 640
                }
                if info.fps > 0 { spec.gifFrameRate = min(spec.gifFrameRate, Int(info.fps.rounded())) }
                out = try await encode(job, spec: spec, to: job.output(.gif, suffix: "compressed"),
                                       duration: info.duration, progress: progress)
            } else {
                let target: FileFormat = [.mp4, .mov, .mkv, .webm].contains(source ?? .mp4) ? (source ?? .mp4) : .mp4
                var spec = job.spec(target)
                spec.preferLossless = false
                spec.quality = options.quality
                let webm = target == .webm
                switch options.quality {
                case .compact: spec.crfOverride = webm ? 45 : 32; spec.maxHeight = 1080; spec.audioKbps = webm ? 64 : 96
                case .balanced: spec.crfOverride = webm ? 40 : 28; spec.audioKbps = webm ? 80 : 128
                case .high: spec.crfOverride = webm ? 36 : 23; spec.audioKbps = webm ? 96 : 128
                }
                let final = job.output(target, suffix: "compressed")
                if let kb = options.targetSizeKB, kb > 0, info.duration > 0 {
                    out = try await compressToSize(job, spec: spec, targetKB: kb, final: final, progress: progress)
                } else {
                    out = try await encode(job, spec: spec, to: final, duration: info.duration, progress: progress)
                }
            }
        } else {
            try job.requireAudio()
            let keep: Set<FileFormat> = [.mp3, .m4a, .ogg, .opus, .wma]
            let target = source.map { keep.contains($0) ? $0 : .m4a } ?? .m4a
            var spec = job.spec(target)
            spec.preferLossless = false
            spec.keepArtwork = true
            let opus = target == .ogg || target == .opus
            var kbps: Int
            switch options.quality {
            case .compact: kbps = opus ? 48 : 64
            case .balanced: kbps = opus ? 64 : 96
            case .high: kbps = opus ? 96 : 128
            }
            if let kb = options.targetSizeKB, kb > 0, info.duration > 0 {
                kbps = Int(Double(kb) * 8.192 / info.duration * 0.97)
                guard kbps >= 24 else {
                    let minKB = Int((24 * info.duration / 8.192 / 0.97).rounded(.up))
                    throw KumquatError(l: "%d KB is too small for “%@”. Try at least %d KB.", kb, job.name, minKB)
                }
            } else if info.audioBitrateKbps > 0, keep.contains(source ?? .wav) {
                kbps = min(kbps, max(24, info.audioBitrateKbps * 3 / 4))
            }
            spec.audioKbps = min(kbps, 320)
            out = try await encode(job, spec: spec, to: job.output(target, suffix: "compressed"),
                                   duration: info.duration, progress: progress)
        }

        var result = ToolResult()
        let outSize = MediaOutput.fileSize(out)
        if inputSize > 0, outSize >= inputSize {
            try? FileManager.default.removeItem(at: out)
            result.messages.append("“\(job.name)” is already well compressed — the result wasn’t smaller, so it was discarded.")
            return result
        }
        result.outputs = [out]
        if let kb = options.targetSizeKB, kb > 0, Double(outSize) > Double(kb) * 1024 * 1.1 {
            result.messages.append("“\(out.lastPathComponent)” is \(outSize / 1024) KB — the closest possible to \(kb) KB.")
        }
        return result
    }

    /// Two-pass bitrate-targeted encode.
    private func compressToSize(_ job: Job, spec base: MediaEncodeSpec, targetKB: Int, final: URL,
                                progress: @escaping ProgressHandler) async throws -> URL {
        let info = job.info
        let totalKbps = Double(targetKB) * 8.192 / info.duration * 0.96
        var audioKbps = 0
        if info.hasAudio {
            audioKbps = totalKbps > 1200 ? 128 : totalKbps > 500 ? 96 : totalKbps > 200 ? 64 : 32
        }
        let videoKbps = Int(totalKbps) - audioKbps
        guard videoKbps >= 40 else {
            let minKB = Int((Double(40 + audioKbps) * info.duration / 8.192 / 0.96).rounded(.up))
            throw KumquatError(l: "%d KB is too small for the %d-second video “%@”. Try at least %d KB.", targetKB, Int(info.duration.rounded()), job.name, minKB)
        }
        var spec = base
        spec.crfOverride = nil
        spec.videoBitrateKbps = videoKbps
        spec.audioKbps = max(audioKbps, 32)
        let short = videoKbps < 400 ? 360 : videoKbps < 900 ? 480 : videoKbps < 1800 ? 720 : videoKbps < 4000 ? 1080 : nil
        if let short { spec.maxHeight = min(spec.maxHeight ?? short, short) }

        if !MediaEncoding.supportsTwoPass(spec.target, spec: spec) {
            // VideoToolbox: single-pass constrained bitrate. If its rate control overshoots the target,
            // re-encode once at a proportionally lower video bitrate.
            let out = try await encode(job, spec: spec, to: final, duration: info.duration, progress: progress, span: 0...0.7)
            let size = Double(MediaOutput.fileSize(out))
            let target = Double(targetKB) * 1024
            guard size > target * 1.03 else { return out }
            let audioBytes = Double(info.hasAudio ? spec.audioKbps ?? 0 : 0) * 1000 / 8 * info.duration
            let scale = (target * 0.97 - audioBytes) / max(size - audioBytes, 1)
            spec.videoBitrateKbps = max(40, Int(Double(videoKbps) * scale))
            try? FileManager.default.removeItem(at: out)
            return try await encode(job, spec: spec, to: final, duration: info.duration, progress: progress, span: 0.7...1)
        }

        let logDir = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = logDir.appendingPathComponent("pass").path

        var pass1Spec = spec
        pass1Spec.dropAudio = true
        var pass1 = try MediaEncoding.outputArgs(pass1Spec, info: info)
        if let i = pass1.firstIndex(of: "-movflags") { pass1.removeSubrange(i...(i + 1)) }
        try await FFmpeg.run(["-i", job.url.path] + pass1 + ["-pass", "1", "-passlogfile", log, "-f", "null", "/dev/null"],
                             duration: info.duration, progress: progress, span: 0...0.45)
        return try await encode(job, spec: spec, to: final, extraOutput: ["-pass", "2", "-passlogfile", log],
                                duration: info.duration, progress: progress, span: 0.45...1)
    }

    // MARK: - Metadata

    private func removeMetadata(_ job: Job, progress: @escaping ProgressHandler) async throws -> ToolResult {
        let info = job.info
        var args = ["-i", job.url.path]
        if let v = info.videoIndex { args += ["-map", "0:\(v)"] }
        for a in info.audioIndices { args += ["-map", "0:\(a)"] }
        guard info.hasVideo || info.hasAudio else { throw KumquatError(l: "“%@” has no audio or video.", job.name) }
        let fmt = FileFormat.detect(job.url)
        if fmt == .mkv || fmt == .mp4 || fmt == .mov { args += ["-map", "0:s?"] }
        args += ["-c", "copy", "-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact"]
        if info.hasVideo { args += ["-flags:v", "+bitexact"] }
        if info.hasAudio { args += ["-flags:a", "+bitexact"] }
        if fmt == .mp4 || fmt == .mov { args += ["-movflags", "+faststart"] }
        let final = OutputNaming.url(for: job.url, ext: job.url.pathExtension.isEmpty ? "mp4" : job.url.pathExtension,
                                     suffix: "clean")
        let out = try await MediaOutput.produce(final) { temp in
            try await FFmpeg.run(args + [temp.path], duration: info.duration, progress: progress)
        }
        return ToolResult(outputs: [out])
    }

    // MARK: - Trim / split

    private func trim(_ job: Job, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        let d = job.info.duration
        let start = max(0, options.trimStart)
        let end = min(options.trimEnd ?? d, d > 0 ? d : .greatestFiniteMagnitude)
        guard end - start > 0.05 else {
            throw KumquatError(l: "The trim range is empty for “%@” (%@s – %@s).", job.name, Self.seconds(start), Self.seconds(end))
        }
        let target = job.sameFormat
        var spec = job.spec(target)
        spec.quality = .high
        if target == .gif, job.info.fps > 0 { spec.gifFrameRate = Int(job.info.fps.rounded()); spec.gifMaxWidth = max(job.info.width, 16) }
        let out = try await encode(job, spec: spec, to: job.output(target, suffix: "trimmed"),
                                   inputOptions: ["-ss", Self.seconds(start), "-t", Self.seconds(end - start)],
                                   duration: end - start, progress: progress)
        return ToolResult(outputs: [out])
    }

    private func split(_ job: Job, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        try job.requireVideo()
        let d = job.info.duration
        let parts = min(max(options.splitParts, 2), 100)
        guard d > Double(parts) * 0.2 else { throw KumquatError(l: "“%@” is too short to split into %d parts.", job.name, parts) }
        let len = d / Double(parts)
        let target = job.sameFormat
        var spec = job.spec(target)
        spec.quality = .high
        var outputs: [URL] = []
        do {
            for i in 0..<parts {
                try Task.checkCancellation()
                let start = Double(i) * len
                let final = OutputNaming.url(named: "\(job.base) part \(i + 1)", ext: job.ext(for: target), in: job.dir)
                let span = (Double(i) / Double(parts))...(Double(i + 1) / Double(parts))
                let input = ["-ss", Self.seconds(start)] + (i == parts - 1 ? [] : ["-t", Self.seconds(len)])
                outputs.append(try await encode(job, spec: spec, to: final, inputOptions: input,
                                                duration: len, progress: progress, span: span))
            }
        } catch {
            outputs.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        return ToolResult(outputs: outputs)
    }

    // MARK: - Video edits

    private func mute(_ job: Job, progress: @escaping ProgressHandler) async throws -> ToolResult {
        try job.requireVideo()
        let target = job.sameFormat
        var spec = job.spec(target)
        spec.copyVideo = true
        spec.dropAudio = true
        let out = try await encode(job, spec: spec, to: job.output(target, suffix: "muted"),
                                   duration: job.info.duration, progress: progress)
        return ToolResult(outputs: [out])
    }

    private func changeSpeed(_ job: Job, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        try job.requireVideo()
        let speed = min(max(options.speed, 0.25), 4)
        guard abs(speed - 1) > 0.001 else { throw KumquatError(l: "Choose a speed other than 1×.") }
        let target = job.sameFormat
        var spec = job.spec(target)
        spec.quality = .high
        spec.videoFilters = ["setpts=PTS/\(FFmpeg.filterNumber(speed))"]
        let fps = job.info.fps > 0 ? job.info.fps : 30
        if fps * speed > 60 { spec.videoFilters.append("fps=\(FFmpeg.filterNumber(min(fps, 60)))") }
        spec.audioFilters = Self.atempoChain(speed)
        let label = speed == speed.rounded() ? "\(Int(speed))x" : "\(String(format: "%g", speed))x"
        let out = try await encode(job, spec: spec, to: job.output(target, suffix: label),
                                   duration: job.info.duration / speed, progress: progress)
        return ToolResult(outputs: [out])
    }

    static func atempoChain(_ speed: Double) -> [String] {
        var r = speed, chain: [String] = []
        while r > 2.0 { chain.append("atempo=2.0"); r /= 2 }
        while r < 0.5 { chain.append("atempo=0.5"); r /= 0.5 }
        if abs(r - 1) > 0.0001 { chain.append("atempo=\(FFmpeg.filterNumber(r))") }
        return chain
    }

    private func crop(_ job: Job, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        try job.requireVideo()
        let a = FFmpeg.filterNumber(options.aspect.value)
        let target = job.sameFormat
        var spec = job.spec(target)
        spec.quality = .high
        spec.copyAudio = true
        spec.videoFilters = [
            "crop='if(gt(iw/ih,\(a)),trunc(ih*\(a)/2)*2,trunc(iw/2)*2)':'if(gt(iw/ih,\(a)),trunc(ih/2)*2,trunc(iw/\(a)/2)*2)'",
            "setsar=1",
        ]
        let out = try await encode(job, spec: spec, to: job.output(target, suffix: "cropped"),
                                   duration: job.info.duration, progress: progress)
        return ToolResult(outputs: [out])
    }

    private func snapshots(_ job: Job, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        try job.requireVideo()
        let count = min(max(options.snapshotCount, 1), 200)
        let d = job.info.duration
        let digits = String(count).count
        let folder = job.dir.appendingPathComponent("\(job.base) snapshots")
        let out = try await MediaOutput.produceDirectory(folder) { temp in
            for k in 0..<count {
                try Task.checkCancellation()
                let t = d > 0 ? d * (Double(k) + 0.5) / Double(count) : 0
                let file = temp.appendingPathComponent("\(job.base) \(String(format: "%0\(digits)d", k + 1)).png")
                let v = job.info.videoIndex ?? 0
                try await FFmpeg.run(["-ss", Self.seconds(t), "-i", job.url.path, "-map", "0:\(v)",
                                      "-frames:v", "1", "-update", "1", "-c:v", "png", file.path],
                                     duration: 0.001)
                if !FileManager.default.fileExists(atPath: file.path) {
                    // Seeking right at the end can yield no frame; fall back to a slightly earlier point.
                    try await FFmpeg.run(["-ss", Self.seconds(max(0, t - 1)), "-i", job.url.path, "-map", "0:\(v)",
                                          "-frames:v", "1", "-update", "1", "-c:v", "png", file.path],
                                         duration: 0.001)
                }
                progress(Double(k + 1) / Double(count))
            }
        }
        return ToolResult(outputs: [out])
    }

    // MARK: - Join

    private func joinVideos(_ inputs: [URL], options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        guard inputs.count >= 2 else { throw KumquatError(l: "Choose at least two videos to join.") }
        var infos: [MediaInfo] = []
        for url in inputs {
            let info = try await MediaProbe.probe(url)
            guard info.hasVideo else { throw KumquatError(l: "“%@” has no video track.", url.lastPathComponent) }
            infos.append(info)
        }
        let first = infos[0]
        let w = max(2, first.width / 2 * 2), h = max(2, first.height / 2 * 2)
        let fps = FFmpeg.filterNumber(first.fps > 0 ? min(first.fps, 60) : 30)
        let anyAudio = infos.contains { $0.hasAudio }

        var args: [String] = []
        for url in inputs { args += ["-i", url.path] }
        var silenceInput: [Int: Int] = [:]
        var nextInput = inputs.count
        if anyAudio {
            for (i, info) in infos.enumerated() where !info.hasAudio {
                args += ["-f", "lavfi", "-t", Self.seconds(max(info.duration, 0.1)), "-i", "anullsrc=r=48000:cl=stereo"]
                silenceInput[i] = nextInput
                nextInput += 1
            }
        }
        var graph: [String] = []
        var concatInputs = ""
        for (i, info) in infos.enumerated() {
            graph.append("[\(i):\(info.videoIndex!)]scale=\(w):\(h):force_original_aspect_ratio=decrease:flags=lanczos,"
                         + "pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps),format=yuv420p[v\(i)]")
            concatInputs += "[v\(i)]"
            if anyAudio {
                let src = info.audioIndices.first.map { "[\(i):\($0)]" } ?? "[\(silenceInput[i]!):a]"
                graph.append("\(src)aresample=48000,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[a\(i)]")
                concatInputs += "[a\(i)]"
            }
        }
        graph.append("\(concatInputs)concat=n=\(inputs.count):v=1:a=\(anyAudio ? 1 : 0)[vout]\(anyAudio ? "[aout]" : "")")
        args += ["-filter_complex", graph.joined(separator: ";"), "-map", "[vout]"]
        if anyAudio { args += ["-map", "[aout]"] }
        var spec = MediaEncodeSpec(target: .mp4)
        spec.quality = options.quality
        args += MediaEncoding.videoCodecArgs(for: .mp4, spec: spec)
        if anyAudio { args += ["-c:a", FFmpeg.aacEncoder, "-b:a", "192k"] }
        args += ["-map_metadata", "-1", "-movflags", "+faststart"]

        let total = infos.reduce(0) { $0 + $1.duration }
        let final = inputs[0].deletingLastPathComponent().appendingPathComponent("Joined.mp4")
        let out = try await MediaOutput.produce(final) { temp in
            try await FFmpeg.run(args + [temp.path], duration: total, progress: progress)
        }
        progress(1)
        return ToolResult(outputs: [out])
    }

    // MARK: - Audio tools

    /// Spec that rewrites only the audio, copying any video stream.
    private func audioEditSpec(_ job: Job) -> MediaEncodeSpec {
        var spec = job.spec(job.sameFormat)
        spec.quality = .high
        if job.info.hasVideo { spec.copyVideo = true }
        return spec
    }

    private func normalize(_ job: Job, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        try job.requireAudio()
        let info = job.info
        let target = String(format: "%.1f", min(max(options.loudnessLUFS, -70), -5))
        let base = "loudnorm=I=\(target):TP=-1.5:LRA=11"
        let rate = info.sampleRate > 0 ? info.sampleRate : 48000

        // Pass 1: measure.
        let stderr = try await FFmpeg.run(["-i", job.url.path, "-map", "0:\(info.audioIndices[0])", "-vn", "-sn",
                                           "-af", base + ":print_format=json", "-f", "null", "-"],
                                          duration: info.duration, loglevel: "info", progress: progress, span: 0...0.4)
        var filter = base
        if let m = Self.loudnormMeasurement(stderr) {
            filter += ":measured_I=\(m["input_i"]!):measured_TP=\(m["input_tp"]!):measured_LRA=\(m["input_lra"]!)"
                + ":measured_thresh=\(m["input_thresh"]!):offset=\(m["target_offset"]!):linear=true"
        }
        var spec = audioEditSpec(job)
        spec.audioFilters = [filter + ":print_format=none", "aresample=\(rate)"]
        let out = try await encode(job, spec: spec, to: job.output(job.sameFormat, suffix: "normalized"),
                                   duration: info.duration, progress: progress, span: 0.4...1)
        return ToolResult(outputs: [out])
    }

    /// Parses loudnorm's JSON summary; nil when missing or the input is silent (-inf).
    static func loudnormMeasurement(_ stderr: String) -> [String: String]? {
        guard let open = stderr.range(of: "{", options: .backwards),
              let close = stderr.range(of: "}", options: .backwards), open.lowerBound < close.lowerBound,
              let obj = try? JSONSerialization.jsonObject(with: Data(stderr[open.lowerBound...close.lowerBound].utf8)) as? [String: Any]
        else { return nil }
        var m: [String: String] = [:]
        for key in ["input_i", "input_tp", "input_lra", "input_thresh", "target_offset"] {
            guard let v = obj[key] as? String, let d = Double(v), d.isFinite else { return nil }
            m[key] = v
        }
        return m
    }

    private func channels(_ job: Job, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        try job.requireAudio()
        let spec = audioEditSpec(job)
        let out = try await encode(job, spec: spec, to: job.output(job.sameFormat, suffix: options.mono ? "mono" : "stereo"),
                                   extraOutput: ["-ac", options.mono ? "1" : "2"],
                                   duration: job.info.duration, progress: progress)
        return ToolResult(outputs: [out])
    }

    private func trimSilence(_ job: Job, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> ToolResult {
        try job.requireAudio()
        let info = job.info
        let db = String(format: "%.1f", min(max(options.silenceThresholdDB, -90), -10))

        // Find leading/trailing silence first (silenceremove alone can't cut the tail cleanly).
        let stderr = try await FFmpeg.run(["-i", job.url.path, "-map", "0:\(info.audioIndices[0])", "-vn", "-sn",
                                           "-af", "silencedetect=noise=\(db)dB:d=0.3", "-f", "null", "-"],
                                          duration: info.duration, loglevel: "info", progress: progress, span: 0...0.3)
        let silences = Self.parseSilences(stderr, duration: info.duration)
        var start = 0.0, end = info.duration
        if let firstSilence = silences.first, firstSilence.start <= 0.05 {
            start = max(0, firstSilence.end - 0.1)
        }
        if let last = silences.last, last.end >= info.duration - 0.05, last.start > start {
            end = min(info.duration, last.start + 0.15)
        }
        if let only = silences.first, silences.count == 1, only.start <= 0.05, only.end >= info.duration - 0.05 {
            throw KumquatError(l: "“%@” is silent below %@ dB — nothing would be left.", job.name, db)
        }
        let target = job.sameFormat
        var spec = job.spec(target)
        spec.quality = .high
        if !info.hasVideo {
            // Audio only: also shorten long pauses inside the recording to 0.5 s.
            let longPauses = silences.contains { $0.start > start + 0.05 && $0.end < end - 0.05 && $0.end - $0.start > 0.6 }
            guard start > 0.01 || end < info.duration - 0.01 || longPauses else {
                return ToolResult(messages: [L("No silence to cut in “%@”.", job.name)])
            }
            spec.audioFilters = ["silenceremove=start_periods=1:start_threshold=\(db)dB:start_silence=0.1"
                                 + ":stop_periods=-1:stop_threshold=\(db)dB:stop_duration=0.5"]
            let out = try await encode(job, spec: spec, to: job.output(target, suffix: "trimmed"),
                                       inputOptions: ["-t", Self.seconds(end)],
                                       duration: end, progress: progress, span: 0.3...1)
            return ToolResult(outputs: [out])
        }
        guard start > 0.01 || end < info.duration - 0.01 else {
            return ToolResult(messages: [L("No silence at the start or end of “%@”.", job.name)])
        }
        guard end - start > 0.1 else {
            throw KumquatError(l: "“%@” is silent below %@ dB — nothing would be left.", job.name, db)
        }
        let out = try await encode(job, spec: spec, to: job.output(target, suffix: "trimmed"),
                                   inputOptions: ["-ss", Self.seconds(start), "-t", Self.seconds(end - start)],
                                   duration: end - start, progress: progress, span: 0.3...1)
        return ToolResult(outputs: [out])
    }

    /// silencedetect intervals; an unterminated silence runs to `duration`.
    static func parseSilences(_ log: String, duration: Double) -> [(start: Double, end: Double)] {
        var result: [(Double, Double)] = []
        var open: Double?
        func value(after key: String, in line: Substring) -> Double? {
            guard let r = line.range(of: key) else { return nil }
            let rest = line[r.upperBound...].drop(while: { $0 == " " })
            return Double(rest.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" || $0 == "e" }))
        }
        for line in log.split(separator: "\n") where line.contains("silencedetect") {
            if let s = value(after: "silence_start:", in: line) { open = max(0, s) }
            if let e = value(after: "silence_end:", in: line) {
                result.append((open ?? 0, e))
                open = nil
            }
        }
        if let o = open { result.append((o, duration)) }
        return result
    }

    private func visualize(_ job: Job, progress: @escaping ProgressHandler) async throws -> ToolResult {
        try job.requireAudio()
        let info = job.info
        let graph = "gradients=s=1280x720:r=30:c0=0x2b2440:c1=0x0a0a10:x0=640:y0=0:x1=640:y1=720:n=2:speed=0[bg];"
            + "[0:\(info.audioIndices[0])]aformat=channel_layouts=mono,"
            + "showwaves=s=1200x360:mode=cline:rate=30:colors=0xff7a1a:draw=full:scale=sqrt,format=rgba[w];"
            + "[bg][w]overlay=(W-w)/2:(H-h)/2:shortest=1:format=auto,format=yuv420p[v]"
        var video = MediaEncodeSpec(target: .mp4)
        video.crfOverride = 21
        let args = ["-i", job.url.path, "-filter_complex", graph, "-map", "[v]", "-map", "0:\(info.audioIndices[0])"]
                    + MediaEncoding.videoCodecArgs(for: .mp4, spec: video)
                    + ["-r", "30", "-c:a", FFmpeg.aacEncoder, "-b:a", "192k", "-shortest",
                    "-map_metadata", "0", "-movflags", "+faststart"]
        let out = try await MediaOutput.produce(OutputNaming.url(for: job.url, ext: "mp4", suffix: "visualizer")) { temp in
            try await FFmpeg.run(args + [temp.path], duration: info.duration, progress: progress)
        }
        return ToolResult(outputs: [out])
    }
}
