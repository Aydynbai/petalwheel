import Foundation

struct VideoPreviewArtifact {
    let directory: URL
    let output: URL
    let seconds: Double
    let elapsed: Double
}

/// One encoding path for both previews and full exports.
enum VideoCompression {
    static func validate(_ info: MediaInfo, mode: VideoCompressionMode) throws {
        guard info.hasVideo else { throw NurToError("No video track.") }
        guard let pixel = info.pixelFormat, ["yuv420p", "yuvj420p", "nv12"].contains(pixel),
              !["smpte2084", "arib-std-b67"].contains(info.colorTransfer ?? "") else {
            throw NurToError("8-bit SDR only. HDR/10-bit is not supported yet.")
        }
        let encoder = mode == .fast ? "hevc_videotoolbox" : "libx265"
        guard FFmpeg.encoders.contains(encoder) else {
            throw NurToError(mode == .quality
                ? "Quality mode is unavailable. Try Fast."
                : "Fast mode is unavailable. Try Quality.")
        }
    }

    static func outputExtension(_ info: MediaInfo) -> String {
        let mp4Audio: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]
        return info.audioCodecs.allSatisfy { mp4Audio.contains($0) } ? "mp4" : "mkv"
    }

    static func arguments(_ source: URL, info: MediaInfo, mode: VideoCompressionMode,
                          start: Double? = nil, duration: Double? = nil) throws -> [String] {
        try validate(info, mode: mode)
        var args: [String] = []
        if let start { args += ["-ss", String(format: "%.6f", max(0, start))] }
        args += ["-i", source.path]
        if let duration { args += ["-t", String(format: "%.6f", duration)] }
        args += ["-map", "0:\(info.videoIndex!)"]
        for index in info.audioIndices { args += ["-map", "0:\(index)"] }
        args += ["-map_metadata", "0", "-map_chapters", duration == nil ? "0" : "-1",
                 "-c:v", mode == .fast ? "hevc_videotoolbox" : "libx265", "-pix_fmt", "yuv420p"]
        if mode == .fast {
            args += ["-allow_sw", "0", "-profile:v", "main", "-q:v", "73", "-g", "250", "-bf", "2"]
        } else {
            args += ["-preset", "slow", "-crf", "20", "-x265-params", "log-level=error:pools=4:frame-threads=2"]
        }
        args += ["-fps_mode", "passthrough", "-c:a", "copy"]
        if outputExtension(info) == "mp4" { args += ["-tag:v", "hvc1", "-movflags", "+faststart"] }
        return args
    }

    static func preview(_ source: URL, info: MediaInfo, mode: VideoCompressionMode,
                        start: Double, seconds: Double = 3,
                        progress: @escaping ProgressHandler) async throws -> VideoPreviewArtifact {
        let length = min(seconds, info.duration - start)
        guard start >= 0, start.isFinite, length > 0, length.isFinite else { throw NurToError("Choose a preview range.") }
        let dir = try OutputNaming.tempDirectory()
        let output = dir.appendingPathComponent("preview").appendingPathExtension(outputExtension(info))
        let clock = Date()
        do {
            let args = try arguments(source, info: info, mode: mode, start: start, duration: length)
            try await FFmpeg.run(args + [output.path], duration: length, allowEncoderFallback: false, progress: progress)
            try Task.checkCancellation()
            return VideoPreviewArtifact(directory: dir, output: output, seconds: length, elapsed: Date().timeIntervalSince(clock))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    static func run(_ source: URL, info: MediaInfo, mode: VideoCompressionMode,
                    progress: @escaping ProgressHandler) async throws -> ToolResult {
        let args = try arguments(source, info: info, mode: mode)
        let final = OutputNaming.url(for: source, ext: outputExtension(info), suffix: mode == .fast ? "fast" : "quality")
        let output = try await MediaOutput.produce(final) { temp in
            try await FFmpeg.run(args + [temp.path], duration: info.duration,
                                 allowEncoderFallback: false, progress: progress)
        }
        let before = MediaOutput.fileSize(source), after = MediaOutput.fileSize(output)
        if before > 0 && after >= before {
            try FileManager.default.removeItem(at: output)
            return ToolResult(outputs: [], messages: ["Already compact. Original kept."])
        }
        return ToolResult(outputs: [output])
    }
}
