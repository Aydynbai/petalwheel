import Foundation

/// Headless mode: `Petalwheel --convert <format> files…` or `Petalwheel --tool <tool> files…`.
/// Runs through the same engines and tool modules as the UI; prints created files.
enum CommandLineMode {
    static let engines: [ConversionEngine] = [
        ImageEngine(), MediaEngine(), DocumentEngine(), SpreadsheetEngine(), SubtitleEngine(), ArchiveEngine(), EpubEngine(), OfficeEngine(), IWorkEngine(),
    ]
    static let toolModules: [ToolModule] = [ImageToolsModule(), MediaToolsModule(), ArchiveToolsModule()]

    /// Returns nil when the arguments don't request CLI mode.
    static func runIfRequested(_ args: [String]) -> Int32? {
        guard args.count >= 2, ["--convert", "--tool", "--list"].contains(args[1]) else { return nil }
        // CLI output is always English so scripts and tests can rely on it.
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": ["en"]], forName: UserDefaults.argumentDomain)
        if args[1] == "--list" {
            print("formats: " + FileFormat.allCases.map(\.rawValue).joined(separator: " "))
            print("tools:   " + FileTool.allCases.map(\.rawValue).joined(separator: " "))
            return 0
        }
        guard args.count >= 4 else {
            fputs("usage: Petalwheel --convert <format> <files…> | --tool <tool> <files…> | --list\n", stderr)
            return 2
        }
        let urls = args.dropFirst(3).map { URL(fileURLWithPath: $0).standardizedFileURL }
        var status: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                if args[1] == "--convert" {
                    guard let target = FileFormat(rawValue: args[2].lowercased()) else { throw PetalwheelError("Unknown format \(args[2])") }
                    for url in urls {
                        do { try await convert(url, to: target).forEach { print($0.path) } }
                        catch { fputs("✗ \(url.lastPathComponent): \(error.localizedDescription)\n", stderr); status = 1 }
                    }
                } else {
                    guard let tool = FileTool(rawValue: args[2]) else { throw PetalwheelError("Unknown tool \(args[2])") }
                    let options = ToolOptions()
                    let batch: Set<FileTool> = [.createCollage, .createPDF, .mergePDF, .joinVideos, .createArchive]
                    let groups = batch.contains(tool) ? [urls] : urls.map { [$0] }
                    for group in groups {
                        guard let module = toolModules.first(where: { $0.canRun(tool, format: FileFormat.detect(group[0])) }) else {
                            throw PetalwheelError("\(tool.rawValue) can't handle \(group[0].lastPathComponent)")
                        }
                        do {
                            let r = try await module.run(tool, inputs: group, options: options, progress: { _ in })
                            r.outputs.forEach { print($0.path) }
                            r.messages.forEach { print("» \($0)") }
                        } catch { fputs("✗ \(group[0].lastPathComponent): \(error.localizedDescription)\n", stderr); status = 1 }
                    }
                }
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                status = 2
            }
            done.signal()
        }
        // Keep the main run loop alive: some engines hop to the main actor (HTML import, printing).
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return status
    }

    static func convert(_ url: URL, to target: FileFormat) async throws -> [URL] {
        guard let source = FileFormat.detect(url) else { throw PetalwheelError("Unsupported file type") }
        if source == target { throw PetalwheelError("Already \(target.title)") }
        guard let engine = engines.first(where: { $0.canConvert(from: source, to: target) }) else {
            throw PetalwheelError("Can't convert \(source.title) to \(target.title)")
        }
        return try await engine.convert(url, from: source, to: target, options: ConversionOptions(), progress: { _ in })
    }
}
