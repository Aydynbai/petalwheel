import Foundation
import PDFKit

/// Converts and processes the contents of folders (and mixed selections of folders and files).
///
/// - Per-file operations (convert, compress, strip metadata) mirror each dropped folder into a sibling
///   "<name> (converted)" / "(compressed)" / "(clean)" folder with the same subfolders. Only matching files
///   are written there. Each file is processed on an APFS clone inside a hidden work folder, so the source
///   folder is never written to. Loose files in a mixed selection are processed next to themselves.
/// - Combined operations (one PDF, collage, OCR text, report) take the union of all files, in natural order.
/// - Flatten copies every file of a folder into "<name> (flat)" with collision-safe names.
///
/// Files run in parallel (bounded by the "Parallel jobs" setting); progress covers all files and the task's
/// cancellation stops the remaining files and removes partial output folders.
struct FolderToolsModule: ToolModule {
    var engines: [ConversionEngine] = []
    var conversion = ConversionOptions()
    /// Max files processed at once; nil = the "Parallel jobs" setting.
    var concurrency: Int? = nil

    /// Collages beyond this many images become unreadable (and huge).
    static let maxCollageImages = 100

    func canRun(_ tool: FileTool, format: FileFormat?) -> Bool {
        format == nil && FolderCatalog.folderTools.contains(tool)
    }

    func run(_ tool: FileTool, inputs: [URL], options: ToolOptions,
             progress: @escaping ProgressHandler) async throws -> ToolResult {
        let scan = try Self.prepare(inputs)
        switch tool {
        case .compress, .removeMetadata:
            let modules: [ToolModule] = [ImageToolsModule(), MediaToolsModule()]
            let step = MirrorStep(keepSourceName: true, copyWhenNoOutput: tool == .compress, copyAsIs: { _ in false }) { input, p in
                let format = FileFormat.detect(input)
                guard let module = modules.first(where: { $0.canRun(tool, format: format) }) else {
                    throw PetalwheelError(l: "%@ isn't available for %@.", tool.title, input.lastPathComponent)
                }
                return try await module.run(tool, inputs: [input], options: options, progress: p).outputs
            }
            return try await runMirrored(scan, entries: FolderCatalog.toolInputs(tool, scan: scan),
                                         suffix: tool == .compress ? "compressed" : "clean", step: step, progress: progress)
        case .createPDF:
            return try makePDF(scan, progress: progress)
        case .createCollage:
            return try makeCollage(scan, options: options, progress: progress)
        case .recognizeText:
            return try await recognizeText(scan, progress: progress)
        case .flattenFolder:
            return try flatten(scan, progress: progress)
        case .folderReport:
            progress(1)
            return ToolResult(messages: Self.report(scan, inputs: inputs))
        default:
            throw PetalwheelError(l: "%@ isn't available for folders.", tool.title)
        }
    }

    /// Converts the files inside the selection to `target` ("Images → JPG" etc., see `FolderCatalog`).
    func convert(_ inputs: [URL], to target: FileFormat, progress: @escaping ProgressHandler) async throws -> ToolResult {
        let scan = try Self.prepare(inputs)
        let entries = FolderCatalog.convertSources(scan, to: target)
        guard entries.contains(where: { FolderCatalog.isConvertible($0, to: target) }) else {
            throw PetalwheelError(l: "Nothing in the selected folders can be converted to %@.", target.title)
        }
        let engines = self.engines
        let options = conversion
        let step = MirrorStep(keepSourceName: false, copyWhenNoOutput: false, copyAsIs: { $0.format == target }) { input, p in
            guard let source = FileFormat.detect(input) else {
                throw PetalwheelError(l: "Unsupported file type: %@", input.lastPathComponent)
            }
            guard let engine = engines.first(where: { $0.canConvert(from: source, to: target) }) else {
                throw PetalwheelError(l: "Can't convert %@ to %@", source.title, target.title)
            }
            return try await engine.convert(input, from: source, to: target, options: options, progress: p)
        }
        return try await runMirrored(scan, entries: entries, suffix: "converted", step: step, progress: progress)
    }

    // MARK: - Scanning

    static func prepare(_ inputs: [URL]) throws -> FolderScan {
        let scan = FolderCatalog.scan(inputs, isCancelled: { Task.isCancelled })
        try Task.checkCancellation()
        if scan.truncated {
            let limit = NumberFormatter.localizedString(from: NSNumber(value: FolderCatalog.maxFiles), number: .decimal)
            throw PetalwheelError(l: "The selection contains more than %@ files. Choose a smaller folder.", limit)
        }
        guard !scan.entries.isEmpty else { throw PetalwheelError(l: "The selected folders contain no files.") }
        return scan
    }

    /// Entries in natural order ("2.jpg" before "10.jpg"), folder by folder in the order they were dropped.
    static func naturalOrder(_ entries: [FolderEntry], scan: FolderScan) -> [FolderEntry] {
        let rootIndex = Dictionary(scan.roots.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return entries.sorted { a, b in
            let ra = a.root.flatMap { rootIndex[$0] } ?? -1, rb = b.root.flatMap { rootIndex[$0] } ?? -1
            if ra != rb { return ra < rb }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }
    }

    /// Name for a combined output: the folder's name, or the first folder's when several items were dropped.
    static func outputBase(_ scan: FolderScan, inputs: [URL]) -> String {
        if let root = scan.roots.first { return root.lastPathComponent }
        return inputs[0].deletingPathExtension().lastPathComponent
    }

    static func outputDirectory(_ inputs: [URL]) -> URL {
        inputs[0].standardizedFileURL.deletingLastPathComponent()
    }

    // MARK: - Mirrored per-file runs

    struct MirrorStep {
        /// Name outputs after the source ("photo (compressed).jpg" → "photo.jpg"): the mirror folder's
        /// name already says what happened.
        var keepSourceName: Bool
        /// Copy the original into the mirror when the step produced nothing (e.g. already compressed).
        var copyWhenNoOutput: Bool
        /// Entries copied unchanged instead of processed (files already in the target format).
        var copyAsIs: (FolderEntry) -> Bool
        /// Processes the file at the URL, writing next to it; returns what it created.
        var run: (URL, @escaping ProgressHandler) async throws -> [URL]
    }

    private func runMirrored(_ scan: FolderScan, entries: [FolderEntry], suffix: String, step: MirrorStep,
                             progress: @escaping ProgressHandler) async throws -> ToolResult {
        guard !entries.isEmpty else { throw PetalwheelError(l: "Nothing in the selected folders can be processed this way.") }
        let fm = FileManager.default
        let ordered = Self.naturalOrder(entries, scan: scan)
        var mirrors: [URL: URL] = [:]
        var work: [URL: URL] = [:]
        for root in scan.roots where ordered.contains(where: { $0.root == root }) {
            let dest = Self.uniqueFolder(root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent) (\(suffix))"))
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            mirrors[root] = dest
            let w = dest.appendingPathComponent(".petalwheel-work-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: w, withIntermediateDirectories: true)
            work[root] = w
        }
        defer { for w in work.values { try? fm.removeItem(at: w) } }

        let limit = concurrency ?? JobSettings.shared.limit(for: ordered.prefix(64).map(\.url))
        let results = await Self.parallel(count: ordered.count, limit: limit, progress: progress) { i, p in
            let e = ordered[i]
            return try await Self.process(e, mirror: e.root.flatMap { mirrors[$0] }, work: e.root.flatMap { work[$0] },
                                          step: step, progress: p)
        }
        for w in work.values { try? fm.removeItem(at: w) }
        if Task.isCancelled {
            for m in mirrors.values { try? fm.removeItem(at: m) }
            throw CancellationError()
        }

        var result = ToolResult()
        var firstError: Error?
        for (i, r) in results.enumerated() {
            switch r {
            case .success(let outs) where ordered[i].root == nil: result.outputs += outs
            case .success: break
            case .failure(let error):
                firstError = firstError ?? error
                result.messages.append("\(ordered[i].relativePath): \(error.localizedDescription)")
            }
        }
        // Mirror folders that received at least one file are the outputs; empty ones are removed.
        let mirrorOutputs = scan.roots.compactMap { mirrors[$0] }.filter { dest in
            let hasFiles = Self.containsFiles(dest)
            if !hasFiles { try? fm.removeItem(at: dest) }
            return hasFiles
        }
        result.outputs = mirrorOutputs + result.outputs
        if result.outputs.isEmpty, let firstError { throw firstError }
        progress(1)
        return result
    }

    private static func process(_ entry: FolderEntry, mirror: URL?, work: URL?, step: MirrorStep,
                                progress: @escaping ProgressHandler) async throws -> [URL] {
        let fm = FileManager.default
        guard let mirror, let work else {
            // Loose file: the usual behaviour, results next to it.
            if step.copyAsIs(entry) { return [] }
            return try await step.run(entry.url, progress)
        }
        let destDir = entry.relativeDir.isEmpty ? mirror : mirror.appendingPathComponent(entry.relativeDir, isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        if step.copyAsIs(entry) {
            progress(1)
            return [try place(entry.url, in: destDir, name: entry.url.lastPathComponent, copy: true)]
        }
        let sandbox = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }
        let input = sandbox.appendingPathComponent(entry.url.lastPathComponent)
        try fm.copyItem(at: entry.url, to: input)       // a clone on APFS: instant, no extra space
        let outputs = try await step.run(input, progress).filter { $0.standardizedFileURL != input.standardizedFileURL }
        if outputs.isEmpty {
            guard step.copyWhenNoOutput else { return [] }
            return [try place(entry.url, in: destDir, name: entry.url.lastPathComponent, copy: true)]
        }
        let base = entry.url.deletingPathExtension().lastPathComponent
        return try outputs.map { out in
            let name = step.keepSourceName && outputs.count == 1 && !out.pathExtension.isEmpty
                ? base + "." + out.pathExtension : out.lastPathComponent
            return try place(out, in: destDir, name: name, copy: false)
        }
    }

    private static let placeLock = NSLock()

    /// Moves (or copies) `item` into `dir` under `name`, or "name 2", "name 3"… when taken.
    /// Serialized so parallel files never race for the same name.
    @discardableResult
    static func place(_ item: URL, in dir: URL, name: String, copy: Bool) throws -> URL {
        placeLock.lock()
        defer { placeLock.unlock() }
        let target = uniqueName(name, in: dir)
        if copy { try FileManager.default.copyItem(at: item, to: target) } else { try FileManager.default.moveItem(at: item, to: target) }
        return target
    }

    static func uniqueName(_ name: String, in dir: URL, taken: Set<String> = []) -> URL {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = name
        var i = 2
        while taken.contains(candidate.lowercased()) || fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            i += 1
        }
        return dir.appendingPathComponent(candidate)
    }

    /// "Photos (converted)", or "Photos (converted) 2" when that exists.
    static func uniqueFolder(_ url: URL) -> URL {
        let fm = FileManager.default
        var candidate = url
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) \(i)", isDirectory: true)
            i += 1
        }
        return candidate
    }

    private static func containsFiles(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
            return true
        }
        return false
    }

    // MARK: - Parallel runner

    /// Overall progress across many files: each file contributes an equal share.
    final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var fractions: [Double]
        private let report: ProgressHandler
        private var lastReported = -1.0
        init(count: Int, report: @escaping ProgressHandler) {
            fractions = Array(repeating: 0, count: max(count, 1))
            self.report = report
        }
        func set(_ index: Int, _ value: Double) {
            lock.lock()
            fractions[index] = max(fractions[index], min(max(value, 0), 1))
            let total = fractions.reduce(0, +) / Double(fractions.count)
            let send = total - lastReported >= 0.002 || total >= 1
            if send { lastReported = total }
            lock.unlock()
            if send { report(total) }
        }
    }

    /// Runs `body` for indices 0..<count with at most `limit` at once; stops starting new ones when cancelled.
    static func parallel<T>(count: Int, limit: Int, progress: @escaping ProgressHandler,
                            body: @escaping (Int, @escaping ProgressHandler) async throws -> T) async -> [Result<T, Error>] {
        let tracker = ProgressTracker(count: count, report: progress)
        var results = [Result<T, Error>?](repeating: nil, count: count)
        await withTaskGroup(of: (Int, Result<T, Error>).self) { group in
            var next = 0
            var inFlight = 0
            while true {
                while next < count && inFlight < max(1, limit) && !Task.isCancelled {
                    let i = next
                    next += 1
                    inFlight += 1
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let value = try await body(i) { tracker.set(i, $0) }
                            tracker.set(i, 1)
                            return (i, .success(value))
                        } catch {
                            tracker.set(i, 1)
                            return (i, .failure(error))
                        }
                    }
                }
                guard let (i, r) = await group.next() else { break }
                inFlight -= 1
                results[i] = r
            }
        }
        return results.map { $0 ?? .failure(CancellationError()) }
    }

    // MARK: - Combined outputs

    private func makePDF(_ scan: FolderScan, progress: @escaping ProgressHandler) throws -> ToolResult {
        let images = Self.naturalOrder(FolderCatalog.toolInputs(.createPDF, scan: scan), scan: scan).map(\.url)
        guard !images.isEmpty else { throw PetalwheelError(l: "There are no images in the selected folders.") }
        let inputs = scan.roots.isEmpty ? images : scan.roots
        let out = OutputNaming.url(named: Self.outputBase(scan, inputs: inputs), ext: "pdf", in: Self.outputDirectory(inputs))
        do {
            try Self.writePDF(images, to: out, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return ToolResult(outputs: [out])
    }

    /// `ImageCodec.writePDF` with cancellation between pages (folders can hold thousands of images).
    static func writePDF(_ files: [URL], to url: URL, progress: @escaping ProgressHandler) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw PetalwheelError(l: "Could not create %@.", url.lastPathComponent)
        }
        for (i, file) in files.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let fmt = FileFormat.detect(file)
                if fmt == .jpg, let (raw, o) = ImageCodec.loadRaw(file) {
                    let swap = [.left, .leftMirrored, .right, .rightMirrored].contains(o)
                    var box = CGRect(x: 0, y: 0, width: swap ? raw.height : raw.width, height: swap ? raw.width : raw.height)
                    ctx.beginPage(mediaBox: &box)
                    ctx.concatenate(ImageCodec.orientationTransform(o, rawWidth: CGFloat(raw.width), rawHeight: CGFloat(raw.height)))
                    ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
                    ctx.endPage()
                } else {
                    let img = try ImageCodec.load(file, format: fmt).image
                    var box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
                    ctx.beginPage(mediaBox: &box)
                    ctx.interpolationQuality = .high
                    ctx.draw(ImageCodec.pdfFriendly(img), in: box)
                    ctx.endPage()
                }
            }
            progress(Double(i + 1) / Double(files.count))
        }
        ctx.closePDF()
    }

    private func makeCollage(_ scan: FolderScan, options: ToolOptions, progress: @escaping ProgressHandler) throws -> ToolResult {
        let all = Self.naturalOrder(FolderCatalog.toolInputs(.createCollage, scan: scan), scan: scan).map(\.url)
        guard all.count >= 2 else { throw PetalwheelError(l: "A collage needs at least two images.") }
        let images = Array(all.prefix(Self.maxCollageImages))
        let inputs = scan.roots.isEmpty ? images : scan.roots
        let dir = Self.outputDirectory(inputs)
        // The collage is written next to its first image: hand it a clone in a hidden work folder instead.
        let fm = FileManager.default
        let work = dir.appendingPathComponent(".petalwheel-work-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let first = work.appendingPathComponent(images[0].lastPathComponent)
        try fm.copyItem(at: images[0], to: first)
        let made = try ImageLayout.collage([first] + images.dropFirst(), options: options, progress: progress)
        let out = try Self.place(made, in: dir, name: "\(Self.outputBase(scan, inputs: inputs)) (collage).png", copy: false)
        var result = ToolResult(outputs: [out])
        if all.count > images.count {
            result.messages.append(Lp("Found %d images; the collage uses the first %d.", all.count, images.count))
        }
        return result
    }

    private func recognizeText(_ scan: FolderScan, progress: @escaping ProgressHandler) async throws -> ToolResult {
        let files = Self.naturalOrder(FolderCatalog.toolInputs(.recognizeText, scan: scan), scan: scan)
        guard !files.isEmpty else { throw PetalwheelError(l: "There are no images or PDFs in the selected folders.") }
        let limit = concurrency ?? min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        let texts = await Self.parallel(count: files.count, limit: limit, progress: progress) { i, p in
            try Self.text(of: files[i].url, progress: p)
        }
        try Task.checkCancellation()
        var sections: [String] = []
        var result = ToolResult()
        for (entry, r) in zip(files, texts) {
            switch r {
            case .success(let t) where !t.isEmpty: sections.append("=== \(entry.relativePath) ===\n\(t)")
            case .success: break
            case .failure(let error): result.messages.append("\(entry.relativePath): \(error.localizedDescription)")
            }
        }
        guard !sections.isEmpty else {
            result.messages.insert(L("No text found"), at: 0)
            return result
        }
        let inputs = scan.roots.isEmpty ? files.map(\.url) : scan.roots
        let out = OutputNaming.url(named: "\(Self.outputBase(scan, inputs: inputs)) (text)", ext: "txt", in: Self.outputDirectory(inputs))
        try (sections.joined(separator: "\n\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        result.outputs = [out]
        return result
    }

    /// Text of an image (OCR) or a PDF (text layer, OCR for scanned pages).
    static func text(of url: URL, progress: @escaping ProgressHandler) throws -> String {
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
                    pages.append(try VisionTools.recognizeText(in: img))
                }
                progress(Double(i + 1) / Double(max(doc.pageCount, 1)))
            }
            return pages.filter { !$0.isEmpty }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let image = try autoreleasepool { try ImageCodec.load(url).image }
        return try VisionTools.recognizeText(in: image).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Flatten

    private func flatten(_ scan: FolderScan, progress: @escaping ProgressHandler) throws -> ToolResult {
        let fm = FileManager.default
        let entries = Self.naturalOrder(scan.entries.filter { $0.root != nil }, scan: scan)
        guard !entries.isEmpty else { throw PetalwheelError(l: "The selected folders contain no files.") }
        var outputs: [URL] = []
        var done = 0
        do {
            for root in scan.roots {
                let mine = entries.filter { $0.root == root }
                guard !mine.isEmpty else { continue }
                let dest = Self.uniqueFolder(root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent) (flat)"))
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                outputs.append(dest)
                // Names are decided up front (case-insensitively, like APFS): "photo.jpg", "photo 2.jpg"…
                var taken = Set<String>()
                for e in mine {
                    try Task.checkCancellation()
                    let target = Self.uniqueName(e.url.lastPathComponent, in: dest, taken: taken)
                    taken.insert(target.lastPathComponent.lowercased())
                    try fm.copyItem(at: e.url, to: target)
                    done += 1
                    progress(Double(done) / Double(entries.count))
                }
            }
        } catch {
            if error is CancellationError { for o in outputs { try? fm.removeItem(at: o) } }
            throw error
        }
        return ToolResult(outputs: outputs)
    }

    // MARK: - Report

    static func report(_ scan: FolderScan, inputs: [URL]) -> [String] {
        let bytes = ImageCodec.formatBytes
        var messages: [String] = []

        let title = inputs.count == 1 ? inputs[0].lastPathComponent : Lp("%d items", inputs.count)
        messages.append([title,
                         Lp("%d files", scan.entries.count) + " · " + Lp("%d folders", scan.folderCount),
                         L("Total size: %@", bytes(scan.totalSize))].joined(separator: "\n"))

        // By type: groups by total size, with the formats inside.
        var byGroup: [String: (title: String, count: Int, size: Int64, formats: [String: Int])] = [:]
        for e in scan.entries {
            let key = e.format?.group.rawValue ?? (e.isPackage ? "packages" : "other")
            var g = byGroup[key] ?? (e.format?.group.title ?? (e.isPackage ? L("Apps and packages") : L("Other")), 0, 0, [:])
            g.count += 1
            g.size += e.size
            let fmt = e.format?.title ?? (e.url.pathExtension.isEmpty ? "–" : e.url.pathExtension.uppercased())
            g.formats[fmt, default: 0] += 1
            byGroup[key] = g
        }
        let groupLines = byGroup.values.sorted { $0.size != $1.size ? $0.size > $1.size : $0.title < $1.title }.map { g in
            let formats = g.formats.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            return "\(g.title): " + Lp("%d files", g.count) + ", \(bytes(g.size)) (\(formats))"
        }
        messages.append(([L("By type")] + groupLines).joined(separator: "\n"))

        let largest = scan.entries.sorted { $0.size > $1.size }.prefix(10)
            .map { e in
                let prefix = inputs.count > 1 ? e.root.map { $0.lastPathComponent + "/" } ?? "" : ""
                return "\(bytes(e.size))  \(prefix)\(e.relativePath)"
            }
        if !largest.isEmpty { messages.append(([L("Largest files")] + largest).joined(separator: "\n")) }

        var skipped: [String] = []
        if scan.hiddenSkipped > 0 { skipped.append(Lp("%d hidden items skipped", scan.hiddenSkipped)) }
        if scan.symlinksSkipped > 0 { skipped.append(Lp("%d symbolic links skipped", scan.symlinksSkipped)) }
        let packages = scan.entries.filter(\.isPackage).count
        if packages > 0 { skipped.append(Lp("%d packages counted as single files", packages)) }
        if !skipped.isEmpty { messages.append(skipped.joined(separator: "\n")) }
        return messages
    }
}
