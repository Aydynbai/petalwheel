import AppKit
import AVFoundation
import CoreImage
import Combine

/// State of the Redact Video editor: playback, the current frame, regions and undo.
@MainActor
final class RedactVideoModel: ObservableObject {
    let url: URL

    @Published private(set) var info: MediaInfo?
    @Published private(set) var loadError: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var duration: Double = 0
    /// Display size of the rotated video in pixels (rect coordinates live here).
    @Published private(set) var displaySize = CGSize(width: 16, height: 9)
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var usesFrameFallback = false
    @Published var regions: [RedactVideoRegion] = []
    @Published var selectedID: UUID?
    /// Thumbnail strip for the timeline (shared loader with Trim / Bleep).
    @Published private(set) var filmstrip: FilmstripFrames?
    @Published var status: String?
    @Published private(set) var isDetecting = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Exact frame at `currentTime` (paused, or every frame in the ffmpeg fallback).
    private(set) var stillFrame: CGImage?
    /// The current frame, display-oriented, extent = (0, 0, displaySize).
    private(set) var currentFrame: CIImage?
    private var frameGeneration = 0

    private(set) var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var generator: AVAssetImageGenerator?
    /// Storage → display transform for pixel buffers (CoreImage coordinates).
    private var bufferTransform = CGAffineTransform.identity
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    private var stillInFlight = false
    private var stillPending = false
    private var tempDir: URL?
    private var closed = false

    private var undoStack: [[RedactVideoRegion]] = []
    private var redoStack: [[RedactVideoRegion]] = []
    private var pendingSnapshot: [RedactVideoRegion]?
    private var coalesceKey: String?
    private var coalesceTime: CFTimeInterval = 0
    private var patchCache: [UUID: (key: String, image: CGImage)] = [:]

    /// Called whenever the video area needs to redraw (frame or regions changed).
    var onRedraw: (() -> Void)?

    static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static let palette: [NSColor] = [
        // Kumquat Grove (bright variants: drawn over video frames)
        KQPalette.Dark.kumquat, KQPalette.Dark.denim, KQPalette.Dark.leaf, KQPalette.Dark.honey,
        KQPalette.Dark.lagoon, KQPalette.Dark.terracotta, KQPalette.Dark.driftwood, KQPalette.rgb(0xF07468),
    ]

    static func tintColor(_ index: Int) -> NSColor { palette[((index % palette.count) + palette.count) % palette.count] }

    init(url: URL) {
        self.url = url
    }

    var selectedRegion: RedactVideoRegion? {
        guard let id = selectedID else { return nil }
        return regions.first { $0.id == id }
    }

    var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return regions.firstIndex { $0.id == id }
    }

    func visibleRegions(at t: Double? = nil) -> [RedactVideoRegion] {
        let time = t ?? currentTime
        return regions.filter { $0.isVisible(at: time, duration: duration) }
    }

    // MARK: Loading

    func load() {
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await MediaProbe.probe(self.url)
                guard !self.closed else { return }
                guard info.hasVideo, info.width > 0, info.height > 0 else {
                    throw KumquatError(l: "“%@” has no video track.", self.url.lastPathComponent)
                }
                self.info = info
                self.displaySize = CGSize(width: info.width, height: info.height)
                self.duration = max(info.duration, 0.04)
                if await !self.setUpPlayer(), !self.closed {
                    self.usesFrameFallback = true
                    self.tempDir = try? OutputNaming.tempDirectory()
                }
                guard !self.closed else { return }
                self.isLoaded = true
                self.requestStill()
                self.loadThumbnails()
            } catch {
                self.loadError = error.localizedDescription
            }
        }
    }

    /// AVFoundation playback. Returns false when the file can't be decoded (mkv, webm, …).
    private func setUpPlayer() async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              let track = try? await asset.loadTracks(withMediaType: .video).first else { return false }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 2560, height: 2560)
        guard (try? await gen.image(at: .zero)) != nil else { return false }
        if let natural = try? await track.load(.naturalSize),
           let t = try? await track.load(.preferredTransform) {
            bufferTransform = Self.displayTransform(natural: natural, preferred: t, display: displaySize)
        }
        guard !closed else { return false }
        generator = gen
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        videoOutput = output
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        player = p
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = self.duration
                self.pause()
            }
        }
        return true
    }

    /// Maps a storage-oriented pixel buffer (CoreImage, y-up) to the display frame.
    static func displayTransform(natural: CGSize, preferred t: CGAffineTransform, display: CGSize) -> CGAffineTransform {
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
        let rotated = CGRect(origin: .zero, size: natural).applying(t)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rotated.height)
        var m = flipIn.concatenating(t)
            .concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
            .concatenating(flipOut)
        if rotated.width > 0, rotated.height > 0 {
            m = m.concatenating(CGAffineTransform(scaleX: display.width / rotated.width,
                                                  y: display.height / rotated.height))
        }
        return m
    }

    private func loadThumbnails() {
        guard let info else { return }
        let url = self.url
        thumbTask = Task { [weak self] in
            let frames = await Task.detached(priority: .utility) {
                await TimelineMediaLoader.filmstrip(for: url, info: info, count: 14, height: 120)
            }.value
            guard let self, !Task.isCancelled, !self.closed else { return }
            self.filmstrip = frames
        }
    }

    /// One frame through ffmpeg (autorotated), for formats AVFoundation can't decode.
    private func extractFrame(at t: Double) async -> CGImage? {
        guard let ffmpeg = ExternalTools.shared.ffmpeg else { return nil }
        if tempDir == nil { tempDir = try? OutputNaming.tempDirectory() }
        guard let dir = tempDir else { return nil }
        let out = dir.appendingPathComponent("frame-\(UUID().uuidString.prefix(8)).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        let (w, h) = (Int(displaySize.width), Int(displaySize.height))
        let scale = "scale=\(w):\(h)"
        let seek = max(0, min(t, duration - 0.02))
        do {
            try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                                                 "-ss", String(format: "%.3f", seek), "-i", url.path,
                                                 "-frames:v", "1", "-an", "-sn", "-vf", "\(scale),setsar=1",
                                                 "-q:v", "3", out.path])
        } catch {
            return nil
        }
        // Read into memory and decode now: the temp file is deleted on return.
        guard let data = try? Data(contentsOf: out),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: Frames

    /// Fetches the exact frame at `currentTime` (coalesced while scrubbing).
    func requestStill() {
        guard isLoaded else { return }
        if stillInFlight { stillPending = true; return }
        stillInFlight = true
        let t = currentTime
        Task { [weak self] in
            guard let self else { return }
            var image: CGImage?
            if let gen = self.generator {
                image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            } else {
                image = await self.extractFrame(at: t)
            }
            self.stillInFlight = false
            guard !self.closed else { return }
            if let image, !self.isPlaying || self.usesFrameFallback { self.setStill(image) }
            if self.stillPending {
                self.stillPending = false
                if !self.isPlaying || self.usesFrameFallback { self.requestStill() }
            }
        }
    }

    private func setStill(_ image: CGImage) {
        stillFrame = image
        var ci = CIImage(cgImage: image)
        let sx = displaySize.width / ci.extent.width, sy = displaySize.height / ci.extent.height
        if abs(sx - 1) > 0.0001 || abs(sy - 1) > 0.0001 {
            ci = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        setFrame(ci)
    }

    private func setFrame(_ ci: CIImage) {
        currentFrame = ci
        frameGeneration += 1
        patchCache.removeAll()
        onRedraw?()
    }

    /// Effect preview for one region, rendered from the current frame.
    func patch(for region: RedactVideoRegion) -> CGImage? {
        guard region.style != .solid, let frame = currentFrame else { return nil }
        let fw = Int(displaySize.width), fh = Int(displaySize.height)
        guard let p = RedactVideoExport.pixelRect(region.rect, frameWidth: max(2, fw), frameHeight: max(2, fh)) else { return nil }
        let key = "\(frameGeneration)|\(p.x),\(p.y),\(p.w),\(p.h)|\(region.style.rawValue)|\(region.strength)"
        if let cached = patchCache[region.id], cached.key == key { return cached.image }
        let ciRect = CGRect(x: p.x, y: fh - p.y - p.h, width: p.w, height: p.h)
        let base = frame.cropped(to: ciRect).clampedToExtent()
        var out: CIImage
        if region.style == .blur {
            let r = Double(RedactVideoExport.blurRadius(strength: region.strength, w: p.w, h: p.h))
            out = base.applyingGaussianBlur(sigma: (r * (r + 1)).squareRoot())
        } else {
            let b = RedactVideoExport.pixelBlock(strength: region.strength, w: p.w, h: p.h)
            out = base.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: Double(b),
                kCIInputCenterKey: CIVector(x: ciRect.minX, y: ciRect.maxY),
            ])
        }
        out = out.cropped(to: ciRect)
        guard let image = Self.ciContext.createCGImage(out, from: ciRect) else { return nil }
        patchCache[region.id] = (key, image)
        return image
    }

    /// Display-oriented CGImage of the current frame (for Vision).
    func currentFrameImage() -> CGImage? {
        if let still = stillFrame, !isPlaying || usesFrameFallback,
           still.width == Int(displaySize.width), still.height == Int(displaySize.height) { return still }
        guard let frame = currentFrame else { return stillFrame }
        return Self.ciContext.createCGImage(frame, from: CGRect(origin: .zero, size: displaySize))
    }

    // MARK: Playback

    func seek(to t: Double) {
        guard isLoaded else { return }
        currentTime = min(max(t, 0), duration)
        player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        if !isPlaying || usesFrameFallback { requestStill() }
        onRedraw?()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard isLoaded, !isPlaying else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        isPlaying = true
        player?.play()
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onRedraw?()
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        guard isPlaying else { return }
        isPlaying = false
        player?.pause()
        if let p = player { currentTime = min(max(p.currentTime().seconds, 0), duration) }
        requestStill()
        onRedraw?()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        if let player, let output = videoOutput {
            let itemTime = output.itemTime(forHostTime: now)
            currentTime = min(max(player.currentTime().seconds, 0), duration)
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                let ci = CIImage(cvPixelBuffer: pb).transformed(by: bufferTransform)
                setFrame(ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY)))
            } else {
                onRedraw?()
            }
        } else {
            currentTime = min(currentTime + dt, duration)
            if currentTime >= duration { pause(); return }
            if !stillInFlight { requestStill() }
            onRedraw?()
        }
    }

    // MARK: Editing & undo

    /// Snapshot before an interactive change (drag, slider); `commitChange` records it.
    func beginChange() { pendingSnapshot = regions }

    func commitChange() {
        guard let snap = pendingSnapshot else { return }
        pendingSnapshot = nil
        if snap != regions { pushUndo(snap) }
    }

    private func pushUndo(_ snap: [RedactVideoRegion]) {
        undoStack.append(snap)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        coalesceKey = nil
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Mutates the selected region; edits with the same `coalesce` key within a second share one undo step.
    func editSelected(coalesce: String? = nil, _ change: (inout RedactVideoRegion) -> Void) {
        guard let i = selectedIndex else { return }
        var r = regions[i]
        change(&r)
        guard r != regions[i] else { return }
        let now = CACurrentMediaTime()
        if pendingSnapshot == nil {
            if let key = coalesce, key == coalesceKey, now - coalesceTime < 1.0 {
                coalesceTime = now
            } else {
                pushUndo(regions)
                coalesceKey = coalesce
                coalesceTime = now
            }
        }
        regions[i] = r
        onRedraw?()
    }

    /// Updates a region without recording undo (inside begin/commit).
    func update(_ id: UUID, _ change: (inout RedactVideoRegion) -> Void) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        change(&regions[i])
        onRedraw?()
    }

    @discardableResult
    func addRegion(rect: CGRect, recordUndo: Bool = true) -> UUID {
        if recordUndo { pushUndo(regions) }
        let start = min(currentTime, max(0, duration - 0.1))
        let usedTints = Set(regions.map(\.tint))
        let tint = (0..<Self.palette.count).first { !usedTints.contains($0) } ?? regions.count
        let region = RedactVideoRegion(rect: rect, start: start, end: duration, tint: tint)
        regions.append(region)
        selectedID = region.id
        onRedraw?()
        return region.id
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        pushUndo(regions)
        regions.remove(at: i)
        selectedID = nil
        onRedraw?()
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(regions)
        regions = snap
        if let id = selectedID, !regions.contains(where: { $0.id == id }) { selectedID = nil }
        coalesceKey = nil
        updateUndoFlags()
        onRedraw?()
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(regions)
        regions = snap
        if let id = selectedID, !regions.contains(where: { $0.id == id }) { selectedID = nil }
        coalesceKey = nil
        updateUndoFlags()
        onRedraw?()
    }

    /// Selects a region and moves the playhead into its range if needed.
    /// Any redaction layer added.
    var hasUnsavedChanges: Bool { !regions.isEmpty }

    func select(_ id: UUID?, revealInTime: Bool = false) {
        selectedID = id
        if revealInTime, let r = selectedRegion, !r.isVisible(at: currentTime, duration: duration) {
            seek(to: r.range(duration: duration).lowerBound)
        }
        onRedraw?()
    }

    // MARK: Faces

    func detectFaces() {
        guard isLoaded, !isDetecting else { return }
        if isPlaying { pause() }
        guard let image = currentFrameImage() else {
            status = L("The frame isn’t ready yet. Try again in a moment.")
            return
        }
        isDetecting = true
        let size = displaySize
        Task.detached(priority: .userInitiated) {
            let faces = (try? VisionTools.faceRects(in: image)) ?? []
            let sx = size.width / CGFloat(image.width), sy = size.height / CGFloat(image.height)
            let rects = faces.map { f -> CGRect in
                // Vision: bottom-left origin → display top-left origin, then expand a little.
                let r = CGRect(x: f.minX * sx, y: (CGFloat(image.height) - f.maxY) * sy,
                               width: f.width * sx, height: f.height * sy)
                return Self.expandFace(r, in: size)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isDetecting = false
                if rects.isEmpty {
                    self.status = L("No faces found in this frame.")
                    return
                }
                self.pushUndo(self.regions)
                for r in rects { self.addRegion(rect: r, recordUndo: false) }
                self.status = Lp("Added %d faces.", rects.count)
            }
        }
    }

    nonisolated static func expandFace(_ r: CGRect, in size: CGSize) -> CGRect {
        let e = r.insetBy(dx: -r.width * 0.18, dy: -r.height * 0.22)
        return e.intersection(CGRect(origin: .zero, size: size))
    }

    // MARK: Export

    func exportJob() -> RedactVideoExport.Job? {
        guard let info else { return nil }
        return RedactVideoExport.Job(source: url, info: info, regions: regions, duration: duration)
    }

    // MARK: Teardown

    func close() {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        timer = nil
        isPlaying = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        loadTask?.cancel()
        thumbTask?.cancel()
        generator?.cancelAllCGImageGeneration()
        onRedraw = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }
}
