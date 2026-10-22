import Foundation

/// Audio / video / GIF conversions through ffmpeg.
struct MediaEngine: ConversionEngine {
    private static let videoOutputs: Set<FileFormat> = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3, .m4a, .wav]
    private static let gifOutputs: Set<FileFormat> = [.mp4, .mov, .webm, .png, .jpg, .gif]

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        switch source.group {
        case .audio:
            return MediaEncoding.audioTargets.contains(target)
        case .video:
            if source == .gif { return Self.gifOutputs.contains(target) }
            return Self.videoOutputs.contains(target)
        default:
            return false
        }
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw KumquatError(l: "Can’t convert %@ to %@.", from.title, target.title)
        }
        let info = try await MediaProbe.probe(source)
        if MediaEncoding.audioTargets.contains(target), !info.hasAudio {
            throw KumquatError(l: "“%@” has no audio track to extract.", source.lastPathComponent)
        }
        if !MediaEncoding.audioTargets.contains(target), !info.hasVideo {
            throw KumquatError(l: "“%@” has no video track.", source.lastPathComponent)
        }

        var spec = MediaEncodeSpec(target: target)
        spec.quality = options.quality
        spec.preserveMetadata = options.preserveMetadata
        spec.keepArtwork = options.preserveMetadata
        spec.maxHeight = options.videoMaxHeight
        spec.gifFrameRate = options.gifFrameRate
        spec.gifMaxWidth = options.gifMaxWidth
        spec.sourceName = source.lastPathComponent
        spec.sourceIsGIF = from == .gif
        // A custom bitrate (anything but the default) overrides the quality preset.
        if options.audioBitrateKbps != ConversionOptions().audioBitrateKbps { spec.audioKbps = options.audioBitrateKbps }

        let final = OutputNaming.url(for: source, ext: target.fileExtension)
        let duration = (target == .png || target == .jpg) ? 0.001 : info.duration
        let out = try await MediaOutput.produce(final) { temp in
            do {
                try await FFmpeg.run(["-i", source.path] + MediaEncoding.outputArgs(spec, info: info) + [temp.path],
                                     duration: duration, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch where spec.keepArtwork && info.attachedPicIndex != nil && (target == .mp3 || target == .m4a) {
                // Cover art the container can't take: retry without it.
                spec.keepArtwork = false
                try await FFmpeg.run(["-i", source.path] + MediaEncoding.outputArgs(spec, info: info) + [temp.path],
                                     duration: duration, progress: progress)
            }
        }
        progress(1)
        return [out]
    }
}
