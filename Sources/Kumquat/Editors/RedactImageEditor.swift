import AppKit
import SwiftUI

/// Redaction editor: draw blur / pixelate / solid boxes, or detect faces and text automatically.
@MainActor
enum RedactImageEditor {
    /// Opens the editor window for `inputs`. Calls `completion` exactly once (nil = cancelled).
    static func present(inputs: [URL], completion: @escaping EditorCompletion) {
        guard let url = inputs.first else { completion(nil); return }
        do {
            let session = try makeSession(url: url, ignoredCount: inputs.count - 1, completion: completion)
            session.show()
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Can't redact %@", url.lastPathComponent)
            alert.informativeText = error.localizedDescription
            KQWindowing.activate()
            alert.runModal()
            completion(nil)
        }
    }

    /// Builds (but does not show) the editor for `url`.
    static func makeSession(url: URL, ignoredCount: Int, completion: @escaping EditorCompletion) throws -> RedactImageSession {
        let (loaded, preview) = try ImageCanvasIO.load(url)
        let model = RedactImageModel(url: url, image: loaded.image, preview: preview, ignoredCount: ignoredCount)
        return RedactImageSession(model: model, completion: completion)
    }
}

@MainActor
final class RedactImageSession {
    let model: RedactImageModel
    let canvas: RedactImageCanvasView
    let host: EditorWindowHost

    init(model: RedactImageModel, completion: @escaping EditorCompletion) {
        self.model = model
        canvas = RedactImageCanvasView(model: model)
        host = EditorWindowHost(title: L("Redact — %@", model.sourceURL.lastPathComponent),
                                minSize: NSSize(width: 760, height: 520), completion: completion)
        host.hasUnsavedChanges = { [weak model] in model?.hasUnsavedChanges ?? false }
        host.makeExport = { [weak model] in model?.makeExport() }
        host.undo = { [weak model] in model?.undo() }
        host.redo = { [weak model] in model?.redo() }
        host.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        host.owner = self
    }

    var rootView: RedactImageEditorView {
        RedactImageEditorView(model: model, canvas: canvas, host: host)
    }

    func show() {
        host.show(rootView)
        host.window.makeFirstResponder(canvas)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let canvas = self.canvas, model = self.model
        return ImageCanvasKeys.handle(event, .init(
            deleteSelection: { model.deleteSelected() },
            zoomIn: { canvas.zoomIn() },
            zoomOut: { canvas.zoomOut() },
            zoomFit: { canvas.zoomToFit() },
            nudge: { dx, dy in canvas.nudgeSelection(dx, dy) },
            character: { ch in
                switch ch {
                case "b": model.applyStyle(.blur)
                case "p": model.applyStyle(.pixelate)
                case "s": model.applyStyle(.solid)
                default: return false
                }
                return true
            }))
    }
}

struct RedactImageEditorView: View {
    @ObservedObject var model: RedactImageModel
    let canvas: RedactImageCanvasView
    let host: EditorWindowHost

    private static let solidColors: [ImageCanvasRGBA] = [.black, .white, .orange, .red, .blue]

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            styleRow
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            ImageCanvasHost(view: canvas)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(VisualEffectBackground(material: .windowBackground, blending: .behindWindow))
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(KQTheme.accentText)
            Text("Drag over sensitive areas to hide them")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button { model.detectFaces() } label: { Label("Detect Faces", systemImage: "face.dashed") }
                .buttonStyle(KQSecondaryButtonStyle())
                .disabled(model.busy != nil)
            Button { model.detectText() } label: { Label("Detect Text", systemImage: "text.viewfinder") }
                .buttonStyle(KQSecondaryButtonStyle())
                .disabled(model.busy != nil)
            Divider().frame(height: 18)
            ImageCanvasIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) { model.undo() }
            ImageCanvasIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) { model.redo() }
            ImageCanvasIconButton(symbol: "trash", help: "Delete Selection (⌫)", enabled: model.selectedID != nil) { model.deleteSelected() }
            Button("Clear All") { model.clearAll() }
                .buttonStyle(KQSecondaryButtonStyle())
                .disabled(model.regions.isEmpty)
        }
    }

    private var styleRow: some View {
        HStack(spacing: 14) {
            Picker("", selection: Binding(get: { model.style }, set: { model.applyStyle($0) })) {
                Text("Blur").tag(RedactionStyle.blur)
                Text("Pixelate").tag(RedactionStyle.pixelate)
                Text("Solid").tag(RedactionStyle.solid)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)

            if model.style == .solid {
                ImageCanvasColorRow(colors: Self.solidColors, selection: model.solidColor) { model.applyColor($0) }
            } else {
                HStack(spacing: 8) {
                    Text("Strength").foregroundStyle(.secondary).fixedSize()
                    Slider(value: Binding(get: { model.strength }, set: { model.applyStrength($0) }), in: 0...1)
                        .frame(width: 160)
                    Text(verbatim: "\(Int((model.strength * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                }
            }
            Button("Apply to All") { model.applyStyleToAll() }
                .buttonStyle(KQSecondaryButtonStyle())
                .fixedSize()
                .disabled(model.regions.count < 2)
                .help("Use this style for every region")
            Spacer(minLength: 0)
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary).lineLimit(1)
            } else if let status = model.status {
                Text(status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            }
        }
        .font(.system(size: 12))
        .frame(height: 26)
    }

    private var bottomBar: some View {
        EditorFooter(host: host, saveHelp: "Save a redacted copy next to the original (⌘S)") {
            EditorFileInfo(name: model.sourceURL.lastPathComponent, detail: Text(infoLine),
                           highlightDetail: model.ignoredCount > 0)
        } accessory: {
            ImageCanvasZoomControls(percent: model.zoomPercent,
                                    fit: { canvas.zoomToFit() },
                                    zoomIn: { canvas.zoomIn() },
                                    zoomOut: { canvas.zoomOut() })
                .padding(.trailing, 12)
        }
    }

    private var infoLine: String {
        var s = "\(Int(model.imageSize.width))×\(Int(model.imageSize.height)) px · " + Lp("%d regions", model.regions.count)
        if model.ignoredCount > 0 {
            s += " · " + Lp("editing the first file only, %d other files ignored", model.ignoredCount)
        }
        return s
    }
}
