import Foundation
import ImageIO
import CoreGraphics

/// Re-encodes raster images to a smaller file in the same format.
enum ImageCompression {
    /// Returns the compressed file, or nil if it couldn't beat the original size.
    static func compress(_ url: URL, options: ToolOptions, progress: @escaping ProgressHandler) async throws -> URL? {
        guard let format = FileFormat.detect(url), format.isRasterImage else {
            throw NurToError(l: "Can't compress %@.", url.lastPathComponent)
        }
        if format == .webp { _ = try ExternalTools.shared.require(ExternalTools.shared.cwebp, "cwebp") }
        if [.heic, .avif].contains(format) && !ImageCodec.canEncode(format) {
            throw NurToError(l: "This Mac can't encode %@ images.", format.title)
        }
        let original = ImageCodec.fileSize(url)
        let loaded = try ImageCodec.load(url, format: format)
        var image = loaded.image
        if options.quality == .compact { image = ImageCodec.limited(image, maxSide: 4096) }
        if !ImageCodec.usesAlpha(image) || ImageCodec.needsOpaque(format) {
            image = ImageCodec.flatten(image)
        }
        progress(0.2)

        let tmp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let candidate = tmp.appendingPathComponent("out").appendingPathExtension(format.fileExtension)
        let metadata = ImageCodec.carriedMetadata(loaded.properties, width: image.width, height: image.height)
        let targetBytes = options.targetSizeKB.map { Int64($0) * 1024 }

        func encode(_ img: CGImage, quality: Double) async throws -> Int64 {
            try Task.checkCancellation()
            switch format {
            case .png:
                try pngData(img, quality: options.quality).write(to: candidate, options: .atomic)
            default:
                try await ImageCodec.write(img, to: candidate, format: format, quality: quality,
                                           metadata: targetBytes == nil ? metadata : nil)
            }
            return ImageCodec.fileSize(candidate)
        }

        let lossy = [.jpg, .heic, .avif, .webp].contains(format)
        if let target = targetBytes {
            var img = image
            var done = false
            for _ in 0..<8 where !done {
                if lossy {
                    // Binary search the highest quality that fits.
                    var lo = 0.05, hi = 0.95, best: Double?
                    for _ in 0..<7 {
                        let mid = (lo + hi) / 2
                        if try await encode(img, quality: mid) <= target { best = mid; lo = mid } else { hi = mid }
                    }
                    if let best {
                        _ = try await encode(img, quality: best)
                        done = true
                        break
                    }
                    _ = try await encode(img, quality: 0.05)
                } else {
                    if try await encode(img, quality: 1) <= target { done = true; break }
                }
                // Too big even at the lowest setting: shrink the dimensions and retry.
                let current = Double(ImageCodec.fileSize(candidate))
                let factor = min(0.9, max(0.5, (Double(target) / current).squareRoot() * 0.95))
                img = ImageCodec.scaled(img, toWidth: max(1, Int(Double(img.width) * factor)),
                                        height: max(1, Int(Double(img.height) * factor)))
                progress(0.2 + 0.08 * Double(img.width) / Double(max(1, image.width)))
            }
        } else {
            _ = try await encode(image, quality: ImageCodec.quality(options.quality))
        }
        progress(0.9)

        let size = ImageCodec.fileSize(candidate)
        // Require a meaningful saving unless the user asked for a specific size.
        let limit = targetBytes == nil ? original * 97 / 100 : original - 1
        guard size > 0, size <= limit else { return nil }
        let out = OutputNaming.url(for: url, ext: format.fileExtension, suffix: "compressed")
        try FileManager.default.moveItem(at: candidate, to: out)
        progress(1)
        return out
    }

    // MARK: PNG

    /// PNG: exact palette when the image has ≤256 colours, otherwise median-cut quantisation for
    /// compact/balanced (opaque images only). Transparent images are re-encoded as 8-bit RGBA.
    static func pngData(_ image: CGImage, quality: Quality) throws -> Data {
        if !ImageCodec.hasAlpha(image) {
            if let indexed = quantize(image, allowLossy: quality != .high) {
                return try ImageCodec.encode(indexed, format: .png, quality: 1)
            }
        }
        return try ImageCodec.encode(image, format: .png, quality: 1)
    }

    /// Returns an indexed-colour copy of an opaque image, or nil.
    static func quantize(_ image: CGImage, allowLossy: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard w * h > 0, let ctx = ImageCodec.makeContext(width: w, height: h, opaque: true) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let src = base.bindMemory(to: UInt8.self, capacity: bpr * h)

        // 1. Exact palette?
        var unique = [UInt32: UInt8]()
        var exact = true
        outer: for y in 0..<h {
            let row = src + y * bpr
            for x in 0..<w {
                let p = row + x * 4
                let key = UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])
                if unique[key] == nil {
                    if unique.count == 256 { exact = false; break outer }
                    unique[key] = UInt8(unique.count)
                }
            }
        }

        var palette: [(Int, Int, Int)] = []
        if exact {
            palette = Array(repeating: (0, 0, 0), count: unique.count)
            for (k, i) in unique { palette[Int(i)] = (Int(k >> 16 & 255), Int(k >> 8 & 255), Int(k & 255)) }
        } else {
            guard allowLossy else { return nil }
            palette = medianCut(src, width: w, height: h, bytesPerRow: bpr, colors: 256)
        }

        // 2. Map pixels.
        var indices = [UInt8](repeating: 0, count: w * h)
        if exact {
            for y in 0..<h {
                let row = src + y * bpr
                for x in 0..<w {
                    let p = row + x * 4
                    indices[y * w + x] = unique[UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])]!
                }
            }
        } else {
            var cache = [Int16](repeating: -1, count: 1 << 18)
            for y in 0..<h {
                let row = src + y * bpr
                for x in 0..<w {
                    let p = row + x * 4
                    let key = Int(p[0] >> 2) << 12 | Int(p[1] >> 2) << 6 | Int(p[2] >> 2)
                    var idx = cache[key]
                    if idx < 0 {
                        let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                        var best = 0, bestD = Int.max
                        for (i, c) in palette.enumerated() {
                            let dr = r - c.0, dg = g - c.1, db = b - c.2
                            let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                            if d < bestD { bestD = d; best = i }
                        }
                        idx = Int16(best)
                        cache[key] = idx
                    }
                    indices[y * w + x] = UInt8(idx)
                }
            }
        }

        var table: [UInt8] = []
        for c in palette { table += [UInt8(c.0), UInt8(c.1), UInt8(c.2)] }
        guard let cs = CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    last: palette.count - 1, colorTable: table),
              let provider = CGDataProvider(data: Data(indices) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private struct Box {
        var pixels: [(UInt8, UInt8, UInt8)]
        var range: (Int, Int, Int) {
            var lo = (255, 255, 255), hi = (0, 0, 0)
            for p in pixels {
                lo = (min(lo.0, Int(p.0)), min(lo.1, Int(p.1)), min(lo.2, Int(p.2)))
                hi = (max(hi.0, Int(p.0)), max(hi.1, Int(p.1)), max(hi.2, Int(p.2)))
            }
            return (hi.0 - lo.0, hi.1 - lo.1, hi.2 - lo.2)
        }
    }

    static func medianCut(_ src: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int, bytesPerRow bpr: Int,
                          colors: Int) -> [(Int, Int, Int)] {
        // Sample ≈ 150k pixels.
        let step = max(1, Int((Double(w * h) / 150_000).squareRoot()))
        var sample: [(UInt8, UInt8, UInt8)] = []
        sample.reserveCapacity((w / step + 1) * (h / step + 1))
        var y = 0
        while y < h {
            let row = src + y * bpr
            var x = 0
            while x < w { let p = row + x * 4; sample.append((p[0], p[1], p[2])); x += step }
            y += step
        }
        var boxes = [Box(pixels: sample)]
        while boxes.count < colors {
            // Split the box with the largest (range × population).
            var bestIndex = -1, bestScore = 0
            var bestRange = (0, 0, 0)
            for (i, b) in boxes.enumerated() where b.pixels.count > 1 {
                let r = b.range
                let score = max(r.0, r.1, r.2) * Int(Double(b.pixels.count).squareRoot())
                if score > bestScore { bestScore = score; bestIndex = i; bestRange = r }
            }
            guard bestIndex >= 0 else { break }
            var px = boxes[bestIndex].pixels
            if bestRange.1 >= bestRange.0 && bestRange.1 >= bestRange.2 { px.sort { $0.1 < $1.1 } }
            else if bestRange.0 >= bestRange.2 { px.sort { $0.0 < $1.0 } }
            else { px.sort { $0.2 < $1.2 } }
            let mid = px.count / 2
            boxes[bestIndex] = Box(pixels: Array(px[..<mid]))
            boxes.append(Box(pixels: Array(px[mid...])))
        }
        return boxes.map { b in
            var r = 0, g = 0, bl = 0
            for p in b.pixels { r += Int(p.0); g += Int(p.1); bl += Int(p.2) }
            let n = max(1, b.pixels.count)
            return (r / n, g / n, bl / n)
        }
    }
}
