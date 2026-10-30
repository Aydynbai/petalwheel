import AppKit
import SwiftUI
import AVKit

private let nurMint = Color(red: 0.25, green: 0.45, blue: 0.94)

func nurBytes(_ size: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
}

/// A shared transport keeps both players on the same source interval. Audio is muted to avoid echo.
@MainActor
final class NurToPlaybackPair: ObservableObject {
    let before: AVPlayer
    let after = AVPlayer()
    @Published var playing = false
    @Published private(set) var hasOutput = false
    private var start = 0.0
    private var duration = 3.0
    private var observer: NSObjectProtocol?
    private var transport: Task<Void, Never>?

    init(source: URL) {
        before = AVPlayer(url: source)
        before.isMuted = true
        after.isMuted = true
        observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: before.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }

    func configure(output: URL?, start: Double, duration: Double) {
        pause()
        self.start = start
        self.duration = duration
        before.currentItem?.forwardPlaybackEndTime = CMTime(seconds: start + duration, preferredTimescale: 60000)
        after.replaceCurrentItem(with: output.map { AVPlayerItem(url: $0) })
        hasOutput = output != nil
        before.seek(to: CMTime(seconds: start, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        after.seek(to: .zero)
    }

    func toggle() {
        if playing { pause(); return }
        playing = true
        transport = Task { [weak self] in
            guard let self else { return }
            let current = before.currentTime().seconds
            let relative = current.isFinite ? current - start : 0
            let offset = relative >= 0 && relative < duration - 0.08 ? relative : 0
            _ = await before.seek(to: CMTime(seconds: start + offset, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            if after.currentItem != nil {
                _ = await after.seek(to: CMTime(seconds: offset, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard !Task.isCancelled else { return }
            before.playImmediately(atRate: 1)
            if after.currentItem != nil { after.playImmediately(atRate: 1) }
        }
    }

    func inspectionTimes() -> (CMTime, CMTime) {
        let current = before.currentTime().seconds
        let relative = current.isFinite ? current - start : 0
        let offset = min(max(0, relative), max(0, duration - 0.05))
        return (CMTime(seconds: start + offset, preferredTimescale: 60000), CMTime(seconds: offset, preferredTimescale: 60000))
    }

    func pause() {
        transport?.cancel(); transport = nil
        before.pause(); after.pause(); playing = false
    }

    func close() {
        pause()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        before.replaceCurrentItem(with: nil); after.replaceCurrentItem(with: nil); hasOutput = false
    }
}

struct NurToPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { nsView.player = player }
}

@MainActor
struct NurToComparisonPlayers: View {
    @ObservedObject var pair: NurToPlaybackPair
    var hasAfter: Bool
    var playerHeight: CGFloat = 240
    @State private var split: CGFloat = 0.5
    @State private var draggingDivider = false
    @State private var zoomScale: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panOrigin = CGSize.zero
    @State private var zoomError: String?
    @State private var capturing = false
    @State private var beforeStill: NSImage?
    @State private var afterStill: NSImage?
    @State private var captureTask: Task<Void, Never>?
    @State private var captureID = UUID()

    var body: some View {
        VStack(spacing: 9) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.96)
                    surface(player: pair.before, image: beforeStill)
                    if hasAfter {
                        surface(player: pair.after, image: afterStill)
                            .mask(alignment: .trailing) { Rectangle().frame(width: geometry.size.width * (1 - split)) }
                        Rectangle().fill(.white).frame(width: 1.5)
                            .position(x: geometry.size.width * split, y: geometry.size.height / 2)
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 29, height: 29).background(.white, in: Circle())
                            .position(x: geometry.size.width * split, y: geometry.size.height / 2)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("comparison"))
                                .onChanged { draggingDivider = true; split = min(0.96, max(0.04, $0.location.x / geometry.size.width)) }
                                .onEnded { _ in draggingDivider = false })
                        HStack {
                            badge("Before")
                            Spacer()
                            badge("After")
                        }.padding(9)
                    }
                    if capturing { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .coordinateSpace(name: "comparison")
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }.frame(height: playerHeight)
            HStack(spacing: 12) {
                Spacer()
                Button { setZoom(max(1, zoomScale - 0.5)) } label: { Image(systemName: "minus") }
                    .disabled(!hasAfter || capturing || zoomScale <= 1)
                Button { setZoom(1) } label: { Text(verbatim: String(format: "%g×", Double(zoomScale))) }
                    .help(Text(verbatim: "Reset zoom"))
                Button { setZoom(min(4, zoomScale + 0.5)) } label: { Image(systemName: "plus") }
                    .disabled(!hasAfter || capturing || zoomScale >= 4)
                Spacer()
            }.buttonStyle(.borderless)
            if let zoomError { Text(verbatim: zoomError).font(.caption).foregroundStyle(.secondary) }

        }
        .onChange(of: hasAfter) { clearZoom() }
        .onDisappear { clearZoom() }
    }

    @ViewBuilder
    private func surface(player: AVPlayer, image: NSImage?) -> some View {
        if let image {
            GeometryReader { geo in
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(zoomScale)
                    .offset(pan)
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            guard zoomScale > 1 else { return }
                            let fit = min(geo.size.width / image.size.width, geo.size.height / image.size.height)
                            let limitX = max(0, (image.size.width * fit * zoomScale - geo.size.width) / 2)
                            let limitY = max(0, (image.size.height * fit * zoomScale - geo.size.height) / 2)
                            pan = CGSize(width: min(limitX, max(-limitX, panOrigin.width + value.translation.width)),
                                         height: min(limitY, max(-limitY, panOrigin.height + value.translation.height)))
                        }
                        .onEnded { _ in panOrigin = pan })
            }.clipped()
        } else {
            NurToPlayer(player: player)
        }
    }

    private func badge(_ title: String) -> some View {
        Text(verbatim: title).font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.5), in: Capsule())
    }

    private func clearZoom() {
        captureID = UUID(); captureTask?.cancel(); captureTask = nil
        zoomScale = 1; pan = .zero; panOrigin = .zero; zoomError = nil
        capturing = false; beforeStill = nil; afterStill = nil
    }

    private func setZoom(_ value: CGFloat) {
        pan = .zero; panOrigin = .zero; zoomError = nil
        if value == 1 {
            captureID = UUID(); captureTask?.cancel(); captureTask = nil
            capturing = false; zoomScale = 1
            return
        }
        if beforeStill != nil && afterStill != nil { zoomScale = value; return }
        guard hasAfter, let beforeItem = pair.before.currentItem, let afterItem = pair.after.currentItem else { return }
        pair.pause(); capturing = true
        let token = UUID(); captureID = token
        let (beforeTime, afterTime) = pair.inspectionTimes()
        captureTask = Task { @MainActor in
            do {
                let first = AVAssetImageGenerator(asset: beforeItem.asset)
                let second = AVAssetImageGenerator(asset: afterItem.asset)
                for generator in [first, second] {
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                }
                async let a = first.image(at: beforeTime)
                async let b = second.image(at: afterTime)
                let (left, right) = try await (a, b)
                guard !Task.isCancelled, token == captureID else { return }
                beforeStill = NSImage(cgImage: left.image, size: NSSize(width: left.image.width, height: left.image.height))
                afterStill = NSImage(cgImage: right.image, size: NSSize(width: right.image.width, height: right.image.height))
                zoomScale = value; capturing = false
            } catch { if token == captureID { capturing = false; zoomError = "Choose another frame to zoom." } }
        }
    }
}

@MainActor
final class NurToCompressionModel: ObservableObject {
    let inputs: [URL]
    let initial: ToolOptions
    let pair: NurToPlaybackPair
    @Published var mode: VideoCompressionMode
    @Published var info: MediaInfo?
    @Published var loading = true
    @Published var start = 0.0
    @Published var busy = false
    @Published var fraction = 0.0
    @Published var artifact: VideoPreviewArtifact?
    @Published var error: String?
    private var generation = UUID()
    private var previewTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var closed = false

    init(inputs: [URL], initial: ToolOptions) {
        self.inputs = inputs; self.initial = initial
        self.mode = initial.videoCompressionMode ?? .fast
        pair = NurToPlaybackPair(source: inputs[0])
    }

    var validation: String? {
        guard let info else { return nil }
        do { try VideoCompression.validate(info, mode: mode); return nil }
        catch { return error.localizedDescription }
    }
    var sampleSeconds: Double { min(3, max(0, (info?.duration ?? 0) - start)) }
    var result: ToolOptions {
        var options = initial
        options.videoCompressionMode = mode
        options.targetSizeKB = nil
        return options
    }
    var estimatedSize: Int64? {
        guard let artifact, let info, artifact.seconds > 0 else { return nil }
        return Int64(Double(MediaOutput.fileSize(artifact.output)) * info.duration / artifact.seconds)
    }

    func load() {
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await MediaProbe.probe(inputs[0])
                guard !closed else { return }
                info = value
                pair.configure(output: nil, start: 0, duration: min(3, value.duration))
                loading = false
            } catch { if !closed { self.error = error.localizedDescription; loading = false } }
        }
    }

    func invalidate() {
        generation = UUID()
        previewTask?.cancel(); previewTask = nil
        busy = false; fraction = 0; error = nil
        pair.configure(output: nil, start: start, duration: sampleSeconds)
        if let artifact { try? FileManager.default.removeItem(at: artifact.directory) }
        artifact = nil
    }

    func makePreview() {
        invalidate()
        guard let info, validation == nil else { return }
        busy = true
        let token = generation, chosenMode = mode, chosenStart = start
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let preview = try await VideoCompression.preview(inputs[0], info: info, mode: chosenMode, start: chosenStart) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.generation == token, !self.closed else { return }
                        self.fraction = value
                    }
                }
                guard !Task.isCancelled, !closed, token == generation else {
                    try? FileManager.default.removeItem(at: preview.directory); return
                }
                artifact = preview
                pair.configure(output: preview.output, start: chosenStart, duration: preview.seconds)
                busy = false
            } catch {
                guard token == generation, !closed else { return }
                busy = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func close() {
        closed = true; generation = UUID()
        previewTask?.cancel(); loadTask?.cancel()
        pair.close()
        if let artifact { try? FileManager.default.removeItem(at: artifact.directory) }
        artifact = nil
    }
}

@MainActor
struct NurToCompressionView: View {
    @ObservedObject var model: NurToCompressionModel
    var onCancel: () -> Void
    var onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(verbatim: "NurTo").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(verbatim: model.inputs[0].lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Picker(selection: $model.mode) {
                Text(verbatim: "Fast").tag(VideoCompressionMode.fast)
                Text(verbatim: "Quality").tag(VideoCompressionMode.quality)
            } label: { EmptyView() }
            .pickerStyle(.segmented).disabled(model.busy)
            NurToComparisonPlayers(pair: model.pair, hasAfter: model.artifact != nil, playerHeight: 240)
            HStack {
                Text(verbatim: TimeText.format(model.start)).font(.caption.monospacedDigit())
                Slider(value: $model.start, in: 0...max(0.001, (model.info?.duration ?? 0) - 0.1))
                    .disabled(model.loading || model.busy || (model.info?.duration ?? 0) <= 0.1)
                Text(verbatim: TimeText.format(model.info?.duration ?? 0)).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error ?? model.validation {
                Text(verbatim: error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if model.busy {
                    ProgressView(value: model.fraction).frame(width: 100)
                    Button { model.invalidate() } label: { Text(verbatim: "Stop") }
                } else {
                    Button { model.makePreview() } label: { Text(verbatim: "Compare") }
                        .disabled(model.loading || model.info == nil || model.validation != nil)
                }
                Spacer()
                Button(action: onCancel) { Text(verbatim: "Close") }.keyboardShortcut(.cancelAction)
                Button(action: onApply) { Text(verbatim: model.inputs.count > 1 ? "Compress (\(model.inputs.count))" : "Compress") }
                    .buttonStyle(.borderedProminent).tint(nurMint).foregroundStyle(.black)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.loading || model.info == nil || model.busy || model.validation != nil || model.error != nil)
            }
        }
        .padding(18).frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor)).tint(nurMint).preferredColorScheme(.light)
        .id(model.loading)
        .onChange(of: model.mode) { model.invalidate() }
        .onChange(of: model.start) { model.invalidate() }
    }
}

@MainActor
final class NurToCompressionPanel: NSObject, NSWindowDelegate {
    private static var active: [NurToCompressionPanel] = []
    let model: NurToCompressionModel
    private var window: NSWindow?
    private var completion: ((ToolOptions?) -> Void)?

    static func present(inputs: [URL], initial: ToolOptions, completion: @escaping (ToolOptions?) -> Void) {
        let controller = NurToCompressionPanel(inputs: inputs, initial: initial, completion: completion)
        active.append(controller); controller.show()
    }
    private init(inputs: [URL], initial: ToolOptions, completion: @escaping (ToolOptions?) -> Void) {
        model = NurToCompressionModel(inputs: inputs, initial: initial)
        self.completion = completion
    }
    private func show() {
        let view = NurToCompressionView(model: model,
            onCancel: { [weak self] in self?.finish(nil) },
            onApply: { [weak self] in
                guard let self, self.model.info != nil, !self.model.busy, self.model.validation == nil else { return }
                self.finish(self.model.result)
            })
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.title = "NurTo · Compress"; w.contentView = host; w.isReleasedWhenClosed = false; w.delegate = self
        w.center(); window = w
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.model.load() }
    }
    private func finish(_ result: ToolOptions?) {
        guard let completion else { return }
        self.completion = nil
        model.close()
        window?.delegate = nil; window?.close(); window = nil
        completion(result)
        Self.active.removeAll { $0 === self }
    }
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
