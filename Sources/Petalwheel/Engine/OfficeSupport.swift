import AppKit
import PDFKit

/// Shared helpers for the Office / iWork / EPUB engines: Quick Look HTML previews, PDF merging,
/// page rasterizing and running DocumentEngine on intermediate files.
enum OfficeSupport {
    static let qlmanage = URL(fileURLWithPath: "/usr/bin/qlmanage")
    static let textutil = URL(fileURLWithPath: "/usr/bin/textutil")
    static let zip = URL(fileURLWithPath: "/usr/bin/zip")
    static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")

    // MARK: - Quick Look

    /// Asks Quick Look for an HTML preview (`qlmanage -p -o`). The system Office generator renders
    /// docx/doc/pptx/xlsx/xls to HTML; the iWork generator produces one vector PDF per page/slide.
    /// Returns the `.qlpreview` directory containing `Preview.html` and its attachments.
    static func quickLookPreview(of source: URL, in temp: URL, timeout: Double = 120) async throws -> URL {
        let out = temp.appendingPathComponent("ql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let args = ["-p", "-o", out.path, source.path]
        do {
            _ = try await withTimeout(timeout, L("Quick Look took too long to render “%@”.", source.lastPathComponent)) {
                try await ProcessRunner.run(qlmanage, args)
            }
        } catch let e as ProcessError {
            throw NurToError(l: "Quick Look couldn't render “%@”: %@", source.lastPathComponent, e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard let preview = items.first(where: { $0.pathExtension == "qlpreview" }),
              FileManager.default.fileExists(atPath: preview.appendingPathComponent("Preview.html").path) else {
            throw NurToError(l: "macOS can't preview “%@”, so NurTo can't convert it.", source.lastPathComponent)
        }
        return preview
    }

    /// Runs `op`, throwing `message` if it doesn't finish within `seconds` (the op is cancelled).
    static func withTimeout<T>(_ seconds: Double, _ message: String,
                               _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: Box<T>?.self) { group in
            group.addTask { Box(try await op()) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let box = first else { throw NurToError(message) }
            return box.value
        }
    }

    final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// `src="…"` values of `<img>` tags in document order.
    static func imageSources(inHTML html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Resolves a relative reference inside `dir`; nil when it escapes the directory or doesn't exist.
    static func containedFile(_ ref: String, in dir: URL) -> URL? {
        let decoded = ref.removingPercentEncoding ?? ref
        guard !decoded.contains("://"), !decoded.hasPrefix("/") else { return nil }
        let url = dir.appendingPathComponent(decoded).standardizedFileURL
        let root = dir.standardizedFileURL.path
        guard url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Quick Look names the document's fonts without fallbacks; when one isn't installed WebKit
    /// falls back to Times. Office documents are mostly set in sans-serif fonts, so fall back to those.
    static func addFontFallbacks(toHTMLFiles files: [URL]) {
        guard let re = try? NSRegularExpression(pattern: #"font-family:\s*("[^"]*"|[^;"}<>]+)"#, options: [.caseInsensitive]) else { return }
        for file in files {
            guard let html = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let ns = html as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let value = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let lower = value.lowercased()
                let generic = ["serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui"].contains { lower.hasSuffix($0) }
                let serifFont = ["times", "georgia", "cambria", "garamond", "palatino", "book antiqua", "minion"].contains { lower.contains($0) }
                let monoFont = ["courier", "consolas", "menlo", "mono"].contains { lower.contains($0) }
                let fallback = monoFont ? "Menlo, monospace" : serifFont ? "\"Times New Roman\", serif" : "\"Helvetica Neue\", Arial, sans-serif"
                out += generic ? ns.substring(with: m.range) : "font-family:\(value), \(fallback)"
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            try? out.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - PDF

    /// Concatenates the pages of `inputs` into one PDF.
    static func mergePDFs(_ inputs: [URL], to output: URL, title: String) throws {
        let merged = PDFDocument()
        for input in inputs {
            guard let doc = PDFDocument(url: input) else { continue }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard merged.pageCount > 0 else { throw NurToError(l: "Nothing to render: the document has no pages.") }
        merged.documentAttributes = [PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "NurTo"]
        guard merged.write(to: output) else { throw NurToError(l: "Couldn't write “%@”.", output.lastPathComponent) }
    }

    /// Renders every page of `pdf` to PNG/JPEG files ("<base> 01.png", …) inside a new folder
    /// next to `source`. Pages are rasterized to at least `minWidth` pixels wide.
    static func rasterizePages(of pdf: URL, source: URL, format: FileFormat, minWidth: CGFloat = 1920,
                               progress: (Double) -> Void) throws -> [URL] {
        guard let doc = CGPDFDocument(pdf as CFURL), doc.numberOfPages > 0 else {
            throw NurToError(l: "Couldn't read the rendered slides.")
        }
        let base = source.deletingPathExtension().lastPathComponent
        let folder = OutputNaming.unique(source.deletingLastPathComponent().appendingPathComponent("\(base) (\(format.title))"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let count = doc.numberOfPages
        let digits = max(2, String(count).count)
        do {
            for index in 1...count {
                try Task.checkCancellation()
                guard let page = doc.page(at: index) else { continue }
                let box = page.getBoxRect(.cropBox)
                let scale = max(1, minWidth / max(box.width, 1))
                let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
                guard width > 0, height > 0,
                      let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.interpolationQuality = .high
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -box.minX, y: -box.minY)
                ctx.drawPDFPage(page)
                guard let image = ctx.makeImage() else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let data = format == .jpg
                    ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                    : rep.representation(using: .png, properties: [:])
                let number = String(repeating: "0", count: max(0, digits - String(index).count)) + String(index)
                try data?.write(to: folder.appendingPathComponent("\(base) \(number).\(format.fileExtension)"))
                progress(Double(index) / Double(count))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return [folder]
    }

    // MARK: - DocumentEngine on intermediate files

    /// Converts an intermediate file (HTML, RTFD, PDF…) with DocumentEngine and moves the results
    /// next to `original`, named after it. Extra outputs (Markdown image folders) move along.
    static func convertIntermediate(_ intermediate: URL, format: FileFormat, to target: FileFormat,
                                    original: URL, temp: URL, options: ConversionOptions,
                                    progress: @escaping ProgressHandler) async throws -> [URL] {
        let final = OutputNaming.url(for: original, ext: target.fileExtension)
        let base = final.deletingPathExtension().lastPathComponent
        // A private directory so DocumentEngine's outputs can't collide with anything else.
        let work = temp.appendingPathComponent("doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let input = work.appendingPathComponent(base).appendingPathExtension(intermediate.pathExtension)
        try FileManager.default.copyItem(at: intermediate, to: input)
        let engine = DocumentEngine()
        guard engine.canConvert(from: format, to: target) else {
            throw NurToError(l: "Can't convert %@ to %@.", format.title, target.title)
        }
        let produced = try await engine.convert(input, from: format, to: target, options: options, progress: progress)
        return try relocate(produced, primary: final)
    }

    /// Moves DocumentEngine outputs into the destination folder. The primary output gets `primary`'s
    /// name; renamed side folders are re-linked in Markdown.
    static func relocate(_ produced: [URL], primary: URL) throws -> [URL] {
        let fm = FileManager.default
        let destDir = primary.deletingLastPathComponent()
        var results: [URL] = []
        var renames: [(String, String)] = []
        var primaryURL: URL?
        for (i, url) in produced.enumerated() {
            let dest = i == 0 ? OutputNaming.unique(primary)
                              : OutputNaming.unique(destDir.appendingPathComponent(url.lastPathComponent))
            if i > 0, dest.lastPathComponent != url.lastPathComponent {
                renames.append((url.lastPathComponent, dest.lastPathComponent))
            }
            try fm.moveItem(at: url, to: dest)
            if i == 0 { primaryURL = dest }
            results.append(dest)
        }
        if let md = primaryURL, md.pathExtension == "md", !renames.isEmpty,
           var text = try? String(contentsOf: md, encoding: .utf8) {
            for (old, new) in renames {
                text = text.replacingOccurrences(of: "(\(old)/", with: "(\(new)/")
                text = text.replacingOccurrences(of: "(<\(old)/", with: "(<\(new)/")
                let encOld = old.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? old
                let encNew = new.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? new
                text = text.replacingOccurrences(of: "(\(encOld)/", with: "(\(encNew)/")
            }
            try text.write(to: md, atomically: true, encoding: .utf8)
        }
        return results
    }
}
