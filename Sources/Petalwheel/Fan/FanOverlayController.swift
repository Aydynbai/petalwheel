import AppKit
import QuickLookThumbnailing

enum FanInteraction { case drag, click }

/// Borderless, non-activating panel hosting the fan. Becomes key only in click mode (for Escape).
final class FanPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .aqua)
    }

    override func cancelOperation(_ sender: Any?) {
        (delegate as? FanPanelDelegate)?.panelDidCancel()
    }
}

@MainActor protocol FanPanelDelegate: NSWindowDelegate {
    func panelDidCancel()
}

/// Shows the radial fan of conversion targets / tools / actions under the cursor.
@MainActor
final class FanOverlayController: NSObject, FanPanelDelegate {
    /// Called when the user drops files on a petal (drag) or clicks a petal (click mode).
    var onSelect: ((FanItem, [URL]) -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var isVisible = false

    private var panel: FanPanel?
    private var capturePanel: NSPanel?
    private var awaitingInitialRelease = false
    private var heldSession = false
    private var fanView: FanView?
    private var items: [FanItem] = []
    private var urls: [URL] = []
    private var interaction: FanInteraction = .drag
    private var dropInProgress = false
    private var generation = 0
    private var monitors: [Any] = []
    private var pendingDismiss: DispatchWorkItem?
    // Category navigation
    private var rootMode: FanMode = .categories
    private var rootItems: [FanItem] = []
    private var openCategory: FanCategory?
    private var categoryTrail: [FanCategory] = []
    private var anchor: NSPoint = .zero
    private var dwellWork: DispatchWorkItem?
    private lazy var tick: NSSound? = {
        let s = NSSound(named: NSSound.Name("Tink"))?.copy() as? NSSound
        s?.volume = 0.18
        return s
    }()

    private static let margin: CGFloat = 26

    override init() { super.init() }

    /// Shows the fan centred at `screenPoint` (global AppKit screen coordinates, bottom-left origin).
    func show(mode: FanMode, items: [FanItem], urls: [URL], at screenPoint: NSPoint, interaction: FanInteraction, awaitInitialRelease: Bool = false, closeOnModifierRelease: Bool = false) {
        if isVisible { teardown(notify: false, animated: false) }
        generation += 1
        self.urls = urls
        self.interaction = interaction
        awaitingInitialRelease = awaitInitialRelease
        heldSession = closeOnModifierRelease
        dropInProgress = false
        rootMode = mode
        rootItems = items
        openCategory = nil
        categoryTrail = []
        anchor = screenPoint

        let panel = self.panel ?? FanPanel()
        self.panel = panel
        panel.delegate = self
        panel.allowsKey = interaction == .click && !awaitingInitialRelease
        present(mode: mode, items: items, hint: nil, canGoBack: false, appearing: true)
    }

    /// Builds the fan for `items` around `anchor`. `appearing` = first show (fade in, monitors);
    /// otherwise the content is swapped in place (category navigation).
    private func present(mode: FanMode, items: [FanItem], hint: String?, canGoBack: Bool, appearing: Bool) {
        guard let panel else { return }
        let gen = generation
        let screenPoint = anchor
        self.items = items
        dwellWork?.cancel()
        if let old = fanView {
            old.onHighlightChange = nil; old.onDrop = nil; old.onClick = nil; old.onDragEnded = nil
            old.onCenterHoverChange = nil; old.onCenterClick = nil
            old.unregisterDraggedTypes()
        }

        let fan = FanView(frame: .zero)
        fan.configure(mode: mode, items: items)
        let radius = items.isEmpty ? fan.layout.centerRadius : fan.layout.outerRadius
        let side = ceil(2 * (radius + Self.margin))
        let size = NSSize(width: side, height: side)

        // Build view hierarchy: container (animated) > shadow, blur, fan.
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let root = NSView(frame: content.bounds)
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        content.addSubview(root)

        fan.frame = root.bounds
        fan.autoresizingMask = [.width, .height]
        fan.clickEnabled = interaction == .click && !awaitingInitialRelease
        fan.captureDrops = interaction == .click
        fan.fileCount = urls.count
        fan.hintOverride = hint
        fan.tint = openCategory?.fanColor
        fan.canGoBack = canGoBack
        if items.isEmpty { fan.message = L("No options for these files") }
        let shape = fan.glassShape()

        let shadow = NSView(frame: root.bounds)
        shadow.wantsLayer = true
        shadow.layer?.shadowPath = shape
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = 0.12
        shadow.layer?.shadowRadius = 12
        shadow.layer?.shadowOffset = CGSize(width: 0, height: -4)
        root.addSubview(shadow)

        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.maskImage(shape: shape, size: size)
        root.addSubview(blur)
        root.addSubview(fan)

        fan.onHighlightChange = { [weak self] index in self?.highlightChanged(index) }
        fan.onDrop = { [weak self] index, dropped in self?.select(index: index, droppedURLs: dropped) }
        fan.onClick = { [weak self] index in self?.select(index: index, droppedURLs: []) }
        fan.onCenterHoverChange = { [weak self] inside in self?.centerHoverChanged(inside) }
        fan.onCenterClick = { [weak self] in self?.goBack() }
        fan.onDragEnded = { [weak self] in
            guard let self, self.generation == gen, !self.dropInProgress, self.interaction == .drag else { return }
            self.dismiss()
        }
        fanView = fan

        // Thumbnail
        loadThumbnail(for: urls.first, into: fan, generation: gen)

        // Position, clamped to the visible frame of the screen under the point.
        var frame = NSRect(x: screenPoint.x - side / 2, y: screenPoint.y - side / 2, width: side, height: side)
        let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            // Allow the transparent margin to overhang; keep the drawn fan inside.
            let m = Self.margin - 4
            frame.origin.x = min(max(frame.origin.x, vf.minX - m), vf.maxX - side + m)
            frame.origin.y = min(max(frame.origin.y, vf.minY - m), vf.maxY - side + m)
        }
        panel.contentView = content
        panel.setFrame(frame, display: false)
        content.layoutSubtreeIfNeeded()

        if appearing, awaitingInitialRelease, let screen { showCapture(on: screen) }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard appearing else {
            // In-place swap: a short "zoom" so the change of level reads clearly.
            if !reduceMotion, let layer = root.layer {
                let c = CGPoint(x: side / 2, y: side / 2)
                let s: CGFloat = 0.82
                let from = CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                               CATransform3DMakeTranslation(c.x * (1 - s), c.y * (1 - s), 0))
                let spring = CASpringAnimation(keyPath: "transform")
                spring.fromValue = NSValue(caTransform3D: from)
                spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                spring.stiffness = 420
                spring.damping = 24
                spring.duration = spring.settlingDuration
                layer.add(spring, forKey: "swap")
            }
            if interaction == .click {
                fan.setHighlightedSilently(fan.petalIndex(atWindowPoint: panel.mouseLocationOutsideOfEventStream))
            }
            return
        }

        // Appear
        isVisible = true
        panel.alphaValue = 0
        if interaction == .click && !awaitingInitialRelease {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.12 : 0.14
            panel.animator().alphaValue = 1
        }
        if !reduceMotion, let layer = root.layer {
            let c = CGPoint(x: side / 2, y: side / 2)
            let s: CGFloat = 0.55
            let from = CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                           CATransform3DMakeTranslation(c.x * (1 - s), c.y * (1 - s), 0))
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: from)
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.mass = 1
            spring.stiffness = 320
            spring.damping = 20
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "appear")
        }

        installMonitors()

        if items.isEmpty {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == gen else { return }
                self.dismiss()
            }
            pendingDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }

        if interaction == .click {
            // Highlight the petal already under the mouse, if any.
            fan.setHighlightedSilently(fan.petalIndex(atWindowPoint: panel.mouseLocationOutsideOfEventStream))
        }
    }

    /// The drag session ended (mouse released) without dropping on the fan.
    func dragDidEnd() {
        if isVisible && awaitingInitialRelease {
            awaitingInitialRelease = false
            fanView?.clickEnabled = true
            panel?.allowsKey = true
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.capturePanel?.orderOut(nil)
                if self.isVisible {
                    NSApp.activate(ignoringOtherApps: true)
                    self.panel?.makeKeyAndOrderFront(nil)
                }
            }
            return
        }
        guard isVisible, interaction == .drag, !dropInProgress else { return }
        if fanView?.highlighted != nil {
            // The mouse was released over a petal: the drop message may still be on its way.
            // Give performDragOperation a moment before giving up.
            let gen = generation
            pendingDismiss?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == gen, self.isVisible, !self.dropInProgress else { return }
                self.dismiss()
            }
            pendingDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            dismiss()
        }
    }

    func modifierReleased() { if heldSession { dismiss() } }

    func dismiss() {
        guard isVisible else { return }
        teardown(notify: true, animated: true)
    }

    // MARK: - NSWindowDelegate / FanPanelDelegate

    func panelDidCancel() { dismiss() }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking another app's window in click mode.
        if isVisible, interaction == .click, !dropInProgress, !awaitingInitialRelease { dismiss() }
    }

    // MARK: - Private

    private func select(index: Int, droppedURLs: [URL]) {
        guard isVisible, index < items.count, !dropInProgress else { return }
        if case .category(let category) = items[index].kind {
            if !droppedURLs.isEmpty { urls = droppedURLs }
            if interaction == .drag {
                // Dropped onto a category: the drag is over, so continue in click mode.
                interaction = .click
                panel?.allowsKey = true
                panel?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            open(category)
            return
        }
        dropInProgress = true
        pendingDismiss?.cancel()
        let item = items[index]
        let chosen = droppedURLs.isEmpty ? urls : droppedURLs
        onSelect?(item, chosen)
        if isVisible { teardown(notify: true, animated: true) }
    }

    private func open(_ category: FanCategory) {
        categoryTrail.append(category)
        openCategory = category
        let items = FanCatalog.items(in: category, urls: urls)
        let mode: FanMode = category == .convert ? .conversions : (category == .share ? .actions : .tools)
        present(mode: mode, items: items, hint: "‹ " + category.title, canGoBack: true, appearing: false)
        highlightFeedback()
    }

    private func goBack() {
        guard isVisible, openCategory != nil else { return }
        if !categoryTrail.isEmpty { categoryTrail.removeLast() }
        if let parent = categoryTrail.last {
            openCategory = parent
            let mode: FanMode = parent == .convert ? .conversions : (parent == .share ? .actions : .tools)
            present(mode: mode, items: FanCatalog.items(in: parent, urls: urls), hint: "‹ " + parent.title, canGoBack: true, appearing: false)
        } else {
            openCategory = nil
            present(mode: rootMode, items: rootItems, hint: nil, canGoBack: false, appearing: false)
        }
        highlightFeedback()
    }

    private func centerHoverChanged(_ inside: Bool) {
        // Hover is visual only. Back requires a deliberate click.
        dwellWork?.cancel()
    }

    private func highlightChanged(_ index: Int?) {
        // A category opens only on click/drop. Replacing the menu must never auto-open
        // another category that happens to appear underneath the stationary pointer.
        dwellWork?.cancel()
        if index != nil { highlightFeedback() }
    }

    private func highlightFeedback() {
        if AppSettings.shared.soundsEnabled, let tick {
            if tick.isPlaying { tick.stop() }
            tick.play()
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Invisible only during the original OS drag, so releasing cannot move the file
    /// onto an unrelated desktop target. It never changes or blurs the desktop.
    private func showCapture(on screen: NSScreen) {
        let back = capturePanel ?? NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        back.setFrame(screen.frame, display: false)
        back.isOpaque = false; back.backgroundColor = .clear; back.hasShadow = false
        back.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        back.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        back.hidesOnDeactivate = false
        back.contentView = NurToDragCaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))
        back.orderFrontRegardless(); capturePanel = back
    }

    private func teardown(notify: Bool, animated: Bool) {
        capturePanel?.orderOut(nil)
        awaitingInitialRelease = false
        heldSession = false
        isVisible = false
        dwellWork?.cancel()
        pendingDismiss?.cancel()
        pendingDismiss = nil
        removeMonitors()
        let gen = generation
        if let fanView {
            fanView.onHighlightChange = nil
            fanView.onDrop = nil
            fanView.onClick = nil
            fanView.onDragEnded = nil
            fanView.onCenterHoverChange = nil
            fanView.onCenterClick = nil
            fanView.unregisterDraggedTypes()
        }
        fanView = nil
        if let panel {
            panel.allowsKey = false
            if animated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    panel.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == gen, !self.isVisible else { return }
                        panel.orderOut(nil)
                        panel.contentView = nil
                    }
                })
            } else {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }
        if notify { onDismiss?() }
    }

    private func installMonitors() {
        removeMonitors()
        let isEscape: (NSEvent) -> Bool = { $0.type == .keyDown && $0.keyCode == 53 }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let self, self.isVisible else { return event }
            if isEscape(event) { self.dismiss(); return nil }
            guard event.type != .keyDown, self.interaction == .click else { return event }
            if event.window !== self.panel {
                self.dismiss()
                return event
            }
            if let fan = self.fanView, !fan.isOnFan(windowPoint: event.locationInWindow) {
                self.dismiss()
                return nil
            }
            return event
        }) {
            monitors.append(local)
        }
        // Global: Escape (only delivered with accessibility trust) and clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                if isEscape(event) { self.dismiss(); return }
                if event.type != .keyDown, self.interaction == .click { self.dismiss() }
            }
        }) {
            monitors.append(global)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func loadThumbnail(for url: URL?, into fan: FanView, generation gen: Int) {
        guard let url else { fan.thumbnail = nil; return }
        fan.thumbnail = NSWorkspace.shared.icon(forFile: url.path)
        fan.isIconThumbnail = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, weak fan] rep, _ in
            guard let cg = rep?.cgImage else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
            Task { @MainActor in
                guard let self, let fan, self.generation == gen else { return }
                fan.isIconThumbnail = false
                fan.thumbnail = image
            }
        }
    }

    static func maskImage(shape: CGPath, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        image.capInsets = NSEdgeInsets()
        image.resizingMode = .stretch
        return image
    }
}

/// Consumes the captured drag without copying/moving the source or triggering an action.
private final class NurToDragCaptureView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
}
