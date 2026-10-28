import AppKit

/// What a finished `runJobs` call produced.
struct JobOutcome {
    var outputs: [URL] = []
    var problems: [OperationProblem] = []
    var messages: [String] = []
    var cancelled = false
    var succeeded: Bool { problems.isEmpty && !cancelled }
}

/// Routes fan selections to conversion engines, tool modules and file actions, and drives the progress HUD.
/// Per-file jobs run concurrently, bounded by `JobSettings.limit(for:)` ("Parallel jobs" in Settings).
@MainActor
final class JobCoordinator {
    private let engines: [ConversionEngine] = [
        ImageEngine(), MediaEngine(), DocumentEngine(), SpreadsheetEngine(), SubtitleEngine(), ArchiveEngine(), EpubEngine(), OfficeEngine(), IWorkEngine(),
    ]
    private let toolModules: [ToolModule] = [ImageToolsModule(), MediaToolsModule(), ArchiveToolsModule()]
    private let actions = ActionPerformer()

    /// Tools that consume all inputs at once and produce a single result.
    private let batchTools: Set<FileTool> = [.createCollage, .createPDF, .mergePDF, .joinVideos, .createArchive]
    private var toolOptions = ToolOptions()

    /// Running operations by HUD id, so `cancelAll()` can stop everything.
    private var running: [UUID: Task<JobOutcome, Never>] = [:]

    func handle(_ item: FanItem, urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch item.kind {
        case .format(let target): convert(urls, to: target)
        case .tool(let tool): runTool(tool, urls: urls)
        case .action(let action): actions.perform(action, urls: urls)
        case .preset(let id): runPreset(id, urls: urls)
        case .category: break   // handled by the fan (opens the category)
        }
    }

    /// Cancels every running operation.
    func cancelAll() {
        for id in running.keys { OperationProgress.shared.cancel(id) }
    }

    // MARK: Conversions

    @discardableResult
    func convert(_ urls: [URL], to target: FileFormat, options: ConversionOptions? = nil,
                 title: String? = nil, downmixToMono: Bool = false, presetID: UUID? = nil) -> Task<JobOutcome, Never>? {
        let options = options ?? AppSettings.shared.conversionOptions
        let engines = self.engines
        let rerun = HistoryRerun(action: .convert(target), presetID: presetID,
                                 conversion: CodableConversionOptions(options), downmixToMono: downmixToMono)
        return runJobs(title: title ?? L("Converting to %@", target.title), urls: urls, rerun: rerun) { index, progress in
            let url = urls[index]
            guard downmixToMono else {
                return ToolResult(outputs: try await Self.convertOne(url, to: target, options: options,
                                                                     engines: engines, progress: progress))
            }
            let converted = try await Self.convertOne(url, to: target, options: options, engines: engines) {
                progress($0 * 0.7)
            }
            var final: [URL] = []
            for out in converted {
                final.append(try await Self.downmixInPlace(out) { progress(0.7 + $0 * 0.3) })
            }
            return ToolResult(outputs: final)
        }
    }

    nonisolated private static func convertOne(_ url: URL, to target: FileFormat, options: ConversionOptions,
                                               engines: [ConversionEngine],
                                               progress: @escaping ProgressHandler) async throws -> [URL] {
        guard let source = FileFormat.detect(url) else {
            throw PetalwheelError(l: "Unsupported file type: %@", url.lastPathComponent)
        }
        if source == target { throw PetalwheelError(l: "%@ is already %@", url.lastPathComponent, target.title) }
        guard let engine = engines.first(where: { $0.canConvert(from: source, to: target) }) else {
            throw PetalwheelError(l: "Can't convert %@ to %@", source.title, target.title)
        }
        return try await engine.convert(url, from: source, to: target, options: options, progress: progress)
    }

    /// Re-encodes `url` as mono and replaces it (used by presets such as "Voice memo → MP3 mono").
    nonisolated private static func downmixInPlace(_ url: URL, progress: @escaping ProgressHandler) async throws -> URL {
        var o = ToolOptions()
        o.mono = true
        let result = try await MediaToolsModule().run(.audioChannels, inputs: [url], options: o, progress: progress)
        guard let mono = result.outputs.first else { return url }
        let fm = FileManager.default
        try fm.removeItem(at: url)
        try fm.moveItem(at: mono, to: url)
        return url
    }

    // MARK: Tools

    func runTool(_ tool: FileTool, urls: [URL]) {
        if tool.isInteractive {
            EditorRouter.present(tool, inputs: urls) { [weak self] export in
                guard let self, let export else { return }
                self.runJobs(title: tool.title, urls: [urls[0]], inputs: urls,
                             displayNames: [urls.count == 1 ? urls[0].lastPathComponent : Lp("%d files", urls.count)],
                             rerun: HistoryRerun(action: .tool(tool))) { _, progress in
                    ToolResult(outputs: try await export(progress))
                }
            }
            return
        }
        if tool.needsOptions {
            ToolOptionsPanel.present(tool: tool, inputs: urls, initial: toolOptions) { [weak self] options in
                guard let self, let options else { return }
                self.toolOptions = options
                self.executeTool(tool, urls: urls, options: options)
            }
        } else {
            executeTool(tool, urls: urls, options: toolOptions)
        }
    }

    private func module(for tool: FileTool, url: URL) -> ToolModule? {
        let format = FileFormat.detect(url)
        return toolModules.first { $0.canRun(tool, format: format) }
    }

    @discardableResult
    func executeTool(_ tool: FileTool, urls: [URL], options: ToolOptions,
                     title: String? = nil, presetID: UUID? = nil) -> Task<JobOutcome, Never>? {
        let completion: ([String]) -> Void = { messages in
            if !messages.isEmpty {
                TextResultsWindow.show(title: tool.title, messages: messages)
            }
        }
        let rerun = HistoryRerun(action: .tool(tool), presetID: presetID, tool: CodableToolOptions(options))
        let title = title ?? tool.title

        if batchTools.contains(tool) {
            guard let module = module(for: tool, url: urls[0]) else { reportUnsupported(tool); return nil }
            return runJobs(title: title, urls: [urls[0]], inputs: urls, displayNames: [Lp("%d files", urls.count)],
                           rerun: rerun, onComplete: completion) { _, progress in
                try await module.run(tool, inputs: urls, options: options, progress: progress)
            }
        } else {
            let modules = urls.map { module(for: tool, url: $0) }
            if modules.contains(where: { $0 == nil }) { reportUnsupported(tool); return nil }
            let resolved = modules.compactMap { $0 }
            return runJobs(title: title, urls: urls, rerun: rerun, onComplete: completion) { index, progress in
                try await resolved[index].run(tool, inputs: [urls[index]], options: options, progress: progress)
            }
        }
    }

    private func reportUnsupported(_ tool: FileTool) {
        let id = OperationProgress.shared.start(title: tool.title, itemCount: 0, onCancel: {})
        OperationProgress.shared.finish(id, outputs: [], problems: [OperationProblem(message: L("%@ isn't available for these files.", tool.title))])
    }

    // MARK: Presets & history

    /// Runs a user preset without the options panel.
    @discardableResult
    func runPreset(_ id: UUID, urls: [URL]) -> Task<JobOutcome, Never>? {
        guard let preset = PresetStore.shared.preset(id) else {
            let hud = OperationProgress.shared.start(title: L("Preset"), itemCount: 0, onCancel: {})
            OperationProgress.shared.finish(hud, outputs: [], problems: [OperationProblem(message: L("This preset no longer exists."))])
            return nil
        }
        return run(preset, urls: urls)
    }

    @discardableResult
    func run(_ preset: UserPreset, urls: [URL]) -> Task<JobOutcome, Never>? {
        if let target = preset.action.format {
            return convert(urls, to: target, options: preset.conversion.options, title: preset.name,
                           downmixToMono: preset.downmixToMono, presetID: preset.id)
        }
        if let tool = preset.action.tool, !tool.isInteractive {
            return executeTool(tool, urls: urls, options: preset.tool.options, title: preset.name, presetID: preset.id)
        }
        return nil
    }

    /// "Run Again" from the Recent menu: same action, same inputs, the options used last time.
    func runAgain(_ entry: HistoryEntry) {
        guard let rerun = entry.rerun, entry.canRunAgain else { return }
        let urls = entry.inputs
        if let pid = rerun.presetID, let preset = PresetStore.shared.preset(pid) {
            run(preset, urls: urls)
            return
        }
        guard let action = rerun.action else { return }
        if let target = action.format {
            convert(urls, to: target, options: rerun.conversion?.options, downmixToMono: rerun.downmixToMono ?? false)
        } else if let tool = action.tool {
            if tool.isInteractive {
                runTool(tool, urls: urls)
            } else {
                executeTool(tool, urls: urls, options: rerun.tool?.options ?? toolOptions)
            }
        }
    }

    // MARK: Job runner

    /// Runs `work` for each of `urls` with bounded concurrency and drives one HUD card.
    /// - Parameters:
    ///   - inputs: the original inputs for history (defaults to `urls`; batch tools pass all files).
    ///   - limit: max concurrent items (defaults to the "Parallel jobs" setting).
    @discardableResult
    func runJobs(title: String, urls: [URL], inputs: [URL]? = nil, displayNames: [String]? = nil,
                 rerun: HistoryRerun? = nil, limit: Int? = nil,
                 onComplete: (([String]) -> Void)? = nil,
                 work: @escaping @Sendable (Int, @escaping ProgressHandler) async throws -> ToolResult) -> Task<JobOutcome, Never> {
        var task: Task<JobOutcome, Never>?
        let hud = OperationProgress.shared
        let id = hud.start(title: title, itemCount: urls.count, onCancel: { task?.cancel() })
        let names = displayNames ?? urls.map(\.lastPathComponent)
        let maxConcurrent = max(1, min(limit ?? JobSettings.shared.limit(for: urls), urls.count))
        let startDate = Date()

        let t = Task { @MainActor [weak self] () -> JobOutcome in
            var outputsByIndex: [Int: [URL]] = [:]
            var problems: [(Int, OperationProblem)] = []
            var messages: [String] = []

            await withTaskGroup(of: (Int, Result<ToolResult, Error>).self) { group in
                var next = 0
                var inFlight = 0
                while true {
                    while next < urls.count && inFlight < maxConcurrent && !Task.isCancelled {
                        let index = next
                        next += 1
                        inFlight += 1
                        hud.itemStarted(id, index: index, name: names[index])
                        let progress: ProgressHandler = { fraction in
                            Task { @MainActor in hud.itemProgress(id, index: index, fraction: fraction) }
                        }
                        group.addTask {
                            do {
                                return (index, .success(try await work(index, progress)))
                            } catch {
                                return (index, .failure(error))
                            }
                        }
                    }
                    guard let (index, result) = await group.next() else { break }
                    inFlight -= 1
                    hud.itemFinished(id, index: index)
                    switch result {
                    case .success(let r):
                        outputsByIndex[index] = r.outputs
                        messages += r.messages
                    case .failure(let error):
                        if error is CancellationError || Task.isCancelled { continue }
                        problems.append((index, OperationProblem(name: names[index], error: error, file: urls[index])))
                    }
                }
            }

            let cancelled = Task.isCancelled
            var outcome = JobOutcome()
            outcome.outputs = outputsByIndex.keys.sorted().flatMap { outputsByIndex[$0] ?? [] }
            outcome.problems = problems.sorted { $0.0 < $1.0 }.map(\.1)
            outcome.messages = messages
            outcome.cancelled = cancelled

            hud.finish(id, outputs: outcome.outputs, problems: outcome.problems)
            HistoryStore.shared.record(HistoryEntry(title: title, date: startDate, inputs: inputs ?? urls,
                                                    outputs: outcome.outputs, succeeded: outcome.succeeded,
                                                    cancelled: cancelled, problem: outcome.problems.first?.line,
                                                    rerun: rerun))
            self?.running[id] = nil
            onComplete?(messages)
            return outcome
        }
        task = t
        running[id] = t
        return t
    }
}
