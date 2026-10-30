import AppKit
import SwiftUI
import AVFoundation

/// Presents tool options in a floating panel near the mouse.
@MainActor
enum ToolOptionsPanel {
    private static var active: [ToolOptionsPanelController] = []

    /// Presents a floating panel with the options relevant to `tool`. completion(nil) = cancelled.
    static func present(tool: FileTool, inputs: [URL], initial: ToolOptions, completion: @escaping (ToolOptions?) -> Void) {
        if tool == .compress, !inputs.isEmpty,
           inputs.allSatisfy({ FileFormat.detect($0)?.group == .video && FileFormat.detect($0) != .gif }) {
            NurToCompressionPanel.present(inputs: inputs, initial: initial, completion: completion)
            return
        }
        let controller = ToolOptionsPanelController(tool: tool, inputs: inputs, initial: initial)
        controller.onDone = { [weak controller] result in
            completion(result)
            if let controller { active.removeAll { $0 === controller } }
        }
        active.append(controller)
        controller.show()
    }
}

// MARK: - Model

final class ToolOptionsModel: ObservableObject {
    let tool: FileTool
    let inputs: [URL]
    @Published var options: ToolOptions
    @Published var thumbnail: NSImage?
    @Published var duration: Double?

    // compress → target size
    @Published var useTargetSize: Bool
    @Published var targetSizeText: String
    @Published var targetUnitMB: Bool

    // trim
    @Published var trimStartText: String
    @Published var trimEndText: String

    // archives: the password asked for just failed
    var archivePasswordWasWrong = false

    init(tool: FileTool, inputs: [URL], initial: ToolOptions) {
        self.tool = tool
        self.inputs = inputs
        var prepared = initial
        prepared.videoCompressionMode = nil
        if tool == .compress && inputs.allSatisfy({ FileFormat.detect($0)?.group == .video && FileFormat.detect($0) != .gif }) {
            prepared.videoCompressionMode = initial.videoCompressionMode ?? .fast
        }
        self.options = prepared
        if let kb = initial.targetSizeKB, kb > 0 {
            useTargetSize = true
            if kb >= 1024 && kb % 1024 == 0 {
                targetUnitMB = true
                targetSizeText = String(kb / 1024)
            } else {
                targetUnitMB = false
                targetSizeText = String(kb)
            }
        } else {
            useTargetSize = false
            targetUnitMB = true
            targetSizeText = "2"
        }
        trimStartText = TimeText.format(initial.trimStart)
        trimEndText = initial.trimEnd.map(TimeText.format) ?? ""
        prepareArchiveOptions()   // archives
    }

    var trimStart: Double? { TimeText.parse(trimStartText) }
    var trimEnd: Double? { trimEndText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : TimeText.parse(trimEndText) }

    var targetSizeKB: Int? {
        guard useTargetSize else { return nil }
        let t = targetSizeText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), v > 0 else { return nil }
        return max(1, Int((targetUnitMB ? v * 1024 : v).rounded()))
    }

    /// Validation message, nil when Apply is allowed.
    var validationError: String? {
        switch tool {
        case .compress:
            if options.videoCompressionMode == nil && useTargetSize && targetSizeKB == nil { return L("Enter a target size greater than zero.") }
        case .trimMedia:
            guard let s = trimStart else { return L("Start time isn't valid. Use 1:23.5 or seconds.") }
            let endEmpty = trimEndText.trimmingCharacters(in: .whitespaces).isEmpty
            if !endEmpty {
                guard let e = trimEnd else { return L("End time isn't valid. Use 1:23.5 or seconds.") }
                if e <= s { return L("End must be after start.") }
                if let d = duration, s >= d { return L("Start is past the end of the media.") }
            } else if let d = duration, s >= d {
                return L("Start is past the end of the media.")
            }
        case .extractArchive, .testArchive, .listArchive:   // archives
            if (options.archivePassword ?? "").isEmpty { return L("Enter the password.") }
        default: break
        }
        return nil
    }

    func result() -> ToolOptions {
        var o = options
        switch tool {
        case .compress:
            o.targetSizeKB = o.videoCompressionMode == nil ? targetSizeKB : nil
        case .trimMedia:
            o.trimStart = max(0, trimStart ?? 0)
            var end = trimEnd
            if let e = end, let d = duration, e > d { end = d }
            o.trimEnd = end
        default: break
        }
        return o
    }

    func loadExtras() {
        guard let first = inputs.first else { return }
        Thumbnails.load(first, size: CGSize(width: 96, height: 96)) { [weak self] image in
            self?.thumbnail = image
        }
        if tool == .trimMedia {
            Task { @MainActor [weak self] in
                let asset = AVURLAsset(url: first)
                if let d = try? await asset.load(.duration), d.isNumeric {
                    let secs = CMTimeGetSeconds(d)
                    if secs.isFinite && secs > 0 {
                        self?.duration = secs
                        if let self, self.trimEndText.isEmpty { self.trimEndText = TimeText.format(secs) }
                    }
                }
            }
        }
    }
}

/// Parses and formats times like "1:23.5", "01:02:03" or "83.5".
enum TimeText {
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0, v.isFinite else { return nil }
            if i > 0 && v >= 60 { return nil }   // minutes/seconds components must be < 60
            total = total * 60 + v
        }
        return total
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
        let frac = seconds - Double(whole)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        var str = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        let tenths = Int((frac * 10).rounded())
        if tenths > 0 && tenths < 10 { str += ".\(tenths)" }
        return str
    }
}

// MARK: - Controller

@MainActor
final class ToolOptionsPanelController: NSObject, NSWindowDelegate {
    let model: ToolOptionsModel
    var onDone: ((ToolOptions?) -> Void)?
    private var panel: KQPanel?
    private var finished = false

    init(tool: FileTool, inputs: [URL], initial: ToolOptions) {
        model = ToolOptionsModel(tool: tool, inputs: inputs, initial: initial)
    }

    func show() {
        let view = ToolOptionsView(model: model,
                                   onCancel: { [weak self] in self?.finish(nil) },
                                   onApply: { [weak self] in
                                       guard let self, self.model.validationError == nil else { return }
                                       self.finish(self.model.result())
                                   })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = KQPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = model.tool.title
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.contentView = host
        p.delegate = self
        p.setFrame(KQWindowing.frameNearMouse(size: p.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size),
                   display: false)
        panel = p
        model.loadExtras()
        KQWindowing.activate()
        p.makeKeyAndOrderFront(nil)
    }

    private func finish(_ result: ToolOptions?) {
        guard !finished else { return }
        finished = true
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        onDone?(result)
        onDone = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { finish(nil) }
    }
}

// MARK: - View

struct ToolOptionsView: View {
    @ObservedObject var model: ToolOptionsModel
    var onCancel: () -> Void
    var onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing + 2) {
            header
            inputSummary
            Divider()
            controls
                .frame(maxWidth: .infinity, alignment: .leading)
            if let err = model.validationError {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(KQTheme.danger)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(KQSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: onApply)
                    .buttonStyle(KQProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.validationError != nil)
                    .opacity(model.validationError != nil ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffectBackground(material: .popover).ignoresSafeArea())
        .tint(KQTheme.accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.tool.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(KQTheme.gradient))
            Text(model.tool.title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
        }
    }

    private var inputSummary: some View {
        HStack(spacing: 10) {
            Group {
                if let img = model.thumbnail {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc").font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.inputs.first?.lastPathComponent ?? L("No files"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var summaryLine: String {
        let n = model.inputs.count
        var s = Lp("%d files", n)
        if let d = model.duration { s += " · \(TimeText.format(d))" }
        return s
    }

    @ViewBuilder private var controls: some View {
        switch model.tool {
        case .compress: compressControls
        case .cropImage, .cropVideo: aspectControls
        case .frameImage: frameControls
        case .blurFaces: blurControls
        case .createCollage: collageControls
        case .trimMedia: trimControls
        case .changeVideoSpeed: speedControls
        case .videoSnapshots: snapshotControls
        case .splitVideo: splitControls
        case .normalizeAudio: loudnessControls
        case .audioChannels: channelControls
        case .trimSilence: silenceControls
        // archives
        case .createArchive: archiveControls
        case .compressSingle: compressFileControls
        case .extractArchive, .testArchive, .listArchive: archivePasswordControls
        default:
            Text("No options for this tool.").foregroundStyle(.secondary)
        }
    }

    // MARK: Per-tool controls

    private var compressControls: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            if model.options.videoCompressionMode != nil {
                Picker(selection: Binding(
                    get: { model.options.videoCompressionMode ?? .fast },
                    set: { model.options.videoCompressionMode = $0 }
                )) {
                    ForEach(VideoCompressionMode.allCases) { Text($0.title).tag($0) }
                } label: { Text(verbatim: "Video compression") }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(verbatim: (model.options.videoCompressionMode ?? .fast).explanation)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(verbatim: "Original kept. 8-bit SDR only.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                OptionRow("Quality") {
                    Picker("", selection: $model.options.quality) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.useTargetSize)
                }
                Toggle("Target size", isOn: $model.useTargetSize.animation(.easeOut(duration: 0.15)))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if model.useTargetSize {
                    HStack(spacing: 8) {
                        TextField("Size", text: $model.targetSizeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Picker("", selection: $model.targetUnitMB) {
                            Text("KB").tag(false)
                            Text("MB").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 100)
                        Spacer()
                    }
                    Text("NurTo will aim for files at or below this size.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var aspectControls: some View {
        OptionRow("Aspect ratio") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(AspectRatio.allCases) { ratio in
                    AspectChip(ratio: ratio, selected: model.options.aspect == ratio) {
                        model.options.aspect = ratio
                    }
                }
            }
        }
    }

    private var frameControls: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            SliderRow(title: "Padding", value: $model.options.padding, range: 0...256, step: 4, unit: "px")
            SliderRow(title: "Corner radius", value: $model.options.cornerRadius, range: 0...128, step: 2, unit: "px")
            HStack {
                Toggle("Drop shadow", isOn: $model.options.shadow).toggleStyle(.switch).controlSize(.small)
                Spacer()
                ColorPicker("Background", selection: Binding(
                    get: { Color(nsColor: model.options.backgroundColor) },
                    set: { model.options.backgroundColor = NSColor($0) }
                ), supportsOpacity: true)
                .font(.system(size: 12))
            }
        }
    }

    private var blurControls: some View {
        OptionRow("Style") {
            Picker("", selection: $model.options.faceBlurStyle) {
                ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var collageControls: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            HStack {
                Text("Columns").font(.system(size: 12, weight: .medium))
                Spacer()
                Stepper(value: $model.options.collageColumns, in: 1...10) {
                    Text(verbatim: "\(model.options.collageColumns)").monospacedDigit().frame(minWidth: 24)
                }
            }
            SliderRow(title: "Spacing", value: $model.options.collageSpacing, range: 0...64, step: 1, unit: "px")
            Text(Lp("%d images", model.inputs.count) + " → " + Lp("%d rows", Int(ceil(Double(model.inputs.count) / Double(max(model.options.collageColumns, 1))))))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start").font(.system(size: 12, weight: .medium))
                    TextField("0:00", text: $model.trimStartText).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("End").font(.system(size: 12, weight: .medium))
                    TextField(model.duration.map(TimeText.format) ?? L("end"), text: $model.trimEndText)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Group {
                if let d = model.duration {
                    Text(L("Duration %@. Use 1:23.5 or seconds; leave End empty to keep until the end.", TimeText.format(d)))
                } else {
                    Text("Use 1:23.5 or seconds; leave End empty to keep until the end.")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let speedPresets: [Double] = [0.25, 0.5, 1.5, 2, 4]

    private var speedControls: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            HStack {
                Text("Speed").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(Self.speedLabel(model.options.speed))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(KQTheme.accentText)
            }
            Slider(value: Binding(get: { model.options.speed },
                                  set: { model.options.speed = min(max(($0 / 0.05).rounded() * 0.05, 0.25), 4) }),
                   in: 0.25...4)
            HStack(spacing: 6) {
                ForEach(Self.speedPresets, id: \.self) { s in
                    Button(Self.speedLabel(s)) { model.options.speed = s }
                        .buttonStyle(ChipButtonStyle(selected: abs(model.options.speed - s) < 0.001))
                }
            }
        }
    }

    static func speedLabel(_ s: Double) -> String {
        var str = String(format: "%.2f", s)
        while str.hasSuffix("0") { str.removeLast() }
        if str.hasSuffix(".") { str.removeLast() }
        return str + "×"
    }

    private var snapshotControls: some View {
        HStack {
            Text("Number of snapshots").font(.system(size: 12, weight: .medium))
            Spacer()
            Stepper(value: $model.options.snapshotCount, in: 1...60) {
                Text(verbatim: "\(model.options.snapshotCount)").monospacedDigit().frame(minWidth: 24)
            }
        }
    }

    private var splitControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Equal parts").font(.system(size: 12, weight: .medium))
                Spacer()
                Stepper(value: $model.options.splitParts, in: 2...50) {
                    Text(verbatim: "\(model.options.splitParts)").monospacedDigit().frame(minWidth: 24)
                }
            }
            if let d = model.duration {
                Text(L("≈ %@ each", TimeText.format(d / Double(model.options.splitParts))))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var loudnessControls: some View {
        OptionRow("Target loudness") {
            Picker("", selection: $model.options.loudnessLUFS) {
                Text("-23 LUFS · Broadcast").tag(-23.0)
                Text("-16 LUFS · Podcast").tag(-16.0)
                Text("-14 LUFS · Streaming").tag(-14.0)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var channelControls: some View {
        OptionRow("Channels") {
            Picker("", selection: $model.options.mono) {
                Text("Mono").tag(true)
                Text("Stereo").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var silenceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            SliderRow(title: "Silence threshold", value: $model.options.silenceThresholdDB, range: -80 ... -20, step: 1, unit: "dB")
            Text("Anything quieter than this is treated as silence.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Small components

struct OptionRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(title)).font(.system(size: 12, weight: .medium))
            content
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L(title)).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(verbatim: "\(Int(value.rounded())) \(unit)")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            // No `step:` here: it draws a tick per step. Round on write instead.
            Slider(value: Binding(get: { value },
                                  set: { value = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }),
                   in: range)
        }
    }
}

struct ChipButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? KQTheme.onAccentProminent : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? KQTheme.accentProminentFill : Color.primary.opacity(configuration.isPressed ? 0.15 : 0.07)))
            .contentShape(Capsule())
    }
}

struct AspectChip: View {
    let ratio: AspectRatio
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                let v = ratio.value
                let w: CGFloat = v >= 1 ? 26 : 26 * v
                let h: CGFloat = v >= 1 ? 26 / v : 26
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(selected ? KQTheme.onAccentProminent : Color.secondary, lineWidth: 1.5)
                    .frame(width: w, height: h)
                    .frame(width: 28, height: 28)
                Text(ratio.rawValue).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(selected ? KQTheme.onAccentProminent : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? KQTheme.accentProminentFill : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
