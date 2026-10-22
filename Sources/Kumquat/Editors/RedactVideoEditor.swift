import AppKit
import SwiftUI

/// Redact Video: draw blur / pixelate / solid rectangles on a video, each with its own time range,
/// and export a new "(redacted)" copy with one ffmpeg filtergraph.
@MainActor
enum RedactVideoEditor {
    /// Opens the editor window for `inputs`. Calls `completion` exactly once (nil = cancelled).
    static func present(inputs: [URL], completion: @escaping EditorCompletion) {
        guard let url = inputs.first else {
            completion(nil)
            return
        }
        RedactVideoSession(url: url, completion: completion).show()
    }
}

@MainActor
final class RedactVideoSession {
    let model: RedactVideoModel
    let host: EditorWindowHost

    init(url: URL, completion: @escaping EditorCompletion) {
        let model = RedactVideoModel(url: url)
        self.model = model
        host = EditorWindowHost(title: L("Redact Video — %@", url.lastPathComponent),
                                minSize: NSSize(width: 820, height: 560), completion: completion)
        host.hasUnsavedChanges = { model.hasUnsavedChanges }
        host.canSave = { model.isLoaded && !model.regions.isEmpty }
        host.makeExport = {
            guard let job = model.exportJob(), !job.regions.isEmpty else { return nil }
            return { progress in try await RedactVideoExport.run(job, progress: progress) }
        }
        host.undo = { model.undo() }
        host.redo = { model.redo() }
        host.playPause = { model.togglePlay() }
        host.keyHandler = { event in Self.handleKey(event, model: model) }
        host.teardown = { model.close() }
        host.owner = self
    }

    func show() {
        host.show(RedactVideoEditorView(model: model, host: host))
        model.load()
    }

    /// Space, ⌘S, Esc and ⌘Z are handled by the window host.
    private static func handleKey(_ event: NSEvent, model: RedactVideoModel) -> Bool {
        guard EditorKeys.isPlain(event) else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let fps = model.info?.fps ?? 0
        let frameStep = fps > 0 ? 1 / fps : 1.0 / 30
        switch event.keyCode {
        case EditorKeys.delete, EditorKeys.forwardDelete: model.deleteSelected(); return true
        case EditorKeys.left: model.seek(to: model.currentTime - (shift ? 1 : frameStep)); return true
        case EditorKeys.right: model.seek(to: model.currentTime + (shift ? 1 : frameStep)); return true
        default: return false
        }
    }
}

// MARK: - SwiftUI

struct RedactVideoEditorView: View {
    @ObservedObject var model: RedactVideoModel
    let host: EditorWindowHost

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    RedactVideoCanvas(model: model)
                        .frame(minWidth: 480, minHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    transport
                    ScrollView(.vertical) {
                        RedactVideoTimeline(model: model)
                            .frame(height: RedactVideoTimelineView.height(rows: model.regions.count))
                    }
                    .frame(height: min(RedactVideoTimelineView.height(rows: model.regions.count), 210))
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04)))
                }
                .padding(KQTheme.padding)
                Divider()
                RedactVideoInspector(model: model)
                    .frame(width: 260)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button(action: { model.togglePlay() }) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(KQSecondaryButtonStyle())
            .disabled(!model.isLoaded)
            .help("Play / Pause (Space)")
            Text(verbatim: "\(TimelineClockText.format(model.currentTime)) / \(TimelineClockText.format(model.duration))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            if model.usesFrameFallback {
                Text("Preview via ffmpeg frames")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("Drag on the video to add a rectangle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        EditorFooter(host: host, canSave: model.isLoaded && !model.regions.isEmpty) {
            EditorFileInfo(name: model.url.lastPathComponent, detail: footerDetail)
        }
    }

    private var footerDetail: Text {
        if let status = model.status { return Text(status) }
        return Text("Space play · ⌫ delete · ⌘Z undo · ←/→ step")
    }
}

struct RedactVideoInspector: View {
    @ObservedObject var model: RedactVideoModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Redact Video")
                    .font(.system(size: 15, weight: .semibold))
                Button(action: { model.detectFaces() }) {
                    Label(model.isDetecting ? L("Detecting…") : L("Detect faces in this frame"),
                          systemImage: "person.crop.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KQSecondaryButtonStyle())
                .disabled(!model.isLoaded || model.isDetecting)

                HStack(spacing: 8) {
                    Button(action: { model.undo() }) { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(KQSecondaryButtonStyle())
                        .disabled(!model.canUndo)
                        .help("Undo (⌘Z)")
                    Button(action: { model.redo() }) { Image(systemName: "arrow.uturn.forward") }
                        .buttonStyle(KQSecondaryButtonStyle())
                        .disabled(!model.canRedo)
                        .help("Redo (⇧⌘Z)")
                    Spacer()
                    Text(Lp("%d layers", model.regions.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider()

                if let region = model.selectedRegion, let index = model.selectedIndex {
                    selectedEditor(region, index: index)
                } else {
                    Text("Select a rectangle on the video or a bar in the timeline to change its style and time range.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(KQTheme.padding)
        }
    }

    @ViewBuilder
    private func selectedEditor(_ region: RedactVideoRegion, index: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: RedactVideoModel.tintColor(region.tint)))
                .frame(width: 10, height: 10)
            Text(L("Layer %d", index + 1))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: { model.deleteSelected() }) { Image(systemName: "trash") }
                .buttonStyle(KQSecondaryButtonStyle())
                .help("Delete (⌫)")
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Style").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { model.selectedRegion?.style ?? .blur },
                                          set: { v in model.editSelected { $0.style = v } })) {
                Text("Blur").tag(RedactionStyle.blur)
                Text("Pixelate").tag(RedactionStyle.pixelate)
                Text("Solid").tag(RedactionStyle.solid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        if region.style == .solid {
            ColorPicker("Colour", selection: Binding(
                get: { Color(nsColor: model.selectedRegion?.color.nsColor ?? .black) },
                set: { c in model.editSelected(coalesce: "color") { $0.color = RedactVideoRGB(NSColor(c)) } }),
                supportsOpacity: false)
                .font(.system(size: 12))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Strength").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: "\(Int((region.strength * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { model.selectedRegion?.strength ?? 0.6 },
                                      set: { v in model.editSelected(coalesce: "strength") { $0.strength = v } }),
                       in: 0...1)
                    .tint(KQTheme.accent)
            }
        }

        Divider()

        Toggle("Show for entire video", isOn: Binding(
            get: { model.selectedRegion?.entireVideo ?? false },
            set: { v in
                model.editSelected { r in
                    r.entireVideo = v
                    if !v, r.end - r.start < 0.05 { r.start = 0; r.end = model.duration }
                }
            }))
            .toggleStyle(.switch)
            .tint(KQTheme.accent)
            .font(.system(size: 12))

        let range = region.range(duration: model.duration)
        VStack(alignment: .leading, spacing: 8) {
            timeRow("Start", range.lowerBound) {
                let t = model.currentTime
                model.editSelected { r in
                    let end = r.range(duration: model.duration).upperBound
                    r.entireVideo = false
                    r.end = end
                    r.start = min(t, max(0, end - 0.05))
                }
            }
            timeRow("End", range.upperBound) {
                let t = model.currentTime
                model.editSelected { r in
                    let start = r.range(duration: model.duration).lowerBound
                    r.entireVideo = false
                    r.start = start
                    r.end = max(t, start + 0.05)
                }
            }
        }
        .opacity(region.entireVideo ? 0.5 : 1)

        Text("Drag the bar in the timeline to move the range, or its ends to change start and end.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func timeRow(_ title: String, _ t: Double, setToPlayhead: @escaping () -> Void) -> some View {
        HStack {
            Text(L(title))
                .font(.system(size: 12))
                .frame(width: 52, alignment: .leading)
            Text(TimelineClockText.format(t))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            Spacer()
            Button("Set to playhead", action: setToPlayhead)
                .buttonStyle(KQSecondaryButtonStyle())
                .font(.system(size: 11))
        }
    }
}
