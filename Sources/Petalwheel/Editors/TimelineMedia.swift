import AVFoundation
import AppKit
import Foundation

// Shared media loading for the timeline editors (Trim, Bleep): waveform peaks, filmstrip frames,
// playability checks and "same format out" naming.

// MARK: - Waveform peaks

/// Min/max sample buckets per channel with a small mip pyramid for fast drawing at any zoom.
final class WaveformPeaks {
    /// Buckets per second at level 0.
    let rate: Double
    let duration: Double
    /// levels[l][channel] = (mins, maxs); each level is `factor` times coarser than the previous one.
    private let levels: [[(mins: [Float], maxs: [Float])]]
    static let factor = 8

    var channelCount: Int { levels.first?.count ?? 0 }
    var bucketCount: Int { levels.first?.first?.mins.count ?? 0 }

    init(rate: Double, channels: [(mins: [Float], maxs: [Float])]) {
        self.rate = rate
        var all = [channels]
        var current = channels
        while (current.first?.mins.count ?? 0) > 2048 {
            current = current.map { ch in
                let n = (ch.mins.count + Self.factor - 1) / Self.factor
                var mins = [Float](repeating: 0, count: n), maxs = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let a = i * Self.factor, b = min(a + Self.factor, ch.mins.count)
                    var lo: Float = 0, hi: Float = 0
                    for j in a..<b { lo = min(lo, ch.mins[j]); hi = max(hi, ch.maxs[j]) }
                    mins[i] = lo; maxs[i] = hi
                }
                return (mins, maxs)
            }
            all.append(current)
        }
        levels = all
        duration = Double(channels.first?.mins.count ?? 0) / rate
        var peak: Float = 0
        for ch in all.last ?? [] {
            for v in ch.mins { peak = max(peak, -v) }
            for v in ch.maxs { peak = max(peak, v) }
        }
        // Quiet recordings are scaled up for display (at most 10×) so their shape stays readable.
        displayGain = peak > 0 ? min(10, 0.95 / peak) : 1
    }

    /// Multiplier that makes the loudest peak fill ~95 % of a lane.
    let displayGain: Float

    /// Min/max of `channel` over [t0, t1), using the coarsest level that still has ≥ 2 buckets per span.
    func extent(channel: Int, from t0: Double, to t1: Double) -> (Float, Float) {
        guard channel < channelCount, t1 > t0 else { return (0, 0) }
        var level = 0
        let wanted = (t1 - t0) * rate
        var f = 1.0
        while level + 1 < levels.count, wanted / (f * Double(Self.factor)) >= 2 {
            level += 1; f *= Double(Self.factor)
        }
        let r = rate / f
        let ch = levels[level][channel]
        let n = ch.mins.count
        guard n > 0 else { return (0, 0) }
        var a = Int((t0 * r).rounded(.down)), b = Int((t1 * r).rounded(.up))
        a = max(0, min(a, n - 1)); b = max(a + 1, min(b, n))
        var lo: Float = 0, hi: Float = 0
        for i in a..<b { lo = min(lo, ch.mins[i]); hi = max(hi, ch.maxs[i]) }
        return (lo, hi)
    }

    /// Peak absolute amplitude across channels of level-0 bucket `i`.
    func amplitude(bucket i: Int) -> Float {
        var m: Float = 0
        for ch in levels[0] where i < ch.mins.count { m = max(m, max(-ch.mins[i], ch.maxs[i])) }
        return m
    }

    /// First and last moments where the signal rises above `thresholdDB`; nil when it never does.
    func audibleRange(thresholdDB: Double) -> (start: Double, end: Double)? {
        let lin = Float(pow(10, thresholdDB / 20))
        let n = bucketCount
        guard n > 0 else { return nil }
        guard let first = (0..<n).first(where: { amplitude(bucket: $0) > lin }),
              let last = (0..<n).last(where: { amplitude(bucket: $0) > lin }) else { return nil }
        return (Double(first) / rate, Double(last + 1) / rate)
    }
}

// MARK: - Filmstrip

final class FilmstripFrames {
    let times: [Double]
    let images: [CGImage]
    init(times: [Double], images: [CGImage]) { self.times = times; self.images = images }

    var aspect: Double {
        guard let i = images.first, i.height > 0 else { return 16.0 / 9 }
        return Double(i.width) / Double(i.height)
    }

    func image(near t: Double) -> CGImage? {
        guard !times.isEmpty else { return nil }
        var best = 0, bestD = Double.greatestFiniteMagnitude
        // times are sorted; binary search would be nicer but counts are small (≤ 80).
        for (i, x) in times.enumerated() {
            let d = abs(x - t)
            if d < bestD { bestD = d; best = i }
        }
        return images[best]
    }
}

// MARK: - Loader

enum TimelineMediaLoader {
    static let peakSampleRate = 8000.0

    /// Waveform peaks for the first audio track (up to two channels). AVFoundation first, ffmpeg fallback.
    static func peaks(for url: URL, info: MediaInfo) async throws -> WaveformPeaks? {
        guard info.hasAudio else { return nil }
        let duration = max(info.duration, 0.01)
        // ~100 buckets per second, capped for very long files.
        let rate = min(100.0, max(4.0, 400_000 / duration))
        if let p = try? await peaksWithAVFoundation(url, rate: rate), p.bucketCount > 0 { return p }
        return try await peaksWithFFmpeg(url, info: info, rate: rate)
    }

    private static func peaksWithAVFoundation(_ url: URL, rate: Double) async throws -> WaveformPeaks? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: peakSampleRate,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        let builder = PeakBuilder(rate: rate, sampleRate: peakSampleRate)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let desc = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let channels = Int(asbd.mChannelsPerFrame)
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let ptr, channels > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: count) { floats in
                builder.append(UnsafeBufferPointer(start: floats, count: count), channels: channels)
            }
        }
        if reader.status == .failed { throw reader.error ?? PetalwheelError(l: "Audio can’t be read.") }
        return builder.finish()
    }

    private static func peaksWithFFmpeg(_ url: URL, info: MediaInfo, rate: Double) async throws -> WaveformPeaks? {
        let channels = min(max(info.channels, 1), 2)
        let dir = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("pcm.raw")
        try await FFmpeg.run(["-i", url.path, "-map", "0:a:0", "-vn", "-sn", "-ac", "\(channels)",
                              "-ar", "\(Int(peakSampleRate))", "-f", "f32le", raw.path], duration: info.duration)
        let data = try Data(contentsOf: raw, options: .mappedIfSafe)
        let builder = PeakBuilder(rate: rate, sampleRate: peakSampleRate)
        data.withUnsafeBytes { bytes in
            let floats = bytes.bindMemory(to: Float.self)
            builder.append(floats, channels: channels)
        }
        return builder.finish()
    }

    /// `count` evenly spaced frames, `height` pixels tall. AVAssetImageGenerator first, ffmpeg fallback.
    static func filmstrip(for url: URL, info: MediaInfo, count: Int, height: Int = 90) async -> FilmstripFrames? {
        guard info.hasVideo, info.duration > 0 else { return nil }
        let times = (0..<count).map { (Double($0) + 0.5) * info.duration / Double(count) }
        if let f = await filmstripWithAVFoundation(url, times: times, height: height), f.images.count == times.count {
            return f
        }
        return try? await filmstripWithFFmpeg(url, info: info, count: count, height: height)
    }

    private static func filmstripWithAVFoundation(_ url: URL, times: [Double], height: Int) async -> FilmstripFrames? {
        let asset = AVURLAsset(url: url)
        // Unplayable assets (GIF, mkv…) can hand back blank frames; let ffmpeg decode those.
        guard (try? await asset.load(.isPlayable)) == true,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: height * 4, height: height)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var images: [CGImage] = []
        for t in times {
            guard let r = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { return nil }
            images.append(r.image)
        }
        return FilmstripFrames(times: times, images: images)
    }

    private static func filmstripWithFFmpeg(_ url: URL, info: MediaInfo, count: Int, height: Int) async throws -> FilmstripFrames? {
        let dir = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fps = Double(count) / info.duration
        try await FFmpeg.run(["-i", url.path, "-map", "0:v:0", "-an", "-sn",
                              "-vf", "fps=\(String(format: "%.6f", fps)),scale=-2:\(height)",
                              "-frames:v", "\(count)", "-q:v", "4", dir.appendingPathComponent("f%04d.jpg").path],
                             duration: info.duration)
        var times: [Double] = [], images: [CGImage] = []
        for i in 0..<count {
            let file = dir.appendingPathComponent(String(format: "f%04d.jpg", i + 1))
            // Decode now: the temp folder is deleted when this function returns.
            guard let data = try? Data(contentsOf: file),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { continue }
            times.append((Double(i) + 0.5) / fps)
            images.append(img)
        }
        return images.isEmpty ? nil : FilmstripFrames(times: times, images: images)
    }

    /// Whether AVFoundation can play the file (mkv, webm, ogg, gif… can't).
    static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        let tracks = (try? await asset.load(.tracks)) ?? []
        return tracks.contains { $0.mediaType == .audio || $0.mediaType == .video }
    }
}

/// Accumulates interleaved float samples into min/max buckets (first two channels).
private final class PeakBuilder {
    let samplesPerBucket: Double
    let rate: Double
    private var mins: [[Float]] = [], maxs: [[Float]] = []
    private var curMin: [Float] = [], curMax: [Float] = []
    private var inBucket = 0.0
    private var channelCount = 0

    init(rate: Double, sampleRate: Double) {
        self.rate = rate
        samplesPerBucket = sampleRate / rate
    }

    func append(_ samples: UnsafeBufferPointer<Float>, channels: Int) {
        let keep = min(channels, 2)
        if channelCount == 0 {
            channelCount = keep
            mins = Array(repeating: [], count: keep); maxs = mins
            curMin = Array(repeating: 0, count: keep); curMax = curMin
        }
        let frames = samples.count / channels
        var idx = 0
        for _ in 0..<frames {
            for c in 0..<channelCount {
                let v = samples[idx + c]
                if v < curMin[c] { curMin[c] = v }
                if v > curMax[c] { curMax[c] = v }
            }
            idx += channels
            inBucket += 1
            if inBucket >= samplesPerBucket { flush(); inBucket -= samplesPerBucket }
        }
    }

    private func flush() {
        for c in 0..<channelCount {
            mins[c].append(curMin[c]); maxs[c].append(curMax[c])
            curMin[c] = 0; curMax[c] = 0
        }
    }

    func finish() -> WaveformPeaks? {
        guard channelCount > 0 else { return nil }
        if inBucket > 0.5 { flush() }
        return WaveformPeaks(rate: rate, channels: (0..<channelCount).map { (mins[$0], maxs[$0]) })
    }
}

// MARK: - Output naming

enum TimelineOutput {
    /// Format to re-encode into, keeping the source container where ffmpeg can write it.
    static func target(for url: URL, info: MediaInfo) -> FileFormat {
        if let f = FileFormat.detect(url),
           MediaEncoding.audioTargets.contains(f) || MediaEncoding.videoTargets.contains(f) || f == .gif {
            return f
        }
        return info.hasVideo ? .mp4 : .m4a
    }

    /// Keeps spellings like ".m4v" / ".aif" when the target is the source's own format.
    static func ext(for url: URL, target: FileFormat) -> String {
        FileFormat.detect(url) == target && !url.pathExtension.isEmpty ? url.pathExtension : target.fileExtension
    }

    static func seconds(_ v: Double) -> String { String(format: "%.3f", max(0, v)) }
}

/// Clock text with hundredths: 1:23.45 / 1:02:03.40.
enum TimelineClockText {
    static func format(_ t: Double) -> String {
        let v = max(0, t.isFinite ? t : 0)
        let cs = Int((v * 100).rounded())
        let h = cs / 360_000, m = (cs / 6000) % 60, s = (cs / 100) % 60, f = cs % 100
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, f) : String(format: "%d:%02d.%02d", m, s, f)
    }

    /// Accepts "83.5", "1:23.45", "1:02:03.4" (comma decimal too).
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0, v.isFinite else { return nil }
            if i > 0 && v >= 60 { return nil }
            total = total * 60 + v
        }
        return total
    }
}

/// One-line description of a media file for editor footers: "1920×1080 · 0:12.00" / "Audio · 0:12.00".
enum TimelineFileInfo {
    static func detail(_ info: MediaInfo) -> String {
        let length = TimelineClockText.format(info.duration)
        if info.hasVideo, info.width > 0, info.height > 0 { return "\(info.width)×\(info.height) · \(length)" }
        return L("Audio") + " · \(length)"
    }
}
