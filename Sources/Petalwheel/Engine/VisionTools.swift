import Foundation
import AppKit
import Vision
import CoreImage
import PDFKit

/// Vision-based tools: background removal, face redaction, QR reading, OCR.
enum VisionTools {
    static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    // MARK: Background removal

    static func removeBackground(_ url: URL) throws -> URL? {
        let loaded = try ImageCodec.load(url)
        let handler = VNImageRequestHandler(cgImage: loaded.image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw NurToError(l: "Could not build the cut-out image.")
        }
        let out = OutputNaming.url(for: url, ext: "png", suffix: "no background")
        try ImageCodec.encode(cg, format: .png, quality: 1).write(to: out, options: .atomic)
        return out
    }

    // MARK: Faces

    static func faceRects(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision boxes are normalized with a bottom-left origin — same as CoreImage.
        return (request.results ?? []).map {
            let b = $0.boundingBox
            return CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h)
        }
    }

    static func blurFaces(_ url: URL, style: RedactionStyle) async throws -> URL? {
        let format = FileFormat.detect(url) ?? .png
        let loaded = try ImageCodec.load(url, format: format)
        let image = loaded.image
        let faces = try faceRects(in: image)
        guard !faces.isEmpty else { return nil }

        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Expand each face box (faces boxes are tight; include hair/chin/ears).
        let regions = faces.map { r -> CGRect in
            r.insetBy(dx: -r.width * 0.2, dy: -r.height * 0.25).intersection(extent)
        }
        let base = CIImage(cgImage: image)
        let longFace = regions.map { max($0.width, $0.height) }.max() ?? 100

        let covered: CIImage
        switch style {
        case .blur:
            covered = base.clampedToExtent()
                .applyingGaussianBlur(sigma: max(8, Double(longFace) / 8))
                .cropped(to: extent)
        case .pixelate:
            covered = base.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, longFace / 7),
                                                            kCIInputCenterKey: CIVector(x: 0, y: 0)])
                .cropped(to: extent)
        case .solid:
            covered = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: extent)
        }

        // Elliptical mask for blur/pixelate (looks natural), rounded rectangles for solid.
        guard let maskCtx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw NurToError(l: "Could not allocate a mask.")
        }
        maskCtx.setFillColor(gray: 0, alpha: 1)
        maskCtx.fill(extent)
        maskCtx.setFillColor(gray: 1, alpha: 1)
        for r in regions {
            if style == .solid {
                maskCtx.addPath(CGPath(roundedRect: r, cornerWidth: r.width * 0.12, cornerHeight: r.width * 0.12, transform: nil))
            } else {
                maskCtx.addEllipse(in: r)
            }
        }
        maskCtx.fillPath()
        guard let maskCG = maskCtx.makeImage() else { throw NurToError(l: "Could not build a mask.") }
        var mask = CIImage(cgImage: maskCG)
        if style != .solid { mask = mask.applyingGaussianBlur(sigma: Double(longFace) / 30).cropped(to: extent) }

        let result = covered.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)

        guard let cg = ciContext.createCGImage(result, from: extent, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw NurToError(l: "Could not render the redacted image.")
        }
        // Keep the source format where possible; fall back to PNG when it can't be written.
        var outFormat = format
        if outFormat == .webp && !ExternalTools.shared.hasWebPEncoder { outFormat = .png }
        else if outFormat != .webp && !ImageCodec.canEncode(outFormat) { outFormat = .png }
        let out = OutputNaming.url(for: url, ext: outFormat.fileExtension, suffix: "redacted")
        // Location/camera metadata of a redacted photo is deliberately not carried over.
        try await ImageCodec.write(cg, to: out, format: outFormat, quality: 0.92)
        return out
    }

    // MARK: Barcodes

    static func barcodes(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }

    static func readCodes(_ url: URL, progress: @escaping ProgressHandler) throws -> [String] {
        var found: [String] = []
        if FileFormat.detect(url) == .pdf {
            let doc = try PDFTools.open(url)
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: i) else { continue }
                let img = try PDFTools.render(page, scale: 2)
                found += try barcodes(in: img)
                progress(Double(i + 1) / Double(doc.pageCount))
            }
        } else {
            found = try barcodes(in: ImageCodec.load(url).image)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    // MARK: OCR

    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if let supported = try? request.supportedRecognitionLanguages() {
            let preferred = ["ru-RU", "en-US"].filter { supported.contains($0) }
            if !preferred.isEmpty { request.recognitionLanguages = preferred }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        return joinLines(observations)
    }

    /// Groups observations into lines (top to bottom, left to right).
    static func joinLines(_ observations: [VNRecognizedTextObservation]) -> String {
        let items = observations.compactMap { o -> (CGRect, String)? in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            return (o.boundingBox, s)
        }.sorted { $0.0.midY > $1.0.midY }
        var lines: [[(CGRect, String)]] = []
        for item in items {
            if let last = lines.last?.first, abs(last.0.midY - item.0.midY) < min(last.0.height, item.0.height) * 0.5 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }
        return lines.map { $0.sorted { $0.0.minX < $1.0.minX }.map(\.1).joined(separator: " ") }.joined(separator: "\n")
    }

    static func recognizeText(_ url: URL, progress: @escaping ProgressHandler) throws -> URL {
        var text = ""
        if FileFormat.detect(url) == .pdf {
            let doc = try PDFTools.open(url)
            var pages: [String] = []
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: i) else { continue }
                if let embedded = PDFTools.text(of: page) {
                    pages.append(embedded)
                } else {
                    let img = try autoreleasepool { try PDFTools.render(page, scale: 2) }
                    pages.append(try recognizeText(in: img))
                }
                progress(Double(i + 1) / Double(doc.pageCount))
            }
            text = pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
        } else {
            text = try recognizeText(in: ImageCodec.load(url).image)
        }
        let out = OutputNaming.url(for: url, ext: "txt")
        try (text + "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}
