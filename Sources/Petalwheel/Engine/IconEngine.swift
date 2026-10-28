import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Favicon and app-icon output, and icon files as input.
/// - any image → ICO: 16, 32, 48, 64, 128 and 256 px PNG-compressed entries, written by our own encoder.
/// - any image → ICNS: an iconset (16…1024 px, 1x and 2x) packed by `iconutil`, falling back to ImageIO.
/// - ICO / ICNS → other formats: the largest image in the file.
/// Non-square pictures are centred on a transparent square canvas first.
struct IconEngine: ConversionEngine {
    static let icoSizes = [16, 32, 48, 64, 128, 256]
    static let iconutil = URL(fileURLWithPath: "/usr/bin/iconutil")

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        guard source.group == .images else { return false }
        if target == .ico || target == .icns { return source != .pdf }
        guard source == .ico || source == .icns else { return false }
        if target == .webp { return ExternalTools.shared.hasWebPEncoder }
        return ImageEngine.targets.contains(target)
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw PetalwheelError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        progress(0.05)
        let loaded = try RawImageEngine.load(source, format: from)
        progress(0.3)
        try Task.checkCancellation()
        let out = OutputNaming.url(for: source, ext: target.fileExtension)
        do {
            switch target {
            case .ico:
                try Self.icoData(from: loaded.image).write(to: out, options: .atomic)
            case .icns:
                try await Self.writeICNS(from: loaded.image, to: out)
            default:
                if (target == .heic || target == .avif) && !ImageCodec.canEncode(target) {
                    throw PetalwheelError(l: "This Mac can't encode %@ images.", target.title)
                }
                try await ImageCodec.write(loaded.image, to: out, format: target,
                                           quality: ImageCodec.quality(options.quality), metadata: nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress(1)
        return [out]
    }

    // MARK: Reading

    /// The largest image in an ICO / ICNS file (ImageIO lists every size as a separate image).
    static func loadLargest(_ url: URL) throws -> LoadedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw PetalwheelError(l: "Could not read the image %@.", url.lastPathComponent)
        }
        var best: (index: Int, pixels: Int)?
        for i in 0..<CGImageSourceGetCount(src) {
            let p = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]) ?? [:]
            let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            if best == nil || w * h > best!.pixels { best = (i, w * h) }
        }
        guard let index = best?.index,
              let image = CGImageSourceCreateImageAtIndex(src, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw PetalwheelError(l: "Could not decode the image %@.", url.lastPathComponent)
        }
        return LoadedImage(image: image, properties: [:], sourceType: CGImageSourceGetType(src) as String?)
    }

    // MARK: Square canvas

    /// `image` centred on a transparent square of `side` px, scaled to fit.
    static func squared(_ image: CGImage, side: Int) throws -> CGImage {
        guard let ctx = ImageCodec.makeContext(width: side, height: side, opaque: false) else {
            throw PetalwheelError(l: "Could not allocate an image of %d×%d.", side, side)
        }
        let w = Double(image.width), h = Double(image.height)
        let scale = Double(side) / max(w, h)
        let dw = w * scale, dh = h * scale
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(side) - dw) / 2, y: (Double(side) - dh) / 2, width: dw, height: dh))
        guard let out = ctx.makeImage() else { throw PetalwheelError(l: "Could not render the icon.") }
        return out
    }

    /// Downscales in halving steps first so small sizes stay crisp (single-step high-quality interpolation
    /// from a very large picture aliases).
    static func iconImage(_ image: CGImage, side: Int) throws -> CGImage {
        var src = image
        while max(src.width, src.height) > side * 4 {
            src = ImageCodec.scaled(src, toWidth: max(1, src.width / 2), height: max(1, src.height / 2))
        }
        return try squared(src, side: side)
    }

    // MARK: ICO

    /// ICONDIR (6 bytes) + one 16-byte ICONDIRENTRY per size + PNG payloads.
    static func icoData(from image: CGImage, sizes: [Int] = icoSizes) throws -> Data {
        var payloads: [(side: Int, png: Data)] = []
        for side in sizes {
            payloads.append((side, try ImageCodec.encode(try iconImage(image, side: side), format: .png, quality: 1)))
        }
        var data = Data()
        func u16(_ v: Int) { data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        u16(0)                  // reserved
        u16(1)                  // type: icon
        u16(payloads.count)
        var offset = 6 + 16 * payloads.count
        for p in payloads {
            data.append(UInt8(p.side >= 256 ? 0 : p.side))   // width (0 = 256)
            data.append(UInt8(p.side >= 256 ? 0 : p.side))   // height
            data.append(0)      // palette colours
            data.append(0)      // reserved
            u16(1)              // colour planes
            u16(32)             // bits per pixel
            u32(p.png.count)
            u32(offset)
            offset += p.png.count
        }
        for p in payloads { data.append(p.png) }
        return data
    }

    // MARK: ICNS

    static func writeICNS(from image: CGImage, to output: URL) async throws {
        let temp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let iconset = temp.appendingPathComponent("icon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        var rendered: [Int: Data] = [:]
        func png(_ side: Int) throws -> Data {
            if let d = rendered[side] { return d }
            let d = try ImageCodec.encode(try iconImage(image, side: side), format: .png, quality: 1)
            rendered[side] = d
            return d
        }
        for base in [16, 32, 128, 256, 512] {
            try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
            try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        let packed = temp.appendingPathComponent("icon.icns")
        do {
            try await ProcessRunner.run(iconutil, ["-c", "icns", iconset.path, "-o", packed.path])
        } catch {
            // ImageIO writes ICNS too (one image per size).
            try? FileManager.default.removeItem(at: packed)
            guard let dest = CGImageDestinationCreateWithURL(packed as CFURL, UTType.icns.identifier as CFString, 6, nil) else {
                throw PetalwheelError(l: "This Mac can't write %@ images.", FileFormat.icns.title)
            }
            for side in [16, 32, 64, 128, 256, 512, 1024] {
                CGImageDestinationAddImage(dest, try iconImage(image, side: side), nil)
            }
            guard CGImageDestinationFinalize(dest) else {
                throw PetalwheelError(l: "Failed to encode the %@ image.", FileFormat.icns.title)
            }
        }
        try FileManager.default.moveItem(at: packed, to: output)
    }
}
