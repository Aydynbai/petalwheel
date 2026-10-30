import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragGestureMonitor()
    private let fan = FanOverlayController()
    private let coordinator = JobCoordinator()
    private let historyMenu = HistoryMenuBuilder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        fan.onSelect = { [weak self] item, urls in
            self?.coordinator.handle(item, urls: urls)
        }
        monitor.onTrigger = { [weak self] mode, point, urls in
            self?.fan.show(mode: mode, items: FanCatalog.items(for: mode, urls: urls), urls: urls, at: point, interaction: .click, awaitInitialRelease: NSEvent.pressedMouseButtons & 1 != 0, closeOnModifierRelease: true)
        }
        monitor.onModifierReleased = { [weak self] in self?.fan.modifierReleased() }
        monitor.onDragEnded = { [weak self] in
            self?.fan.dragDidEnd()
        }
        monitor.start()
        Integrations.install(showFan: { [weak self] urls in
            self?.showFan(mode: .categories, urls: urls, at: NSEvent.mouseLocation, interaction: .click)
        }, coordinator: coordinator)

        // Explicit local UI entry point for testing and Finder-independent access.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--compress-window"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            coordinator.runTool(.compress, urls: [url])
        }
    }

    private func showFan(mode: FanMode, urls: [URL], at point: NSPoint, interaction: FanInteraction) {
        let items = FanCatalog.items(for: mode, urls: urls)
        fan.show(mode: mode, items: items, urls: urls, at: point, interaction: interaction)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "NurTo")
            image?.isTemplate = true
            button.image = image
        }
        historyMenu.onRunAgain = { [weak self] entry in self?.coordinator.runAgain(entry) }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = AppSettings.shared
        let header = NSMenuItem(title: "Hold \(s.triggerKey.symbol) · 1.3 s", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item("Choose Files", #selector(chooseForConversion), "o"))
        menu.addItem(item(L("Show Float"), #selector(showFloat), "f"))
        menu.addItem(historyMenu.makeRecentItem())
        menu.addItem(.separator())
        menu.addItem(item(L("How It Works"), #selector(showWelcome), ""))
        menu.addItem(item(L("Settings…"), #selector(showSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item(L("Quit NurTo"), #selector(quit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func chooseForConversion() { chooseFiles(mode: .categories) }

    private func chooseFiles(mode: FanMode) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = L("Choose")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        // Let the open panel finish closing before the fan takes over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.showFan(mode: mode, urls: urls, at: NSEvent.mouseLocation, interaction: .click)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
    @objc private func showFloat() { FloatShelfController.shared.show() }
    @objc private func showWelcome() { WelcomeWindowController.shared.show() }
    @objc private func showSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Files dropped on the app icon / opened via `open -a NurTo file`.
    func application(_ application: NSApplication, open urls: [URL]) {
        showFan(mode: .categories, urls: urls, at: NSEvent.mouseLocation, interaction: .click)
    }
}
