import AppKit
import SwiftUI
import CoreImage

/// Photo adjustments editor: grouped sliders, presets, live preview on a proxy, compare, filmstrip.
@MainActor
enum AdjustImageEditor {
    /// Opens the editor window for `inputs`. Calls `completion` exactly once (nil = cancelled).
    static func present(inputs: [URL], completion: @escaping EditorCompletion) {
        guard !inputs.isEmpty else { completion(nil); return }
        AdjustEditorSession(inputs: inputs, completion: completion).show()
    }
}

// MARK: - Model

@MainActor
final class AdjustEditorModel: ObservableObject {
    let inputs: [URL]
    @Published var settings = AdjustSettings() { didSet { if settings != oldValue { scheduleRender() } } }
    @Published var index = 0 { didSet { if index != oldValue { loadProxy() } } }
    @Published var showOriginal = false
    @Published var activePreset: String?
    @Published private(set) var original: CGImage?
    @Published private(set) var rendered: CGImage?
    @Published private(set) var thumbnails: [Int: CGImage] = [:]
    @Published private(set) var loadError: String?

    private var proxy: CIImage?
    private var generation = 0
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "kumquat.adjust.render", qos: .userInitiated)
    private let thumbQueue = DispatchQueue(label: "kumquat.adjust.thumbs", qos: .utility)

    /// Snapshot-based undo of the settings (and the preset they came from).
    private struct Snapshot: Equatable {
        var settings: AdjustSettings
        var preset: String?
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var coalesceKey: String?
    private var coalesceTime: CFTimeInterval = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    init(inputs: [URL]) {
        self.inputs = inputs
        loadProxy()
        if inputs.count > 1 { loadThumbnails() }
    }

    var displayed: CGImage? { showOriginal ? original : (rendered ?? original) }

    /// Any slider away from neutral.
    var hasUnsavedChanges: Bool { !settings.isNeutral }

    func binding(_ p: AdjustParam) -> Binding<Double> {
        Binding(get: { [unowned self] in self.settings[p] },
                set: { [unowned self] v in
                    var s = self.settings
                    s[p] = v
                    if s != self.settings {
                        self.recordUndo(coalesce: p.rawValue)
                        self.settings = s
                        self.activePreset = nil
                    }
                })
    }

    func apply(_ preset: AdjustPreset) {
        guard preset.settings != settings || activePreset != preset.name else { return }
        recordUndo()
        settings = preset.settings
        activePreset = preset.name
    }

    func resetAll() {
        guard !settings.isNeutral || activePreset != nil else { return }
        recordUndo()
        settings = AdjustSettings()
        activePreset = nil
    }

    // MARK: Undo

    private var snapshot: Snapshot { Snapshot(settings: settings, preset: activePreset) }

    /// Records the state before a change. Changes of the same slider within a second form one step.
    private func recordUndo(coalesce key: String? = nil) {
        let now = CACurrentMediaTime()
        if let key, key == coalesceKey, now - coalesceTime < 1 {
            coalesceTime = now
            return
        }
        coalesceKey = key
        coalesceTime = now
        undoStack.append(snapshot)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoFlags()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    private func restore(_ s: Snapshot) {
        settings = s.settings
        activePreset = s.preset
        coalesceKey = nil
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func setCompare(_ on: Bool) {
        if showOriginal != on { showOriginal = on }
    }

    private func loadProxy() {
        let url = inputs[index]
        generation += 1
        let gen = generation
        rendered = nil
        loadError = nil
        queue.async { [weak self] in
            let img = AdjustPipeline.loadProxy(url)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                guard let img else {
                    self.original = nil
                    self.proxy = nil
                    self.loadError = L("Could not read %@.", url.lastPathComponent)
                    return
                }
                self.original = img
                self.proxy = CIImage(cgImage: img)
                self.scheduleRender(delay: 0)
            }
        }
    }

    /// Debounced, coalesced render of the proxy on a background queue.
    private func scheduleRender(delay: Double = 0.03) {
        guard let proxy else { return }
        generation += 1
        let gen = generation
        let snapshot = settings
        pending?.cancel()
        if snapshot.isNeutral { rendered = original; return }
        let colorSpace = original?.colorSpace
        let work = DispatchWorkItem { [weak self] in
            let out = AdjustPipeline.render(AdjustPipeline.apply(snapshot, to: proxy), colorSpace: colorSpace)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.rendered = out
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func loadThumbnails() {
        for (i, url) in inputs.enumerated() {
            thumbQueue.async { [weak self] in
                let t = AdjustPipeline.loadProxy(url, maxSide: 160)
                DispatchQueue.main.async { if let t { self?.thumbnails[i] = t } }
            }
        }
    }
}

// MARK: - Views

struct AdjustEditorView: View {
    @ObservedObject var model: AdjustEditorModel
    let host: EditorWindowHost

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    preview
                    if model.inputs.count > 1 { filmstrip }
                }
                .padding(14)
                Divider()
                AdjustSidebar(model: model)
                    .frame(width: 300)
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 840, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.82))
            Group {
                if let img = model.displayed {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                } else if let err = model.loadError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showOriginal {
                Text("Original")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KQTheme.onAccentProminent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(KQTheme.accentProminentFill))
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.inputs.enumerated()), id: \.offset) { i, url in
                    Button { model.index = i } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                            if let t = model.thumbnails[i] {
                                Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: 72, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(i == model.index ? KQTheme.accent : Color.primary.opacity(0.1),
                                          lineWidth: i == model.index ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(url.lastPathComponent)
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
        .frame(height: 60)
    }

    private var bottomBar: some View {
        EditorFooter(host: host, saveTitle: model.inputs.count > 1 ? Lp("Save %d Images", model.inputs.count) : "Save") {
            if model.inputs.count > 1 {
                EditorFileInfo(name: model.inputs[model.index].lastPathComponent,
                               detail: Text(L("%d of %d · settings apply to all", model.index + 1, model.inputs.count)))
            } else {
                EditorFileInfo(name: model.inputs[0].lastPathComponent)
            }
        } accessory: {
            HStack(spacing: 6) {
                ImageCanvasIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) { model.undo() }
                ImageCanvasIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) { model.redo() }
            }
            Button("Reset All") { model.resetAll() }
                .buttonStyle(KQSecondaryButtonStyle())
                .disabled(model.settings.isNeutral)
            AdjustCompareButton(model: model)
            Text("Hold \\ to compare")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.trailing, 12)
        }
    }
}

/// Press and hold to show the original.
struct AdjustCompareButton: View {
    @ObservedObject var model: AdjustEditorModel

    var body: some View {
        Label("Compare", systemImage: "square.split.2x1")
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.showOriginal ? KQTheme.accent.opacity(0.25) : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in model.setCompare(true) }
                .onEnded { _ in model.setCompare(false) })
            .help("Hold to show the original")
    }
}

struct AdjustSidebar: View {
    @ObservedObject var model: AdjustEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Presets").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(AdjustPreset.all) { preset in
                        Button { model.apply(preset) } label: {
                            Text(preset.title)
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .foregroundStyle(model.activePreset == preset.name ? KQTheme.onAccentProminent : Color.primary)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(model.activePreset == preset.name ? KQTheme.accentProminentFill : Color.primary.opacity(0.07)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(AdjustGroup.allCases) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(group.title, systemImage: group.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(KQTheme.accentText)
                        ForEach(group.params) { p in
                            AdjustSliderRow(param: p, value: model.binding(p))
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(14)
        }
    }
}

struct AdjustSliderRow: View {
    let param: AdjustParam
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 1) {
            HStack {
                Text(param.title)
                    .font(.system(size: 12))
                    .onTapGesture(count: 2) { value = 0 }
                Spacer()
                Text(param.display(value))
                    .font(.system(size: 11, weight: value == 0 ? .regular : .semibold).monospacedDigit())
                    .foregroundStyle(value == 0 ? Color.secondary : KQTheme.accentText)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(value == 0 ? 0 : 0.06)))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { value = 0 }
                    .help("Double-click to reset")
            }
            ZStack {
                if param.isBipolar {
                    Capsule().fill(Color.secondary.opacity(0.55)).frame(width: 2, height: 9)
                }
                Slider(value: $value, in: param.range)
                    .controlSize(.mini)
                    .tint(KQTheme.accent)
            }
        }
    }
}

// MARK: - Window

@MainActor
final class AdjustEditorSession {
    let model: AdjustEditorModel
    let host: EditorWindowHost

    init(inputs: [URL], completion: @escaping EditorCompletion) {
        model = AdjustEditorModel(inputs: inputs)
        host = EditorWindowHost(title: inputs.count > 1 ? Lp("Adjust %d Images", inputs.count) : L("Adjust – %@", inputs[0].lastPathComponent),
                                minSize: NSSize(width: 840, height: 560), completion: completion)
        let model = self.model
        host.hasUnsavedChanges = { model.hasUnsavedChanges }
        host.makeExport = { AdjustPipeline.makeExport(inputs: model.inputs, settings: model.settings) }
        host.undo = { model.undo() }
        host.redo = { model.redo() }
        // Hold "\" to compare with the original.
        let compare: (NSEvent) -> Bool = { event in
            guard event.charactersIgnoringModifiers == "\\", EditorKeys.isPlain(event) else { return false }
            model.setCompare(event.type == .keyDown)
            return true
        }
        host.keyHandler = compare
        host.keyUpHandler = compare
        host.owner = self
    }

    func show() {
        host.show(AdjustEditorView(model: model, host: host))
    }
}
