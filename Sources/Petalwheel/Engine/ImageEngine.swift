import Foundation
import AppKit
import ImageIO

/// Image conversions via ImageIO (raster), NSImage (SVG), PDFKit (PDF pages) and cwebp (WebP output).
struct ImageEngine: ConversionEngine {
    static let targets: Set<FileFormat> = [.jpg, .png, .heic, .webp, .avif, .tiff, .bmp, .gif, .pdf]

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        if source == .pdf { return target == .png || target == .jpg }
        guard source.group == .images, Self.targets.contains(target) else { return false }
        if target == .webp { return ExternalTools.shared.hasWebPEncoder }
        return true
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            if target == .webp { _ = try ExternalTools.shared.require(nil, "cwebp") }
            throw NurToError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        let quality = ImageCodec.quality(options.quality)
        progress(0.05)

        if from == .pdf {
            return try await PDFTools.renderPages(source, format: target, quality: quality, progress: progress)
        }

        let loaded = try ImageCodec.load(source, format: from)
        progress(0.4)
        try Task.checkCancellation()

        let out = OutputNaming.url(for: source, ext: target.fileExtension)
        do {
            if target == .pdf {
                if from == .jpg {
                    // Embed the JPEG data unchanged.
                    try ImageCodec.writePDF(imageFiles: [source], to: out)
                } else {
                    try ImageCodec.writePDF(images: [loaded.image], to: out)
                }
            } else {
                let metadata = options.preserveMetadata
                    ? ImageCodec.carriedMetadata(loaded.properties, width: loaded.width, height: loaded.height)
                    : nil
                if (target == .heic || target == .avif) && !ImageCodec.canEncode(target) {
                    throw NurToError(l: "This Mac can't encode %@ images.", target.title)
                }
                try await ImageCodec.write(loaded.image, to: out, format: target, quality: quality, metadata: metadata)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress(1)
        return [out]
    }
}
