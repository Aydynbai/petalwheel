import AppKit
import SwiftUI

// MARK: - Models

/// Draft of a preset being added or edited.
final class PresetDraft: ObservableObject {
    let id: UUID
    let isNew: Bool
    @Published var name: String
    @Published var action: PresetAction
    @Published var toolOptions: ToolOptions
    @Published var conversion: ConversionOptions
    @Published var downmixToMono: Bool
    @Published var symbolName: String?
    /// Restrict the preset to inputs of this group (nil = any input the action accepts).
    @Published var onlyFor: FormatGroup?
    /// Compress: target size text (MB), empty = use quality.
    @Published var useTargetSize: Bool
    @Published var targetSizeMB: String

    init(_ preset: UserPreset, isNew: Bool) {
        id = preset.id
        self.isNew = isNew
        name = preset.name
        action = preset.action
        toolOptions = preset.tool.options
        conversion = preset.conversion.options
        downmixToMono = preset.downmixToMono
        symbolName = preset.symbolName
        onlyFor = preset.onlyFor?.first.flatMap(FormatGroup.init(rawValue:))
        let kb = preset.tool.targetSizeKB
        useTargetSize = kb != nil
        targetSizeMB = kb.map { Self.formatMB($0) } ?? "2"
    }

    static func formatMB(_ kb: Int) -> String {
        let mb = Double(kb) / 1024
        return mb == mb.rounded() ? String(Int(mb)) : String(format: "%.2g", mb)
    }

    var targetSizeKB: Int? {
        guard useTargetSize else { return nil }
        let t = targetSizeMB.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), v > 0 else { return nil }
        return max(1, Int((v * 1024).rounded()))
    }

    var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return L("Give the preset a name.") }
        if action.tool == .compress && useTargetSize && targetSizeKB == nil { return L("Enter a target size greater than zero.") }
        return nil
    }

    var result: UserPreset {
        var o = toolOptions
        if action.tool == .compress { o.targetSizeKB = targetSizeKB }
        let mono = action.format?.group == .audio ? downmixToMono : false
        return UserPreset(id: id, name: name.trimmingCharacters(in: .whitespaces), action: action,
                          conversion: conversion, tool: o, downmixToMono: mono, symbolName: symbolName,
                          onlyFor: onlyFor.map { [$0] })
    }
}

final class PresetsSettingsModel: ObservableObject {
    @Published var selection: UUID?
    @Published var draft: PresetDraft?
    @Published var isEditing = false

    func add(_ action: PresetAction) {
        let preset = UserPreset(name: Self.defaultName(for: action), action: action)
        draft = PresetDraft(preset, isNew: true)
        isEditing = true
    }

    func edit(_ preset: UserPreset) {
        draft = PresetDraft(preset, isNew: false)
        isEditing = true
    }

    func save(to store: PresetStore) {
        guard let draft, draft.validationError == nil else { return }
        store.upsert(draft.result)
        selection = draft.id
        isEditing = false
    }

    static func defaultName(for action: PresetAction) -> String {
        if let f = action.format { return L("To %@", f.title) }
        return action.tool?.title ?? L("New Preset")
    }
}

// MARK: - Settings tab

/// Settings tab: list, add, edit and delete user presets ("my recipes").
struct PresetsSettingsView: View {
    @ObservedObject var store: PresetStore = .shared
    @StateObject private var model = PresetsSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Presets run a conversion or tool with saved options, straight from the wheel's Presets category.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $model.selection) {
                ForEach(store.presets) { preset in
                    PresetRow(preset: preset)
                        .tag(preset.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.edit(preset) }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if store.presets.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "star").font(.system(size: 22)).foregroundStyle(.secondary)
                        Text("No presets yet").font(.system(size: 12, weight: .medium))
                        Text("Add one with the + menu below.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))

            HStack(spacing: 8) {
                PresetActionMenu(label: { Label("Add", systemImage: "plus") }) { model.add($0) }
                    .fixedSize()
                Button {
                    if let p = selected { model.edit(p) }
                } label: { Label("Edit", systemImage: "pencil") }
                    .disabled(selected == nil)
                Button {
                    if let id = model.selection { store.delete(id); model.selection = nil }
                } label: { Label("Delete", systemImage: "trash") }
                    .disabled(selected == nil)
                Spacer()
                Menu {
                    Button("Restore Starter Presets") { store.restoreDefaults() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            .controlSize(.regular)
        }
        .sheet(isPresented: $model.isEditing) {
            if let draft = model.draft {
                PresetEditorView(draft: draft,
                                 onCancel: { model.isEditing = false },
                                 onSave: { model.save(to: store) })
            }
        }
    }

    private var selected: UserPreset? { model.selection.flatMap(store.preset) }
}

struct PresetRow: View {
    let preset: UserPreset

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: preset.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(KQTheme.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(preset.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// A menu listing every conversion target and unattended tool.
struct PresetActionMenu<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var onPick: (PresetAction) -> Void

    var body: some View {
        Menu {
            Menu("Convert to") {
                ForEach(FormatGroup.allCases, id: \.self) { group in
                    let formats = FileFormat.allCases.filter { $0.group == group }
                    if !formats.isEmpty {
                        Section(group.title) {
                            ForEach(formats) { f in
                                Button(f.title) { onPick(.convert(f)) }
                            }
                        }
                    }
                }
            }
            ForEach(Self.toolCategories, id: \.self) { category in
                let tools = category.tools.filter { !$0.isInteractive }
                if !tools.isEmpty {
                    Menu(category.title) {
                        ForEach(tools) { t in
                            Button { onPick(.tool(t)) } label: { SwiftUI.Label(t.title, systemImage: t.symbol) }
                        }
                    }
                }
            }
        } label: {
            label()
        }
    }

    static var toolCategories: [FanCategory] { [.optimize, .edit, .combine, .extract] }
}

// MARK: - Editor

struct PresetEditorView: View {
    @ObservedObject var draft: PresetDraft
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            HStack(spacing: 10) {
                Image(systemName: draft.result.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(KQTheme.gradient))
                Text(draft.isNew ? L("New Preset") : L("Edit Preset"))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
            }

            OptionRow("Name") {
                TextField("Preset name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            OptionRow("Action") {
                PresetActionMenu(label: { Text(draft.action.title) }) { draft.action = $0 }
                    .fixedSize()
            }

            OptionRow("Show for") {
                Picker("", selection: $draft.onlyFor) {
                    Text("Any file it works on").tag(FormatGroup?.none)
                    ForEach(FormatGroup.allCases, id: \.self) { Text($0.title).tag(FormatGroup?.some($0)) }
                }
                .labelsHidden().fixedSize()
            }

            Divider()

            controls
                .frame(maxWidth: .infinity, alignment: .leading)

            if let err = draft.validationError {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(KQTheme.danger)
            }

            HStack {
                Text(draft.result.summary)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(KQSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? L("Add") : L("Save"), action: onSave)
                    .buttonStyle(KQProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.validationError != nil)
                    .opacity(draft.validationError != nil ? 0.5 : 1)
            }
        }
        .padding(20)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .tint(KQTheme.accent)
    }

    @ViewBuilder private var controls: some View {
        if let f = draft.action.format {
            conversionControls(f)
        } else if let t = draft.action.tool {
            toolControls(t)
        }
    }

    // MARK: Conversion

    @ViewBuilder private func conversionControls(_ f: FileFormat) -> some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            OptionRow("Quality") {
                Picker("", selection: $draft.conversion.quality) {
                    ForEach(Quality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if f.group == .audio || (f.group == .video && f != .gif) {
                OptionRow("Audio bitrate") {
                    Picker("", selection: $draft.conversion.audioBitrateKbps) {
                        ForEach([64, 96, 128, 192, 256, 320], id: \.self) { Text(verbatim: "\($0) kbps").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if f.group == .video {
                OptionRow("Max height") {
                    Picker("", selection: $draft.conversion.videoMaxHeight) {
                        Text("Keep original").tag(Int?.none)
                        ForEach([2160, 1080, 720, 480], id: \.self) { Text(verbatim: "\($0)p").tag(Int?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if f.group == .audio {
                Toggle("Mix down to mono", isOn: $draft.downmixToMono)
            }
            Toggle("Preserve metadata", isOn: $draft.conversion.preserveMetadata)
        }
    }

    // MARK: Tools

    @ViewBuilder private func toolControls(_ t: FileTool) -> some View {
        switch t {
        case .compress:
            VStack(alignment: .leading, spacing: KQTheme.spacing) {
                OptionRow("Quality") {
                    Picker("", selection: $draft.toolOptions.quality) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(draft.useTargetSize)
                }
                HStack {
                    Toggle("Target size", isOn: $draft.useTargetSize)
                    TextField("2", text: $draft.targetSizeMB)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .disabled(!draft.useTargetSize)
                    Text("MB").foregroundStyle(.secondary)
                }
            }
        case .cropImage, .cropVideo:
            OptionRow("Aspect ratio") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(AspectRatio.allCases) { ratio in
                        AspectChip(ratio: ratio, selected: draft.toolOptions.aspect == ratio) {
                            draft.toolOptions.aspect = ratio
                        }
                    }
                }
            }
        case .frameImage:
            VStack(alignment: .leading, spacing: KQTheme.spacing) {
                SliderRow(title: "Padding", value: $draft.toolOptions.padding, range: 0...300, step: 4, unit: "px")
                SliderRow(title: "Corner radius", value: $draft.toolOptions.cornerRadius, range: 0...120, step: 2, unit: "px")
                Toggle("Shadow", isOn: $draft.toolOptions.shadow)
                ColorPicker("Background", selection: Binding(
                    get: { Color(nsColor: draft.toolOptions.backgroundColor) },
                    set: { draft.toolOptions.backgroundColor = NSColor($0) }), supportsOpacity: true)
            }
        case .blurFaces:
            stylePicker
        case .createCollage:
            VStack(alignment: .leading, spacing: KQTheme.spacing) {
                Stepper(L("Columns: %d", draft.toolOptions.collageColumns), value: $draft.toolOptions.collageColumns, in: 1...8)
                SliderRow(title: "Spacing", value: $draft.toolOptions.collageSpacing, range: 0...80, step: 2, unit: "px")
            }
        case .changeVideoSpeed:
            OptionRow("Speed") {
                Picker("", selection: $draft.toolOptions.speed) {
                    ForEach([0.25, 0.5, 1.5, 2, 4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        case .videoSnapshots:
            Stepper(L("Frames: %d", draft.toolOptions.snapshotCount), value: $draft.toolOptions.snapshotCount, in: 1...60)
        case .splitVideo:
            Stepper(L("Parts: %d", draft.toolOptions.splitParts), value: $draft.toolOptions.splitParts, in: 2...20)
        case .normalizeAudio:
            SliderRow(title: "Loudness", value: $draft.toolOptions.loudnessLUFS, range: -30...(-8), step: 1, unit: "LUFS")
        case .audioChannels:
            OptionRow("Channels") {
                Picker("", selection: $draft.toolOptions.mono) {
                    Text("Mono").tag(true)
                    Text("Stereo").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        case .trimSilence:
            SliderRow(title: "Silence below", value: $draft.toolOptions.silenceThresholdDB, range: -70...(-20), step: 1, unit: "dB")
        default:
            Text("This tool has no options.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var stylePicker: some View {
        OptionRow("Style") {
            Picker("", selection: $draft.toolOptions.faceBlurStyle) {
                ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }
}
