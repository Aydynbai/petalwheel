import Foundation

// Glue between folder operations and the app's two front ends (the progress HUD and the CLI).

extension JobCoordinator {
    /// Runs one folder operation as a single HUD card ("Photos – 120 files") whose progress covers every file.
    /// Cancelling the card cancels the operation (remaining files are skipped, partial folders removed).
    @discardableResult
    func runFolderJob(title: String, urls: [URL], rerun: HistoryRerun?, onComplete: (([String]) -> Void)? = nil,
                      work: @escaping @Sendable (@escaping ProgressHandler) async throws -> ToolResult) -> Task<JobOutcome, Never> {
        runJobs(title: title, urls: [urls[0]], inputs: urls, displayNames: [FolderCatalog.displayName(urls)],
                rerun: rerun, limit: 1, onComplete: onComplete) { _, progress in
            try await work(progress)
        }
    }

    /// Shows per-file problems and notes of a folder job (if any) in a results window.
    static func folderMessages(title: String) -> ([String]) -> Void {
        { messages in
            if !messages.isEmpty { TextResultsWindow.show(title: title, messages: messages) }
        }
    }
}

enum FolderCommandLine {
    /// `--convert <format> <folder…>` / `--tool <tool> <folder…>` when the inputs include a folder.
    /// Returns nil when the inputs hold no folder (or the tool isn't a folder tool), so the caller handles them.
    static func run(convert target: FileFormat?, tool: FileTool?, urls: [URL],
                    engines: [ConversionEngine]) async throws -> ToolResult? {
        guard FolderCatalog.containsFolder(urls) else { return nil }
        let module = FolderToolsModule(engines: engines, conversion: ConversionOptions())
        if let target { return try await module.convert(urls, to: target, progress: { _ in }) }
        guard let tool, FolderCatalog.folderTools.contains(tool) else { return nil }
        return try await module.run(tool, inputs: urls, options: ToolOptions(), progress: { _ in })
    }

    /// Prints outputs, then messages with every line prefixed by "» " (scripts treat other lines as paths).
    static func print(_ result: ToolResult) {
        result.outputs.forEach { Swift.print($0.path) }
        for message in result.messages {
            for line in message.split(separator: "\n", omittingEmptySubsequences: false) { Swift.print("» \(line)") }
        }
    }
}
