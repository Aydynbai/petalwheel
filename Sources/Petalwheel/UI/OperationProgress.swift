import AppKit
import SwiftUI
import Combine

/// One failed item in an operation: a short human message plus the technical detail.
struct OperationProblem: Identifiable, Equatable {
    let id = UUID()
    /// File (or step) name; empty when the problem isn't tied to a file.
    var name: String
    /// Short message from `ErrorTranslator`.
    var message: String
    /// Technical detail (ffmpeg stderr, NSError…), shown behind "Details". Empty = none.
    var detail: String = ""

    init(name: String = "", message: String, detail: String = "") {
        self.name = name
        self.message = message
        self.detail = detail
    }

    /// Builds a problem from an error via `ErrorTranslator`.
    init(name: String, error: Error, file: URL? = nil) {
        let f = ErrorTranslator.translate(error, file: file)
        self.init(name: name, message: f.message, detail: f.detail)
    }

    var line: String { name.isEmpty ? message : "\(name): \(message)" }
}

/// One running (or finished) operation shown as a card in the progress HUD.
final class OperationCardModel: ObservableObject, Identifiable {
    enum Phase { case running, cancelling, succeeded, cancelled, failed }

    let id: UUID
    let title: String
    let itemCount: Int
    let onCancel: () -> Void
    @Published var itemIndex = 0
    @Published var itemName = ""
    @Published var fraction: Double = 0
    @Published var phase: Phase = .running
    @Published var outputs: [URL] = []
    @Published var failures: [String] = []
    @Published var problems: [OperationProblem] = []
    @Published var expandedProblems: Set<UUID> = []

    // Per-item tracking for concurrent jobs (see `OperationProgress.itemStarted` etc.).
    @Published var tracksItems = false
    @Published var completedCount = 0
    /// index → (name, fraction) for items currently running.
    @Published var runningItems: [Int: RunningItem] = [:]
    private(set) var finishedIndices: Set<Int> = []

    struct RunningItem: Equatable {
        var name: String
        var fraction: Double
    }

    init(id: UUID, title: String, itemCount: Int, onCancel: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.itemCount = max(itemCount, 1)
        self.onCancel = onCancel
    }

    var overall: Double {
        switch phase {
        case .succeeded: return 1
        default:
            if tracksItems {
                let running = runningItems.values.reduce(0) { $0 + min(max($1.fraction, 0), 1) }
                return min(max((Double(completedCount) + running) / Double(itemCount), 0), 1)
            }
            let f = min(max(fraction, 0), 1)
            return min(max((Double(itemIndex) + f) / Double(itemCount), 0), 1)
        }
    }

    var isActive: Bool { phase == .running || phase == .cancelling }

    /// Running items in index order.
    var runningList: [(index: Int, item: RunningItem)] {
        runningItems.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    fileprivate func markStarted(_ index: Int, name: String) {
        tracksItems = true
        guard !finishedIndices.contains(index) else { return }
        runningItems[index] = RunningItem(name: name, fraction: 0)
        itemName = name
        itemIndex = min(max(index, 0), itemCount - 1)
    }

    fileprivate func markProgress(_ index: Int, fraction: Double) {
        guard !finishedIndices.contains(index), var item = runningItems[index] else { return }
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        // Skip tiny changes to keep SwiftUI work down when several jobs report at once.
        guard abs(f - item.fraction) >= 0.005 || f == 1 else { return }
        item.fraction = f
        runningItems[index] = item
    }

    fileprivate func markFinished(_ index: Int) {
        tracksItems = true
        guard finishedIndices.insert(index).inserted else { return }
        runningItems[index] = nil
        completedCount = min(finishedIndices.count, itemCount)
    }
}

final class OperationHUDModel: ObservableObject {
    @Published var cards: [OperationCardModel] = []
}

/// Floating, non-activating HUD in the top-right corner that stacks one card per operation.
@MainActor
final class OperationProgress {
    static let shared = OperationProgress()

    private let model = OperationHUDModel()
    private var panel: KQPanel?
    private var hosting: NSHostingView<OperationHUDView>?
    private var cancellables: [UUID: AnyCancellable] = [:]
    private var hudCancellable: AnyCancellable?
    private var hideWork: [UUID: DispatchWorkItem] = [:]

    private init() {}

    /// Begins a HUD for an operation over `itemCount` files. Returns an id. `onCancel` is invoked by the HUD's cancel button.
    func start(title: String, itemCount: Int, onCancel: @escaping () -> Void) -> UUID {
        let id = UUID()
        let card = OperationCardModel(id: id, title: title, itemCount: itemCount, onCancel: onCancel)
        add(card)
        return id
    }

    func update(_ id: UUID, itemIndex: Int, itemName: String, fraction: Double) {
        guard let card = card(id), card.isActive else { return }
        card.itemIndex = min(max(itemIndex, 0), card.itemCount - 1)
        card.itemName = itemName
        card.fraction = fraction.isFinite ? fraction : 0
    }

    // MARK: Concurrent items

    /// Marks item `index` as running (several items may run at once).
    func itemStarted(_ id: UUID, index: Int, name: String) {
        guard let card = card(id), card.isActive else { return }
        card.markStarted(index, name: name)
    }

    /// Progress 0...1 of a running item.
    func itemProgress(_ id: UUID, index: Int, fraction: Double) {
        guard let card = card(id), card.isActive else { return }
        card.markProgress(index, fraction: fraction)
    }

    /// Marks item `index` as done (succeeded or failed): it counts toward "N of M done".
    func itemFinished(_ id: UUID, index: Int) {
        guard let card = card(id), card.isActive else { return }
        card.markFinished(index)
    }

    /// Shows the result with structured problems (message + copyable details).
    func finish(_ id: UUID, outputs: [URL], problems: [OperationProblem]) {
        finish(id, outputs: outputs, failures: problems.map(\.line), problems: problems)
    }

    /// Shows the result (Show in Finder button for outputs, list of failures) and auto-hides on success.
    func finish(_ id: UUID, outputs: [URL], failures: [String]) {
        finish(id, outputs: outputs, failures: failures, problems: failures.map { OperationProblem(message: $0) })
    }

    private func finish(_ id: UUID, outputs: [URL], failures: [String], problems: [OperationProblem]) {
        let card: OperationCardModel
        if let existing = self.card(id) {
            card = existing
        } else {
            card = OperationCardModel(id: id, title: "NurTo", itemCount: 1, onCancel: {})
            add(card)
        }
        let wasCancelling = card.phase == .cancelling
        card.outputs = outputs
        card.failures = failures
        card.problems = problems
        card.fraction = 1
        card.itemIndex = card.itemCount - 1
        card.runningItems = [:]
        if !failures.isEmpty {
            card.phase = .failed
        } else if wasCancelling {
            card.phase = .cancelled
        } else {
            card.phase = .succeeded
        }

        let settings = AppSettings.shared
        if settings.soundsEnabled {
            NSSound(named: NSSound.Name(failures.isEmpty ? "Glass" : "Basso"))?.play()
            NSHapticFeedbackManager.defaultPerformer.perform(failures.isEmpty ? .levelChange : .generic,
                                                             performanceTime: .now)
        }
        if settings.revealOutputs && !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if failures.isEmpty {
            scheduleHide(id, after: card.phase == .cancelled && !outputs.isEmpty ? 6 : 4)
        }
        relayout()
    }

    // MARK: - Internals

    private func card(_ id: UUID) -> OperationCardModel? {
        model.cards.first { $0.id == id }
    }

    private func add(_ card: OperationCardModel) {
        model.cards.append(card)
        cancellables[card.id] = card.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.relayout() } }
        }
        ensurePanel()
        relayout()
        panel?.orderFrontRegardless()
    }

    /// Cancels a running operation as if its cancel button were pressed.
    func cancel(_ id: UUID) {
        guard let card = card(id), card.phase == .running else { return }
        card.phase = .cancelling
        card.onCancel()
    }

    fileprivate func close(_ id: UUID) {
        hideWork[id]?.cancel()
        hideWork[id] = nil
        cancellables[id] = nil
        model.cards.removeAll { $0.id == id }
        if model.cards.isEmpty {
            panel?.orderOut(nil)
        } else {
            relayout()
        }
    }

    fileprivate func hover(_ id: UUID, inside: Bool) {
        guard let card = card(id), card.phase == .succeeded || card.phase == .cancelled else { return }
        if inside {
            hideWork[id]?.cancel()
            hideWork[id] = nil
        } else {
            scheduleHide(id, after: 2)
        }
    }

    private func scheduleHide(_ id: UUID, after seconds: Double) {
        hideWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.close(id) }
        }
        hideWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = KQPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        let view = OperationHUDView(model: model,
                                    onCancel: { [weak self] id in self?.cancel(id) },
                                    onClose: { [weak self] id in self?.close(id) },
                                    onHover: { [weak self] id, inside in self?.hover(id, inside: inside) })
        let host = NSHostingView(rootView: view)
        p.contentView = host
        hosting = host
        panel = p
    }

    private var relayoutPending = false

    /// Coalesces resizes; runs after SwiftUI has applied the pending state change.
    private func relayout() {
        applyLayout()
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.relayoutPending = false
                self?.applyLayout()
            }
        }
    }

    private func applyLayout() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        size.width = OperationHUDView.width
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        size.height = min(max(size.height, 40), vf.height - 20)
        let frame = NSRect(x: vf.maxX - size.width - 8, y: vf.maxY - size.height - 4,
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

// MARK: - Views

struct OperationHUDView: View {
    static let width: CGFloat = 344
    @ObservedObject var model: OperationHUDModel
    var onCancel: (UUID) -> Void
    var onClose: (UUID) -> Void
    var onHover: (UUID, Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.cards) { card in
                OperationCardView(card: card,
                                  onCancel: { onCancel(card.id) },
                                  onClose: { onClose(card.id) })
                    .onHover { onHover(card.id, $0) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .frame(width: Self.width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.2), value: model.cards.map(\.id))
    }
}

struct OperationCardView: View {
    @ObservedObject var card: OperationCardModel
    var onCancel: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                trailingButton
            }

            if card.isActive {
                KQProgressBar(value: card.overall)
                if card.tracksItems && card.runningItems.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(card.runningList.prefix(4), id: \.index) { entry in
                            HStack(spacing: 6) {
                                Text(entry.item.name)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                KQProgressBar(value: entry.item.fraction, height: 3)
                                    .frame(width: 70)
                            }
                        }
                        if card.runningItems.count > 4 {
                            Text(L("+%d more running", card.runningItems.count - 4))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Text(progressLine)
                    Spacer()
                    Text(verbatim: "\(Int((card.overall * 100).rounded()))%")
                        .monospacedDigit()
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }

            if !card.problems.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(card.problems) { problem in
                            OperationProblemRow(problem: problem, card: card)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: card.expandedProblems.isEmpty ? 120 : 220)
                .fixedSize(horizontal: false, vertical: card.problems.count < 4 && card.expandedProblems.isEmpty)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(KQTheme.danger.opacity(0.10)))
            }

            if !card.isActive && !card.outputs.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(card.outputs)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(KQProminentButtonStyle())
                }
            }
        }
        .padding(KQTheme.padding - 2)
        .kqCard()
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private var progressLine: String {
        if card.phase == .cancelling { return L("Cancelling…") }
        if card.tracksItems {
            return L("%d of %d done", card.completedCount, card.itemCount)
        }
        return L("%d of %d", card.itemIndex + 1, card.itemCount)
    }

    private var subtitle: String {
        switch card.phase {
        case .running, .cancelling:
            if card.tracksItems && card.runningItems.count > 1 {
                return Lp("%d files at once", card.runningItems.count)
            }
            if card.tracksItems, let only = card.runningItems.values.first { return only.name }
            return card.itemName.isEmpty ? L("Preparing…") : card.itemName
        case .succeeded:
            let n = card.outputs.count
            return n == 0 ? L("Done") : Lp("Done – %d files created", n)
        case .cancelled:
            let n = card.outputs.count
            return n == 0 ? L("Cancelled") : Lp("Cancelled – %d files created", n)
        case .failed:
            let n = max(card.problems.count, card.failures.count)
            return Lp("%d problems", n) + (card.outputs.isEmpty ? "" : ", " + L("%d created", card.outputs.count))
        }
    }

    @ViewBuilder private var statusIcon: some View {
        ZStack {
            Circle().fill(iconColor.opacity(0.16)).frame(width: 30, height: 30)
            switch card.phase {
            case .running, .cancelling:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KQTheme.accentText)
            case .succeeded:
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(KQTheme.success)
            case .cancelled:
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(KQTheme.danger)
            }
        }
    }

    private var iconColor: Color {
        switch card.phase {
        case .running, .cancelling: return KQTheme.accent
        case .succeeded: return KQTheme.success
        case .cancelled: return KQTheme.inkSecondary
        case .failed: return KQTheme.danger
        }
    }

    @ViewBuilder private var trailingButton: some View {
        if card.isActive {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(card.phase == .cancelling)
            .help("Cancel")
        } else {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }
}

/// A failure line with a "Details" disclosure holding the copyable technical text.
struct OperationProblemRow: View {
    let problem: OperationProblem
    @ObservedObject var card: OperationCardModel

    private var expanded: Bool { card.expandedProblems.contains(problem.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                (Text(problem.name.isEmpty ? "" : problem.name + ": ").fontWeight(.medium) + Text(problem.message))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !problem.detail.isEmpty && problem.detail != problem.message {
                    Button {
                        if expanded { card.expandedProblems.remove(problem.id) } else { card.expandedProblems.insert(problem.id) }
                    } label: {
                        HStack(spacing: 2) {
                            Text(ErrorStrings.details)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(KQTheme.accentText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 11))
            if expanded {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(problem.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(problem.name.isEmpty ? problem.detail : "\(problem.name)\n\(problem.detail)", forType: .string)
                    } label: {
                        Label(ErrorStrings.copy, systemImage: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.leading, 12)
            }
        }
    }
}

/// Determinate NurTo progress bar.
struct KQProgressBar: View {
    var value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(KQTheme.accent)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: height)
    }
}
