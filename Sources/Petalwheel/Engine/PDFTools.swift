import Foundation
import AppKit
import PDFKit
import Quartz

/// PDF helpers: page rendering, merge/split, compression and metadata removal.
enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw PetalwheelError(l: "Could not open the PDF %@.", url.lastPathComponent)
        }
        if doc.isLocked {
            throw PetalwheelError(l: "%@ is password-protected.", url.lastPathComponent)
        }
        return doc
    }

    /// Renders a page (crop box, rotation applied) to an image at `scale` (2 = 144 dpi).
    static func render(_ page: PDFPage, scale: CGFloat = 2, opaque: Bool = true) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let wPt = rotated ? bounds.height : bounds.width
        let hPt = rotated ? bounds.width : bounds.height
        let w = max(1, Int((wPt * scale).rounded())), h = max(1, Int((hPt * scale).rounded()))
        guard w * h <= 400_000_000, let ctx = ImageCodec.makeContext(width: w, height: h, opaque: opaque) else {
            throw PetalwheelError(l: "The PDF page is too large to render.")
        }
        if opaque {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        guard let img = ctx.makeImage() else { throw PetalwheelError(l: "Could not render the PDF page.") }
        return img
    }

    /// pdf → png/jpg, one file per page. Multi-page output goes into "<name> pages".
    static func renderPages(_ source: URL, format: FileFormat, quality: Double,
                            progress: @escaping ProgressHandler) async throws -> [URL] {
        let doc = try open(source)
        let count = doc.pageCount
        guard count > 0 else { throw PetalwheelError(l: "%@ has no pages.", source.lastPathComponent) }
        let name = ImageCodec.baseName(source)
        var outputs: [URL] = []
        if count == 1, let page = doc.page(at: 0) {
            let img = try render(page)
            let out = OutputNaming.url(for: source, ext: format.fileExtension)
            try await ImageCodec.write(img, to: out, format: format, quality: quality)
            progress(1)
            return [out]
        }
        let folder = try ImageCodec.uniqueFolder(near: source, name: "\(name) pages")
        let digits = String(count).count
        do {
            for i in 0..<count {
                try Task.checkCancellation()
                guard let page = doc.page(at: i) else { continue }
                let img = try autoreleasepool { try render(page) }
                let num = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
                let out = OutputNaming.url(named: "\(name)-\(num)", ext: format.fileExtension, in: folder)
                try await ImageCodec.write(img, to: out, format: format, quality: quality)
                outputs.append(out)
                progress(Double(i + 1) / Double(count))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return outputs
    }

    // MARK: Merge / split

    static func merge(_ inputs: [URL], progress: @escaping ProgressHandler) throws -> URL {
        let result = PDFDocument()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let doc = try open(url)
            for p in 0..<doc.pageCount {
                if let page = doc.page(at: p)?.copy() as? PDFPage {
                    result.insert(page, at: result.pageCount)
                }
            }
            progress(Double(i + 1) / Double(inputs.count) * 0.9)
        }
        let out = OutputNaming.url(named: "Merged", ext: "pdf", in: inputs[0].deletingLastPathComponent())
        guard result.write(to: out) else { throw PetalwheelError(l: "Could not write %@.", out.lastPathComponent) }
        progress(1)
        return out
    }

    static func split(_ source: URL, progress: @escaping ProgressHandler) throws -> [URL] {
        let doc = try open(source)
        let count = doc.pageCount
        guard count > 1 else { throw PetalwheelError(l: "%@ has only one page.", source.lastPathComponent) }
        let name = ImageCodec.baseName(source)
        let folder = try ImageCodec.uniqueFolder(near: source, name: "\(name) pages")
        let digits = String(count).count
        var outputs: [URL] = []
        for i in 0..<count {
            try Task.checkCancellation()
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let num = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            let out = OutputNaming.url(named: "\(name)-\(num)", ext: "pdf", in: folder)
            guard single.write(to: out) else { throw PetalwheelError(l: "Could not write %@.", out.lastPathComponent) }
            outputs.append(out)
            progress(Double(i + 1) / Double(count))
        }
        return outputs
    }

    // MARK: Compress

    /// Tries several strategies and keeps the smallest result. Returns nil if nothing beat the original.
    static func compress(_ source: URL, quality: Quality, progress: @escaping ProgressHandler) async throws -> URL? {
        let doc = try open(source)
        let original = ImageCodec.fileSize(source)
        let tmp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var candidates: [URL] = []

        // 1. PDFKit: re-encode embedded images as JPEG, downsampled for screen (compact/balanced).
        let a = tmp.appendingPathComponent("a.pdf")
        var opts: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
        if quality != .high { opts[.optimizeImagesForScreenOption] = true }
        if doc.write(to: a, withOptions: opts) { candidates.append(a) }
        progress(0.3)

        // 2. Quartz "Reduce File Size" filter (aggressive) for compact.
        if quality == .compact,
           let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")),
           let doc2 = PDFDocument(url: source) {
            let b = tmp.appendingPathComponent("b.pdf")
            if doc2.write(to: b, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) {
                candidates.append(b)
            }
        }
        progress(0.6)

        // 3. Scanned documents (pages that are just images): re-render pages as JPEG.
        if isMostlyImages(doc) {
            let c = tmp.appendingPathComponent("c.pdf")
            let scale: CGFloat = quality == .compact ? 1.5 : (quality == .balanced ? 2 : 2.5)
            let q = ImageCodec.quality(quality)
            if let ctx = CGContext(c as CFURL, mediaBox: nil, nil) {
                for i in 0..<doc.pageCount {
                    try Task.checkCancellation()
                    guard let page = doc.page(at: i) else { continue }
                    let img = try render(page, scale: scale)
                    let data = try ImageCodec.encode(img, format: .jpg, quality: q)
                    guard let provider = CGDataProvider(data: data as CFData),
                          let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                    else { continue }
                    let b = page.bounds(for: .cropBox)
                    var box = page.rotation % 180 != 0 ? CGRect(x: 0, y: 0, width: b.height, height: b.width) : CGRect(origin: .zero, size: b.size)
                    ctx.beginPage(mediaBox: &box)
                    ctx.draw(jpeg, in: box)
                    ctx.endPage()
                }
                ctx.closePDF()
                if PDFDocument(url: c)?.pageCount == doc.pageCount { candidates.append(c) }
            }
        }
        progress(0.9)

        let best = candidates
            .filter { PDFDocument(url: $0)?.pageCount == doc.pageCount }
            .min { ImageCodec.fileSize($0) < ImageCodec.fileSize($1) }
        guard let best, ImageCodec.fileSize(best) < original * 97 / 100 else { return nil }
        let out = OutputNaming.url(for: source, ext: "pdf", suffix: "compressed")
        try FileManager.default.copyItem(at: best, to: out)
        progress(1)
        return out
    }

    /// True when the document has (almost) no text — e.g. a scan.
    static func isMostlyImages(_ doc: PDFDocument) -> Bool {
        let pages = min(doc.pageCount, 10)
        guard pages > 0 else { return false }
        var chars = 0
        for i in 0..<pages { chars += doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0 }
        return chars < 20 * pages
    }

    // MARK: Metadata

    static func stripMetadata(_ source: URL) throws -> URL {
        let doc = try open(source)
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "",
            PDFDocumentAttribute.authorAttribute: "",
            PDFDocumentAttribute.subjectAttribute: "",
            PDFDocumentAttribute.creatorAttribute: "",
            PDFDocumentAttribute.producerAttribute: "",
            PDFDocumentAttribute.keywordsAttribute: [String](),
        ]
        let out = OutputNaming.url(for: source, ext: "pdf", suffix: "clean")
        guard doc.write(to: out) else { throw PetalwheelError(l: "Could not write %@.", out.lastPathComponent) }
        return out
    }

    // MARK: Text

    /// Embedded text layer of a page, if any.
    static func text(of page: PDFPage) -> String? {
        guard let s = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 20 else { return nil }
        return s
    }
}
