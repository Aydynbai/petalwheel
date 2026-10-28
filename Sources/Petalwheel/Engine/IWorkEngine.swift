import AppKit
import PDFKit

/// Keynote / Pages / Numbers → PDF (and slide images, and text formats for Pages) without the iWork apps.
/// 1. iWork '09 documents embed a full `QuickLook/Preview.pdf`: use it as is.
/// 2. Current documents only embed a first-page `preview.jpg`, so ask the system iWork Quick Look
///    generator (`qlmanage -p -o`), which writes one vector PDF per page / slide / sheet, and merge them.
struct IWorkEngine: ConversionEngine {
    static let targets: [FileFormat: Set<FileFormat>] = [
        .key: [.pdf, .png, .jpg],
        .pages: [.pdf, .docx, .rtf, .html, .md, .txt],
        .numbers: [.pdf],
    ]

    init() {}

    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        Self.targets[source]?.contains(target) ?? false
    }

    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL] {
        guard canConvert(from: from, to: target) else {
            throw PetalwheelError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
        let temp = try OutputNaming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        progress(0.02)
        let title = source.deletingPathExtension().lastPathComponent
        let pdf = target == .pdf ? OutputNaming.url(for: source, ext: "pdf") : temp.appendingPathComponent("\(title).pdf")
        try await Self.renderPDF(source, to: pdf, temp: temp)
        progress(0.6)
        switch target {
        case .pdf:
            progress(1)
            return [pdf]
        case .png, .jpg:
            return try OfficeSupport.rasterizePages(of: pdf, source: source, format: target) { p in progress(0.6 + 0.4 * p) }
        default:
            return try await OfficeSupport.convertIntermediate(pdf, format: .pdf, to: target, original: source,
                                                               temp: temp, options: options) { p in progress(0.6 + 0.4 * p) }
        }
    }

    static func renderPDF(_ source: URL, to output: URL, temp: URL) async throws {
        let title = source.deletingPathExtension().lastPathComponent
        if let embedded = try await embeddedPreviewPDF(source, temp: temp) {
            try OfficeSupport.mergePDFs([embedded], to: output, title: title)
            return
        }
        let preview: URL
        do {
            preview = try await OfficeSupport.quickLookPreview(of: source, in: temp)
        } catch {
            throw PetalwheelError(l: "macOS couldn't render “%@”. Open it in %@ and export it instead.", source.lastPathComponent, FileFormat.detect(source)?.title ?? L("its app"))
        }
        let html = (try? String(contentsOf: preview.appendingPathComponent("Preview.html"), encoding: .utf8)) ?? ""
        let pages = OfficeSupport.imageSources(inHTML: html).compactMap { OfficeSupport.containedFile($0, in: preview) }
        let pdfs = pages.filter { $0.pathExtension.lowercased() == "pdf" }
        if !pdfs.isEmpty {
            try OfficeSupport.mergePDFs(pdfs, to: output, title: title)
            return
        }
        // Some previews are bitmaps: one PDF page per image.
        let images = pages.compactMap { NSImage(contentsOf: $0) }
        guard !images.isEmpty else { throw PetalwheelError(l: "Quick Look returned no pages for “%@”.", source.lastPathComponent) }
        let doc = PDFDocument()
        for image in images { if let page = PDFPage(image: image) { doc.insert(page, at: doc.pageCount) } }
        guard doc.write(to: output) else { throw PetalwheelError(l: "Couldn't write “%@”.", output.lastPathComponent) }
    }

    /// `QuickLook/Preview.pdf` inside a package directory or a single-file (zip) document.
    static func embeddedPreviewPDF(_ source: URL, temp: URL) async throws -> URL? {
        let member = "QuickLook/Preview.pdf"
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
        if isDir.boolValue {
            let pdf = source.appendingPathComponent(member)
            return PDFDocument(url: pdf).map { _ in pdf }
        }
        guard let listing = try? await ProcessRunner.run(OfficeSupport.unzip, ["-Z1", source.path]),
              listing.stdout.split(separator: "\n").contains(where: { $0 == member }) else { return nil }
        let dir = temp.appendingPathComponent("embedded")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try? await ProcessRunner.run(OfficeSupport.unzip, ["-qq", "-o", source.path, member, "-d", dir.path])
        let pdf = dir.appendingPathComponent(member)
        return PDFDocument(url: pdf).map { _ in pdf }
    }
}
