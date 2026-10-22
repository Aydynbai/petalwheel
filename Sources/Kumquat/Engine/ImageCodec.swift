import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A decoded image with orientation already applied to the pixels, plus its original properties.
struct LoadedImage {
    var image: CGImage
    /// Source properties (EXIF, GPS, TIFF, IPTC…), or empty.
    var properties: [CFString: Any]
    var sourceType: String?

    var width: Int { image.width }
    var height: Int { image.height }
    var hasAlpha: Bool { ImageCodec.hasAlpha(image) }
}

/// Shared ImageIO / CoreGraphics helpers used by ImageEngine, ImageToolsModule and the PDF/Vision tools.
enum ImageCodec {
    // MARK: Quality

    static func quality(_ q: Quality) -> Double {
        switch q {
        case .compact: return 0.6
        case .balanced: return 0.8
        case .high: return 0.92
        }
    }

    // MARK: Type identifiers

    static func utType(for format: FileFormat) -> String? {
        switch format {
        case .jpg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .heic: return UTType.heic.identifier
        case .avif: return "public.avif"
        case .tiff: return UTType.tiff.identifier
        case .bmp: return UTType.bmp.identifier
        case .gif: return UTType.gif.identifier
        default: return nil
        }
    }

    static func canEncode(_ format: FileFormat) -> Bool {
        guard let t = utType(for: format) else { return false }
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return ids.contains(t)
    }

    /// Formats where alpha must be flattened onto white.
    static func needsOpaque(_ format: FileFormat) -> Bool { format == .jpg || format == .bmp }

    static func supportsQuality(_ format: FileFormat) -> Bool {
        [.jpg, .heic, .avif].contains(format)
    }

    // MARK: Loading

    static func load(_ url: URL, format: FileFormat? = nil) throws -> LoadedImage {
        let fmt = format ?? FileFormat.detect(url)
        if fmt == .svg { return LoadedImage(image: try renderSVG(url), properties: [:], sourceType: nil) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else {
            throw KumquatError(l: "Could not read the image %@.", url.lastPathComponent)
        }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        guard let raw = CGImageSourceCreateImageAtIndex(src, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw KumquatError(l: "Could not decode the image %@.", url.lastPathComponent)
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let oriented = try applyOrientation(raw, orientation: CGImagePropertyOrientation(rawValue: orientation) ?? .up)
        return LoadedImage(image: oriented, properties: props, sourceType: CGImageSourceGetType(src) as String?)
    }

    /// Raw (unoriented) image + orientation, useful for PDF passthrough of JPEG data.
    static func loadRaw(_ url: URL) -> (CGImage, CGImagePropertyOrientation)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        guard let img = CGImageSourceCreateImageAtIndex(src, index, nil) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
        let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (img, CGImagePropertyOrientation(rawValue: o) ?? .up)
    }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    // MARK: SVG

    static func renderSVG(_ url: URL) throws -> CGImage {
        guard let img = NSImage(contentsOf: url) else {
            throw KumquatError(l: "Could not read the SVG %@.", url.lastPathComponent)
        }
        var size = img.size
        if size.width < 1 || size.height < 1 { size = CGSize(width: 1024, height: 1024) }
        let long = max(size.width, size.height)
        // At least 2x; small icons go up to ~1024 px on the long side; never above 8192.
        var scale: CGFloat = 2
        if long * scale < 1024 { scale = 1024 / long }
        if long * scale > 8192 { scale = 8192 / long }
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = makeContext(width: w, height: h, opaque: false) else {
            throw KumquatError(l: "Could not allocate an image of %d×%d.", w, h)
        }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        img.draw(in: CGRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let out = ctx.makeImage() else { throw KumquatError(l: "Could not render the SVG %@.", url.lastPathComponent) }
        return out
    }

    // MARK: Pixel ops

    static func makeContext(width: Int, height: Int, opaque: Bool) -> CGContext? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: cs, bitmapInfo: info)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// True if the image has an alpha channel with at least one non-opaque pixel.
    static func usesAlpha(_ image: CGImage) -> Bool {
        guard hasAlpha(image) else { return false }
        // Check on a downscaled copy for speed — a reasonable approximation.
        let maxSide = 512
        let s = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return true }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return true }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h)
        for i in 0..<(w * h) where p[i] < 255 { return true }
        return false
    }

    static func flatten(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        guard hasAlpha(image), let ctx = makeContext(width: image.width, height: image.height, opaque: true) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(background)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func scaled(_ image: CGImage, toWidth w: Int, height h: Int) -> CGImage {
        guard w > 0, h > 0, w != image.width || h != image.height,
              let ctx = makeContext(width: w, height: h, opaque: !hasAlpha(image)) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Scales so that the long side is at most `maxSide`.
    static func limited(_ image: CGImage, maxSide: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxSide else { return image }
        let s = Double(maxSide) / Double(long)
        return scaled(image, toWidth: max(1, Int((Double(image.width) * s).rounded())),
                      height: max(1, Int((Double(image.height) * s).rounded())))
    }

    /// The affine transform that maps an image drawn in a `w×h` (raw) rect to its upright orientation.
    static func orientationTransform(_ o: CGImagePropertyOrientation, rawWidth w: CGFloat, rawHeight h: CGFloat) -> CGAffineTransform {
        // CoreGraphics' origin is bottom-left; EXIF orientations describe the top-left based raw data.
        var t = CGAffineTransform.identity
        switch o {
        case .up: break
        case .upMirrored: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .left: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .leftMirrored: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
        return t
    }

    static func applyOrientation(_ image: CGImage, orientation o: CGImagePropertyOrientation) throws -> CGImage {
        guard o != .up else { return image }
        let rw = image.width, rh = image.height
        let swap = [.left, .leftMirrored, .right, .rightMirrored].contains(o)
        let w = swap ? rh : rw, h = swap ? rw : rh
        let cs = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else {
            throw KumquatError(l: "Could not allocate an image of %d×%d.", w, h)
        }
        ctx.concatenate(orientationTransform(o, rawWidth: CGFloat(rw), rawHeight: CGFloat(rh)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rw, height: rh))
        guard let out = ctx.makeImage() else { throw KumquatError(l: "Could not rotate the image.") }
        return out
    }

    // MARK: Metadata

    /// Metadata dictionaries to carry into an upright output image of size `w×h`.
    static func carriedMetadata(_ props: [CFString: Any], width w: Int, height h: Int) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let v = props[key] { out[key] = v }
        }
        if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = w
            exif[kCGImagePropertyExifPixelYDimension] = h
            out[kCGImagePropertyExifDictionary] = exif
        }
        return out
    }

    // MARK: Encoding

    static func encode(_ image: CGImage, format: FileFormat, quality: Double,
                       metadata: [CFString: Any]? = nil) throws -> Data {
        guard let type = utType(for: format) else { throw KumquatError(l: "Can't encode %@ images.", format.title) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw KumquatError(l: "This Mac can't write %@ images.", format.title)
        }
        var img = image
        if needsOpaque(format) { img = flatten(img) }
        var props: [CFString: Any] = metadata ?? [:]
        props[kCGImagePropertyOrientation] = 1
        if supportsQuality(format) { props[kCGImageDestinationLossyCompressionQuality] = quality }
        if format == .tiff {
            var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if format == .gif { props.removeValue(forKey: kCGImagePropertyExifDictionary); props.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw KumquatError(l: "Failed to encode the %@ image.", format.title)
        }
        return data as Data
    }

    static func write(_ image: CGImage, to url: URL, format: FileFormat, quality: Double,
                      metadata: [CFString: Any]? = nil) async throws {
        if format == .webp {
            try await writeWebP(image, to: url, quality: quality)
            return
        }
        if format == .pdf {
            try writePDF(images: [image], to: url)
            return
        }
        let data = try encode(image, format: format, quality: quality, metadata: metadata)
        try data.write(to: url, options: .atomic)
    }

    static func writeWebP(_ image: CGImage, to url: URL, quality: Double) async throws {
        let cwebp = try ExternalTools.shared.require(ExternalTools.shared.cwebp, "cwebp")
        let tmp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let png = tmp.appendingPathComponent("in.png")
        try encode(image, format: .png, quality: 1).write(to: png)
        let q = Int((quality * 100).rounded())
        try await ProcessRunner.run(cwebp, ["-quiet", "-q", "\(q)", "-alpha_q", "\(max(q, 80))", "-mt", png.path, "-o", url.path])
    }

    // MARK: PDF from images

    /// Writes one page per image, each page the image's pixel size at 72 dpi.
    static func writePDF(images: [CGImage], to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw KumquatError(l: "Could not create %@.", url.lastPathComponent)
        }
        for img in images {
            var box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(pdfFriendly(img), in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// Writes image files to a PDF, keeping JPEG data as-is (no re-encode) where possible.
    static func writePDF(imageFiles: [URL], to url: URL, progress: ProgressHandler? = nil) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw KumquatError(l: "Could not create %@.", url.lastPathComponent)
        }
        for (i, file) in imageFiles.enumerated() {
            let fmt = FileFormat.detect(file)
            if fmt == .jpg, let (raw, o) = loadRaw(file) {
                // Draw the original JPEG with the orientation as a transform: Quartz embeds the DCT data directly.
                let swap = [.left, .leftMirrored, .right, .rightMirrored].contains(o)
                let w = swap ? raw.height : raw.width, h = swap ? raw.width : raw.height
                var box = CGRect(x: 0, y: 0, width: w, height: h)
                ctx.beginPage(mediaBox: &box)
                ctx.concatenate(orientationTransform(o, rawWidth: CGFloat(raw.width), rawHeight: CGFloat(raw.height)))
                ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
                ctx.endPage()
            } else {
                let img = try load(file, format: fmt).image
                var box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
                ctx.beginPage(mediaBox: &box)
                ctx.interpolationQuality = .high
                ctx.draw(pdfFriendly(img), in: box)
                ctx.endPage()
            }
            progress?(Double(i + 1) / Double(imageFiles.count))
        }
        ctx.closePDF()
    }

    /// Opaque images are wrapped as JPEG (q 0.9) so the PDF stays small; images with transparency stay lossless.
    static func pdfFriendly(_ image: CGImage) -> CGImage {
        guard !usesAlpha(image),
              let data = try? encode(image, format: .jpg, quality: 0.9),
              let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return image }
        return jpeg
    }

    // MARK: Files

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// A fresh folder next to `source` named "<name> pages" (or "<name> pages 2" …).
    static func uniqueFolder(near source: URL, name: String) throws -> URL {
        let dir = source.deletingLastPathComponent()
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name, isDirectory: true)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(i)", isDirectory: true)
            i += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    static func baseName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}
