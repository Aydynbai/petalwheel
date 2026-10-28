import AppKit

/// System integrations: Finder Services, the global hotkey and watch folders.
/// Wire once from `applicationDidFinishLaunching`:
///
///     Integrations.install(showFan: { urls in … }, coordinator: coordinator)
@MainActor
enum Integrations {
    /// Opens the category wheel in click mode at the mouse for `urls`.
    private(set) static var showFan: (([URL]) -> Void)?
    /// Runs a fan item headlessly through the JobCoordinator (with the progress HUD).
    private(set) static var runItem: ((FanItem, [URL]) -> Void)?
    private static var provider: FinderServicesProvider?

    static func install(showFan: @escaping ([URL]) -> Void, coordinator: JobCoordinator) {
        install(showFan: showFan, run: { [weak coordinator] item, urls in coordinator?.handle(item, urls: urls) })
    }

    static func install(showFan: @escaping ([URL]) -> Void, run: @escaping (FanItem, [URL]) -> Void) {
        self.showFan = showFan
        self.runItem = run

        // 1. Finder Services (NSServices in Info.plist).
        let provider = FinderServicesProvider()
        self.provider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()

        // 2. Global hotkey.
        GlobalHotkey.shared.onPress = { handleHotkey() }
        GlobalHotkey.shared.start()
        // Test hook: `defaults write studio.kipper.Petalwheel integrationsDebug -bool YES`, then post
        // the distributed notification "studio.kipper.Petalwheel.simulateHotkey" to act as if the hotkey was pressed.
        if UserDefaults.standard.bool(forKey: "integrationsDebug") {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("studio.kipper.Petalwheel.simulateHotkey"),
                                                                object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handleHotkey() }
            }
        }

        // 3. Watch folders.
        WatchFolderStore.shared.start(run: run)
    }

    /// Hotkey: open the wheel for the current Finder selection.
    static func handleHotkey() {
        guard FinderSelection.finderIsFrontmost else {
            IntegrationsToast.show(L("Select files in Finder first"), symbol: "cursorarrow.click.2")
            return
        }
        FinderSelection.fetch { result in
            switch result {
            case .files(let urls):
                showFan?(urls)
            case .empty, .finderNotRunning:
                IntegrationsToast.show(L("Select files in Finder first"), symbol: "cursorarrow.click.2")
            case .notAuthorized:
                FinderSelection.presentPermissionHelp()
            case .failed(let message):
                IntegrationsToast.show(L("Couldn't read the Finder selection: %@", message), symbol: "exclamationmark.triangle")
            }
        }
    }
}

// MARK: - Toast

/// A small transient HUD near the mouse ("Select files in Finder first").
@MainActor
enum IntegrationsToast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "info.circle", duration: TimeInterval = 1.8) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = KQTheme.accentNS
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)
        let fitting = stack.fittingSize
        let size = NSSize(width: min(max(fitting.width, 120), 460), height: max(fitting.height, 40))

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        stack.frame = blur.bounds
        stack.autoresizingMask = [.width, .height]
        blur.addSubview(stack)

        let p = NSPanel(contentRect: KQWindowing.frameNearMouse(size: size, offset: NSPoint(x: 0, y: -44)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.contentView = blur
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
