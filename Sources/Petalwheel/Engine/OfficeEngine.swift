import AppKit
import PDFKit

/// Microsoft Office formats that DocumentEngine / SpreadsheetEngine don't read, without Java or LibreOffice:
/// - pptx → pdf / png / jpg: Quick Look's Office generator renders slides to HTML; WebKit prints each slide to a PDF page.
/// - doc → document formats: textutil reads Word 97–2004 files; DocumentEngine does the rest.
/// - xls → xlsx / csv / tsv / html / pdf: Quick Look renders each sheet to an HTML table.
/// Legacy .ppt has no system renderer on macOS, so it isn't supported.
struct OfficeEngine: ConversionEngine {
    static let targets: [FileFormat: Set<FileFormat>] = [
        .pptx: [.pdf, .png, .jpg],
        .doc: [.pdf, .docx, .odt, .rtf, .rtfd, .html, .md, .txt],
        .xls: [.xlsx, .csv, .tsv, .html, .pdf],
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
        switch from {
        case .pptx: return try await convertPresentation(source, to: target, temp: temp, progress: progress)
        case .doc: return try await convertWordDoc(source, to: target, temp: temp, options: options, progress: progress)
        case .xls: return try await convertLegacySpreadsheet(source, to: target, temp: temp, progress: progress)
        default: throw PetalwheelError(l: "Can't convert %@ to %@.", from.title, target.title)
        }
    }

    // MARK: - PowerPoint

    private func convertPresentation(_ source: URL, to target: FileFormat, temp: URL,
                                     progress: @escaping ProgressHandler) async throws -> [URL] {
        let pdf = target == .pdf ? OutputNaming.url(for: source, ext: "pdf") : temp.appendingPathComponent("slides.pdf")
        try await Self.renderSlides(source, to: pdf, temp: temp) { p in progress(0.05 + (target == .pdf ? 0.95 : 0.6) * p) }
        if target == .pdf { progress(1); return [pdf] }
        return try OfficeSupport.rasterizePages(of: pdf, source: source, format: target) { p in progress(0.65 + 0.35 * p) }
    }

    /// Renders every slide of a pptx into one PDF page each, at the slide's own size.
    static func renderSlides(_ source: URL, to output: URL, temp: URL, progress: @escaping (Double) -> Void) async throws {
        let preview = try await OfficeSupport.quickLookPreview(of: source, in: temp)
        progress(0.3)
        let html = preview.appendingPathComponent("Preview.html")
        OfficeSupport.addFontFallbacks(toHTMLFiles: [html])
        let title = source.deletingPathExtension().lastPathComponent
        try await renderSlidesOnMain(html: html, root: preview, output: output, title: title, progress: progress)
    }

    @MainActor
    private static func renderSlidesOnMain(html: URL, root: URL, output: URL, title: String,
                                           progress: @escaping (Double) -> Void) async throws {
        let renderer = OfficeWebRenderer(width: 1000)
        let css = """
            html, body { background: #fff !important; margin: 0 !important; padding: 0 !important; }
            div.slide { margin: 0 !important; -webkit-box-shadow: none !important; box-shadow: none !important; }
            div.loading-slide { display: none !important; }
            """
        try await renderer.load(html, readAccess: root, extraCSS: css)
        // Slides are absolutely positioned children of div.slide; the first child carries the slide size.
        let measure = """
            JSON.stringify(Array.from(document.querySelectorAll('div.slide')).map(function(s){
              var r = s.getBoundingClientRect(), w = r.width, h = r.height;
              for (var c = s.firstElementChild; c; c = c.nextElementSibling) {
                var cr = c.getBoundingClientRect();
                if (cr.left - r.left < 1 && cr.top - r.top < 1 && cr.width > 50 && cr.height > 50) { w = cr.width; h = cr.height; break; }
              }
              return [r.left + window.scrollX, r.top + window.scrollY, w, h];
            }))
            """
        let rects = try await renderer.evaluateJSON(measure, as: [[Double]].self)
        guard !rects.isEmpty else { throw PetalwheelError(l: "Quick Look found no slides in “%@”.", title) }
        progress(0.4)
        // Show one slide at a time so each is rendered at the top of the page.
        let merged = PDFDocument()
        for (i, r) in rects.enumerated() {
            try Task.checkCancellation()
            _ = try await renderer.evaluate("""
                document.querySelectorAll('div.slide').forEach(function(s, j){ s.style.display = (j === \(i)) ? '' : 'none'; });
                window.scrollTo(0, 0); 1
                """)
            let size = CGSize(width: max(1, r[2]), height: max(1, r[3]))
            try await renderer.resize(to: size)
            let data = try await renderer.pdfPage(CGRect(origin: .zero, size: size))
            if let doc = PDFDocument(data: data), let page = doc.page(at: 0) { merged.insert(page, at: merged.pageCount) }
            progress(0.4 + 0.6 * Double(i + 1) / Double(rects.count))
        }
        guard merged.pageCount > 0 else { throw PetalwheelError(l: "Nothing was rendered.") }
        merged.documentAttributes = [PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "Petalwheel"]
        guard merged.write(to: output) else { throw PetalwheelError(l: "Couldn't write “%@”.", output.lastPathComponent) }
    }

    // MARK: - Word 97–2004

    private func convertWordDoc(_ source: URL, to target: FileFormat, temp: URL, options: ConversionOptions,
                                progress: @escaping ProgressHandler) async throws -> [URL] {
        let rtfd = try await Self.wordDocToRTFD(source, temp: temp)
        progress(0.3)
        if target == .rtfd {
            let out = OutputNaming.url(for: source, ext: "rtfd")
            try FileManager.default.moveItem(at: rtfd, to: out)
            progress(1)
            return [out]
        }
        return try await OfficeSupport.convertIntermediate(rtfd, format: .rtfd, to: target, original: source,
                                                           temp: temp, options: options) { p in progress(0.3 + 0.7 * p) }
    }

    /// textutil reads .doc natively; RTFD keeps the embedded pictures.
    static func wordDocToRTFD(_ source: URL, temp: URL) async throws -> URL {
        let rtfd = temp.appendingPathComponent("\(UUID().uuidString).rtfd")
        do {
            try await ProcessRunner.run(OfficeSupport.textutil, ["-convert", "rtfd", "-output", rtfd.path, source.path])
        } catch let e as ProcessError {
            throw PetalwheelError(l: "Couldn't read “%@”: %@", source.lastPathComponent, e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard FileManager.default.fileExists(atPath: rtfd.path) else {
            throw PetalwheelError(l: "Couldn't read “%@” as a Word document.", source.lastPathComponent)
        }
        return rtfd
    }

    // MARK: - Excel 97–2004

    struct SheetPage { let name: String; let html: URL }

    private func convertLegacySpreadsheet(_ source: URL, to target: FileFormat, temp: URL,
                                          progress: @escaping ProgressHandler) async throws -> [URL] {
        let preview = try await OfficeSupport.quickLookPreview(of: source, in: temp)
        progress(0.3)
        let pages = Self.sheetPages(in: preview, fallbackName: source.deletingPathExtension().lastPathComponent)
        OfficeSupport.addFontFallbacks(toHTMLFiles: pages.map(\.html))
        let baseName = source.deletingPathExtension().lastPathComponent

        if target == .pdf {
            let out = OutputNaming.url(for: source, ext: "pdf")
            var parts: [URL] = []
            for (i, page) in pages.enumerated() {
                let part = temp.appendingPathComponent("sheet-\(i).pdf")
                if try await Self.printSheet(page.html, root: preview, to: part) { parts.append(part) }
                progress(0.3 + 0.6 * Double(i + 1) / Double(pages.count))
            }
            guard !parts.isEmpty else { throw PetalwheelError(l: "“%@” has no data.", source.lastPathComponent) }
            try OfficeSupport.mergePDFs(parts, to: out, title: baseName)
            progress(1)
            return [out]
        }

        var sheets: [SpreadsheetSheet] = []
        for (i, page) in pages.enumerated() {
            let rows = try await Self.readSheet(page.html, root: preview)
            var sheet = SpreadsheetSheet(name: page.name, rows: rows.map { row in
                row.map { cell in
                    // xlsx keeps numbers as numbers; Quick Look shows them formatted for the user's locale.
                    if target == .xlsx, cell.numeric, let plain = Self.plainNumber(cell.text) { return SpreadsheetCell(plain, kind: .number) }
                    return SpreadsheetCell(cell.text, kind: target == .xlsx ? .text : .auto)
                }
            })
            sheet.trim()
            sheets.append(sheet)
            progress(0.3 + 0.5 * Double(i + 1) / Double(pages.count))
        }
        if sheets.count > 1 { sheets.removeAll { $0.rows.isEmpty } }
        guard sheets.contains(where: { !$0.rows.isEmpty }) else { throw PetalwheelError(l: "“%@” has no data.", source.lastPathComponent) }

        switch target {
        case .xlsx:
            let out = OutputNaming.url(for: source, ext: "xlsx")
            try await SpreadsheetXLSX.write(sheets, to: out)
            progress(1)
            return [out]
        case .html:
            let out = OutputNaming.url(for: source, ext: "html")
            try SpreadsheetEngine.html(sheets, title: baseName).write(to: out, atomically: true, encoding: .utf8)
            progress(1)
            return [out]
        default:
            let delimiter: Character = target == .csv ? "," : "\t"
            var outputs: [URL] = []
            for sheet in sheets {
                let out = sheets.count == 1
                    ? OutputNaming.url(for: source, ext: target.rawValue)
                    : OutputNaming.url(named: "\(baseName) - \(SpreadsheetEngine.fileSafe(sheet.name))", ext: target.rawValue,
                                       in: source.deletingLastPathComponent())
                var data = Data([0xEF, 0xBB, 0xBF])
                data.append(Data(SpreadsheetCSV.write(sheet.rows.map { $0.map(\.value) }, delimiter: delimiter).utf8))
                try data.write(to: out)
                outputs.append(out)
            }
            progress(1)
            return outputs
        }
    }

    /// Quick Look writes a tab bar (Preview.html) with one HTML file per sheet; single-sheet
    /// workbooks have the table in Preview.html itself.
    static func sheetPages(in preview: URL, fallbackName: String) -> [SheetPage] {
        let main = preview.appendingPathComponent("Preview.html")
        guard let html = try? String(contentsOf: main, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #"<div class="TabHeader">([\s\S]*?)</div>\s*<a href="([^"]+)""#) else {
            return [SheetPage(name: fallbackName, html: main)]
        }
        let ns = html as NSString
        let pages: [SheetPage] = re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let name = decodeEntities(ns.substring(with: m.range(at: 1)))
            guard let file = OfficeSupport.containedFile(ns.substring(with: m.range(at: 2)), in: preview) else { return nil }
            return SheetPage(name: name.isEmpty ? fallbackName : name, html: file)
        }
        return pages.isEmpty ? [SheetPage(name: fallbackName, html: main)] : pages
    }

    /// Decodes the few HTML entities Quick Look emits in sheet names.
    static func decodeEntities(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        guard out.contains("&") else { return out.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                if let code = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct SheetCell: Decodable { let text: String; let numeric: Bool }

    @MainActor
    static func readSheet(_ html: URL, root: URL) async throws -> [[SheetCell]] {
        let renderer = OfficeWebRenderer(width: 1200)
        try await renderer.load(html, readAccess: root)
        // Expand colspans so columns stay aligned; right-aligned cells are numbers in Quick Look's output.
        return try await renderer.evaluateJSON("""
            JSON.stringify(Array.from(document.querySelectorAll('table.worksheet tr, table:not(.worksheet) tr')).map(function(tr){
              var out = [];
              Array.from(tr.cells).forEach(function(td){
                var t = (td.innerText || '').replace(/\\u00a0/g, ' ').replace(/\\s+$/, '');
                out.push({text: t, numeric: getComputedStyle(td).textAlign === 'right'});
                for (var i = 1; i < (td.colSpan || 1); i++) out.push({text: '', numeric: false});
              });
              return out;
            }))
            """, as: [[SheetCell]].self)
    }

    /// Prints one sheet; returns false when it is empty.
    @MainActor
    static func printSheet(_ html: URL, root: URL, to output: URL) async throws -> Bool {
        let renderer = OfficeWebRenderer(width: 760)
        // Quick Look draws gridlines only on screen; keep them in print.
        let css = """
            html, body { background: #fff !important; }
            .showGridlines, .showGridlines td, .showGridlines th { border: 0.5px solid #c8c8d0 !important; }
            """
        try await renderer.load(html, readAccess: root, extraCSS: css)
        let hasText = try await renderer.evaluate("(document.body && document.body.innerText.trim().length > 0) ? 1 : 0") as? Int ?? 1
        if hasText == 0 { return false }
        let size = try await renderer.contentSize()
        // The view is wider than the sheet; measure the tables themselves to pick the orientation.
        let tableWidth = try await renderer.evaluate(
            "Math.max(0, ...Array.from(document.querySelectorAll('table')).map(function(t){ return t.getBoundingClientRect().right; }))"
        ) as? Double ?? Double(size.width)
        let width = CGFloat(tableWidth > 0 ? tableWidth : Double(size.width))
        let a4 = DocumentEngine.pageSize
        let margin: CGFloat = 36
        // Wide sheets go landscape; still wider ones are scaled to the page width.
        let landscape = width > a4.width - 2 * margin
        let paper = landscape ? CGSize(width: a4.height, height: a4.width) : a4
        try await renderer.resize(to: CGSize(width: max(width, paper.width - 2 * margin), height: max(size.height, 200)))
        try await renderer.printPDF(to: output, paperSize: paper, margin: margin, fitWidth: width > paper.width - 2 * margin)
        return true
    }

    /// "1 234,5" / "1,234.5" (locale formatted) → "1234.5"; nil if not a plain number.
    static func plainNumber(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 24 else { return nil }
        if SpreadsheetCell.looksNumeric(t) { return t }
        let f = NumberFormatter()
        f.locale = Locale.current
        f.numberStyle = .decimal
        guard let n = f.number(from: t.replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")) else { return nil }
        let s = n.stringValue
        return SpreadsheetCell.looksNumeric(s) ? s : nil
    }
}

