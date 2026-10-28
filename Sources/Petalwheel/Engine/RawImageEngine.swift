import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Input-only images: camera RAW (dng, cr2, cr3, nef, arw, raf, orf, rw2) developed with Core Image's
/// RAW filter at its default settings, plus JPEG XL and Photoshop (flattened composite) read through ImageIO.
/// Outputs go through the shared ImageCodec writers (WebP via cwebp, PDF via Quartz).
struct RawImageEngine: ConversionEngine {
    static let sources: Set<FileFormat> = [.dng, .cr2, .cr3, .nef, .arw, .raf, .orf, .rw2, .jxl, .psd]

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        guard Self.sources.contains(source), ImageEngine.targets.contains(target) else { return false }
        if target == .webp { return ExternalTools.shared.hasWebPEncoder }
        if source.isCameraRaw && (target == .bmp || target == .gif) { return false }
        return true
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw PetalwheelError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        if (target == .heic || target == .avif) && !ImageCodec.canEncode(target) {
            throw PetalwheelError(l: "This Mac can't encode %@ images.", target.title)
        }
        progress(0.05)
        let loaded = try Self.load(source, format: from)
        progress(0.6)
        try Task.checkCancellation()
        let out = OutputNaming.url(for: source, ext: target.fileExtension)
        do {
            let metadata = options.preserveMetadata
                ? ImageCodec.carriedMetadata(loaded.properties, width: loaded.width, height: loaded.height)
                : nil
            try await ImageCodec.write(loaded.image, to: out, format: target,
                                       quality: ImageCodec.quality(options.quality), metadata: metadata)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress(1)
        return [out]
    }

    // MARK: Decoding

    /// ImageIO type identifiers for the ImageIO-only inputs.
    private static func typeIdentifier(_ format: FileFormat) -> String? {
        switch format {
        case .jxl: return "public.jpeg-xl"
        case .psd: return "com.adobe.photoshop-image"
        default: return nil
        }
    }

    /// Whether this Mac can read `format` (JPEG XL needs macOS 14+ ImageIO; checked at run time).
    static func canDecode(_ format: FileFormat) -> Bool {
        guard let type = typeIdentifier(format) else { return true }
        let ids = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return ids.contains(type)
    }

    /// Decodes any image Petalwheel reads, upright, with its metadata: RAW through CIRAWFilter, ICO/ICNS
    /// at their largest size, everything else through ImageCodec.
    static func load(_ url: URL, format: FileFormat) throws -> LoadedImage {
        if format.isCameraRaw { return try developRAW(url) }
        if format == .ico || format == .icns { return try IconEngine.loadLargest(url) }
        if !canDecode(format) {
            throw PetalwheelError(l: "This Mac can't read %@ images.", format.title)
        }
        return try ImageCodec.load(url, format: format)
    }

    /// Develops a camera RAW file with Core Image's default processing. The filter applies the file's
    /// orientation; EXIF/TIFF/GPS properties come from ImageIO. Falls back to ImageIO's own decoder
    /// (the embedded preview for cameras Core Image doesn't know).
    static func developRAW(_ url: URL) throws -> LoadedImage {
        let props: [CFString: Any] = {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return [:] }
            return (CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any]) ?? [:]
        }()
        if let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage,
           output.extent.width.isFinite, output.extent.width >= 1, output.extent.height >= 1 {
            let extent = output.extent.integral
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                              .cacheIntermediates: false])
            if let image = context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: cs) {
                let opaque = ImageCodec.flatten(image)
                return LoadedImage(image: opaque, properties: props, sourceType: UTType.rawImage.identifier)
            }
        }
        do {
            return try ImageCodec.load(url)
        } catch {
            throw PetalwheelError(l: "Couldn't develop the RAW photo “%@”. This camera may not be supported by macOS.",
                                  url.lastPathComponent)
        }
    }
}
