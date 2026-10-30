import AppKit

if let status = CommandLineMode.runIfRequested(CommandLine.arguments) {
    exit(status)
}

PreferencesMigration.run()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.appearance = NSAppearance(named: .aqua)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
