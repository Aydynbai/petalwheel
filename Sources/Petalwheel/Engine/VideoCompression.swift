import Foundation

/// Two explicit SDR video modes. Never silently substitutes a different encoder.
enum VideoCompression {
    static func run(_ source: URL, info: MediaInfo, mode: VideoCompressionMode,
                    progress: @escaping ProgressHandler) async throws -> ToolResult {
        guard info.hasVideo else { throw PetalwheelError("No video stream.") }
        guard let pixel = info.pixelFormat, ["yuv420p", "yuvj420p", "nv12"].contains(pixel),
              !["smpte2084", "arib-std-b67"].contains(info.colorTransfer ?? "") else {
            throw PetalwheelError("Бұл режим әзірге тек 8-bit SDR видеоны қолдайды. HDR/10-bit түпнұсқаны өзгеріссіз қалдырдық.")
        }
        let encoder = mode == .fast ? "hevc_videotoolbox" : "libx265"
        guard FFmpeg.encoders.contains(encoder) else {
            throw PetalwheelError("Таңдалған режим үшін \(encoder) қажет. Басқа режимді таңдаңыз немесе FFmpeg жинағын жаңартыңыз.")
        }
        // AAC/MP3/ALAC/AC-3/E-AC-3 can be copied into MP4. Other tracks use MKV.
        let mp4Audio: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]
        let ext = info.audioCodecs.allSatisfy { mp4Audio.contains($0) } ? "mp4" : "mkv"
        let final = OutputNaming.url(for: source, ext: ext, suffix: mode == .fast ? "fast" : "quality")
        var args = ["-i", source.path, "-map", "0:\(info.videoIndex!)"]
        for index in info.audioIndices { args += ["-map", "0:\(index)"] }
        args += ["-map_metadata", "0", "-map_chapters", "0", "-c:v", encoder, "-pix_fmt", "yuv420p"]
        if mode == .fast {
            args += ["-allow_sw", "0", "-profile:v", "main", "-q:v", "73", "-g", "250", "-bf", "2"]
        } else {
            args += ["-preset", "slow", "-crf", "20", "-x265-params", "log-level=error:pools=4:frame-threads=2"]
        }
        args += ["-fps_mode", "passthrough", "-c:a", "copy"]
        if ext == "mp4" { args += ["-tag:v", "hvc1", "-movflags", "+faststart"] }
        let output = try await MediaOutput.produce(final) { temp in
            try await FFmpeg.run(args + [temp.path], duration: info.duration,
                                 allowEncoderFallback: false, progress: progress)
        }
        let before = MediaOutput.fileSize(source), after = MediaOutput.fileSize(output)
        if before > 0 && after >= before {
            try FileManager.default.removeItem(at: output)
            return ToolResult(outputs: [], messages: ["Көлем азаймады. Артық көшірме сақталмады; түпнұсқа өзгерген жоқ."])
        }
        return ToolResult(outputs: [output], messages: ["\(mode.title): \(before / 1024) KB → \(after / 1024) KB. Дыбыс қайта кодталмады."])
    }
}
