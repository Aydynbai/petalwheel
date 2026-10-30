import Foundation
import AppKit
import ImageIO

/// Image and PDF tools.
struct ImageToolsModule: ToolModule {
    func canRun(_ tool: FileTool, format: FileFormat?) -> Bool {
        guard let format else { return false }
        let raster = format.isRasterImage
        let pdf = format == .pdf
        switch tool {
        case .compress, .removeMetadata, .readQRCode, .recognizeText: return raster || pdf
        case .cropImage, .frameImage, .removeBackground, .blurFaces, .createCollage, .createPDF: return raster
        case .mergePDF, .splitPDF: return pdf
        default: return false
        }
    }

    func run(_ tool: FileTool, inputs: [URL], options: ToolOptions,
             progress: @escaping ProgressHandler) async throws -> ToolResult {
        guard let first = inputs.first else { throw NurToError(l: "No files given.") }
        switch tool {
        case .createCollage:
            guard inputs.count >= 2 else { throw NurToError(l: "A collage needs at least two images.") }
            return ToolResult(outputs: [try ImageLayout.collage(inputs, options: options, progress: progress)])
        case .createPDF:
            let out = inputs.count == 1
                ? OutputNaming.url(for: first, ext: "pdf")
                : OutputNaming.url(named: "Images", ext: "pdf", in: first.deletingLastPathComponent())
            do {
                try ImageCodec.writePDF(imageFiles: inputs, to: out, progress: progress)
            } catch {
                try? FileManager.default.removeItem(at: out)
                throw error
            }
            return ToolResult(outputs: [out])
        case .mergePDF:
            guard inputs.count >= 2 else { throw NurToError(l: "Merging needs at least two PDFs.") }
            return ToolResult(outputs: [try PDFTools.merge(inputs, progress: progress)])
        default:
            break
        }

        // Per-file tools.
        var result = ToolResult()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let n = Double(inputs.count)
            let sub: ProgressHandler = { p in progress((Double(i) + p) / n) }
            let r = try await runSingle(tool, url: url, options: options, progress: sub)
            result.outputs += r.outputs
            result.messages += r.messages
        }
        return result
    }

    private func runSingle(_ tool: FileTool, url: URL, options: ToolOptions,
                           progress: @escaping ProgressHandler) async throws -> ToolResult {
        let name = url.lastPathComponent
        let format = FileFormat.detect(url)
        let isPDF = format == .pdf
        progress(0.05)

        switch tool {
        case .compress:
            let original = ImageCodec.fileSize(url)
            let out = isPDF
                ? try await PDFTools.compress(url, quality: options.quality, progress: progress)
                : try await ImageCompression.compress(url, options: options, progress: progress)
            guard let out else {
                return ToolResult(messages: ["\(name) is already well compressed (\(ImageCodec.formatBytes(original))); no smaller file was made."])
            }
            if let target = options.targetSizeKB, ImageCodec.fileSize(out) > Int64(target) * 1024 {
                return ToolResult(outputs: [out], messages: ["\(name): couldn't reach \(target) KB; the result is \(ImageCodec.formatBytes(ImageCodec.fileSize(out)))."])
            }
            return ToolResult(outputs: [out])

        case .removeMetadata:
            let out = isPDF ? try PDFTools.stripMetadata(url) : try await ImageMetadata.strip(url)
            progress(1)
            return ToolResult(outputs: [out])

        case .cropImage:
            return ToolResult(outputs: [try await ImageLayout.crop(url, aspect: options.aspect)])

        case .frameImage:
            return ToolResult(outputs: [try ImageLayout.frame(url, options: options)])

        case .removeBackground:
            guard let out = try VisionTools.removeBackground(url) else {
                return ToolResult(messages: [L("No foreground subject found in %@", name)])
            }
            return ToolResult(outputs: [out])

        case .blurFaces:
            guard let out = try await VisionTools.blurFaces(url, style: options.faceBlurStyle) else {
                return ToolResult(messages: [L("No faces found in %@", name)])
            }
            return ToolResult(outputs: [out])

        case .readQRCode:
            let codes = try VisionTools.readCodes(url, progress: progress)
            return ToolResult(messages: codes.isEmpty ? [L("No QR codes found in %@", name)] : codes)

        case .recognizeText:
            return ToolResult(outputs: [try VisionTools.recognizeText(url, progress: progress)])

        case .splitPDF:
            return ToolResult(outputs: try PDFTools.split(url, progress: progress))

        default:
            throw NurToError(l: "%@ isn't available for %@.", tool.title, name)
        }
    }
}
