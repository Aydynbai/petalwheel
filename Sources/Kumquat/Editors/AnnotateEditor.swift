import AppKit
import SwiftUI

/// Markup editor: arrows, pen, shapes, highlighter, text, numbered steps, magnifier and image stickers.
@MainActor
enum AnnotateEditor {
    /// Opens the editor window for `inputs`. Calls `completion` exactly once (nil = cancelled).
    static func present(inputs: [URL], completion: @escaping EditorCompletion) {
        guard let url = inputs.first else { completion(nil); return }
        do {
            let session = try makeSession(url: url, ignoredCount: inputs.count - 1, completion: completion)
            session.show()
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Can't annotate %@", url.lastPathComponent)
            alert.informativeText = error.localizedDescription
            KQWindowing.activate()
            alert.runModal()
            completion(nil)
        }
    }

    /// Builds (but does not show) the editor for `url`.
    static func makeSession(url: URL, ignoredCount: Int, completion: @escaping EditorCompletion) throws -> AnnotateSession {
        let (loaded, preview) = try ImageCanvasIO.load(url)
        let model = AnnotateModel(url: url, image: loaded, preview: preview, ignoredCount: ignoredCount)
        return AnnotateSession(model: model, completion: completion)
    }
}

@MainActor
final class AnnotateSession {
    let model: AnnotateModel
    let canvas: AnnotateCanvasView
    let host: EditorWindowHost

    init(model: AnnotateModel, completion: @escaping EditorCompletion) {
        self.model = model
        canvas = AnnotateCanvasView(model: model)
        host = EditorWindowHost(title: L("Annotate – %@", model.sourceURL.lastPathComponent),
                                minSize: NSSize(width: 760, height: 520), completion: completion)
        let canvas = self.canvas
        host.hasUnsavedChanges = { [weak model] in model?.hasUnsavedChanges ?? false }
        host.willSave = { canvas.endTextEditing() }
        host.makeExport = { [weak model] in model?.makeExport() }
        host.undo = { [weak model] in canvas.endTextEditing(); model?.undo() }
        host.redo = { [weak model] in canvas.endTextEditing(); model?.redo() }
        host.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        host.owner = self
    }

    var rootView: AnnotateEditorView {
        AnnotateEditorView(model: model, canvas: canvas, host: host)
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
            paste: { canvas.pasteSticker() },
            character: { ch in
                guard let tool = AnnotateTool.allCases.first(where: { $0.shortcut == ch }) else { return false }
                model.tool = tool
                canvas.toolChanged()
                return true
            }))
    }
}

struct AnnotateEditorView: View {
    @ObservedObject var model: AnnotateModel
    let canvas: AnnotateCanvasView
    let host: EditorWindowHost

    private static let mainTools: [AnnotateTool] = [.select, .arrow, .pen, .rectangle, .ellipse, .highlighter, .text, .step, .magnifier]

    var body: some View {
        VStack(spacing: 0) {
            toolRow
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

    // MARK: Rows

    private var toolRow: some View {
        HStack(spacing: 4) {
            ForEach(Self.mainTools) { tool in
                ImageCanvasToolButton(symbol: tool.symbol, help: tool.title, selected: model.tool == tool) {
                    model.tool = tool
                    canvas.toolChanged()
                }
            }
            Menu {
                Button("Choose Image…") { canvas.chooseSticker() }
                Button("Paste Image (⌘V)") { canvas.pasteSticker() }
            } label: {
                Image(systemName: AnnotateTool.sticker.symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .padding(.leading, 4)
            .help("Image Sticker: choose a file or paste (⌘V)")

            Spacer(minLength: 12)

            ImageCanvasIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) {
                canvas.endTextEditing(); model.undo()
            }
            ImageCanvasIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) {
                canvas.endTextEditing(); model.redo()
            }
            ImageCanvasIconButton(symbol: "trash", help: "Delete Selection (⌫)", enabled: model.selectedID != nil) {
                model.deleteSelected()
            }
            Button("Clear All") { canvas.endTextEditing(); model.clearAll() }
                .buttonStyle(KQSecondaryButtonStyle())
                .disabled(model.items.isEmpty)
        }
    }

    private var styleRow: some View {
        HStack(spacing: 14) {
            ImageCanvasColorRow(colors: ImageCanvasRGBA.palette, selection: model.color) { model.applyColor($0) }
            Divider().frame(height: 18)
            contextualControls
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .font(.system(size: 12))
    }

    @ViewBuilder private var contextualControls: some View {
        switch model.styleContext {
        case .text:
            HStack(spacing: 8) {
                Text("Size").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.fontSize }, set: { model.applyFontSize($0) }), in: 10...160)
                    .frame(width: 130)
                Text(verbatim: "\(Int(model.fontSize))").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                Picker("", selection: Binding(get: { model.fontFamily }, set: { model.applyFontFamily($0) })) {
                    ForEach(AnnotateFontFamily.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
        case .magnifier:
            HStack(spacing: 8) {
                widthSlider
                Text("Zoom").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.magnifierZoom }, set: { model.applyMagnifierZoom($0) }), in: 1.25...6)
                    .frame(width: 120)
                Text(String(format: "%.1f×", model.magnifierZoom)).monospacedDigit().foregroundStyle(.secondary)
            }
        case .sticker:
            HStack(spacing: 8) {
                Button("Choose Image…") { canvas.chooseSticker() }.buttonStyle(KQSecondaryButtonStyle())
                Button("Paste") { canvas.pasteSticker() }.buttonStyle(KQSecondaryButtonStyle())
                Text("Drag corners to resize (⇧ for free aspect)").foregroundStyle(.secondary)
            }
        case .step:
            HStack(spacing: 8) {
                widthSlider
                Text(L("Next: %d", model.nextStepNumber)).foregroundStyle(.secondary)
            }
        default:
            widthSlider
        }
    }

    private var widthSlider: some View {
        HStack(spacing: 8) {
            Text(model.styleContext == .step ? L("Size") : L("Width")).foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.widthLevel }, set: { model.applyWidth($0) }), in: 1...20)
                .frame(width: 130)
            Text(verbatim: "\(Int(model.widthLevel.rounded()))").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
        }
    }

    private var bottomBar: some View {
        EditorFooter(host: host, saveHelp: "Save a flattened copy next to the original (⌘S)") {
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
        var s = "\(Int(model.imageSize.width))×\(Int(model.imageSize.height)) px"
        if model.ignoredCount > 0 {
            s += " · " + Lp("editing the first file only, %d other files ignored", model.ignoredCount)
        }
        return s
    }
}
