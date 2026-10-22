import AppKit

/// The "Actions" wheel: Float, AirDrop, Copy, Copy Path, Move To…, Terminal.
@MainActor
final class ActionPerformer {
    func perform(_ action: FileAction, urls: [URL]) {
        switch action {
        case .float:
            FloatShelfController.shared.add(urls)
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                return fail("AirDrop", L("AirDrop isn't available on this Mac right now."))
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            confirm(L("Copied %@", count(urls)))
        case .copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            confirm(urls.count == 1 ? L("Copied path") : Lp("Copied %d paths", urls.count))
        case .move:
            move(urls)
        case .openTerminal:
            openTerminal(urls)
        }
    }

    private func move(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Move Here")
        panel.message = L("Choose a destination for %@", count(urls))
        panel.directoryURL = urls.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        var moved: [URL] = []
        var failures: [String] = []
        for url in urls {
            let target = OutputNaming.unique(destination.appendingPathComponent(url.lastPathComponent))
            do {
                try FileManager.default.moveItem(at: url, to: target)
                moved.append(target)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let id = OperationProgress.shared.start(title: L("Moved %@", count(moved)), itemCount: urls.count, onCancel: {})
        OperationProgress.shared.finish(id, outputs: moved, failures: failures)
    }

    private func openTerminal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
        let folder = isDir.boolValue ? first : first.deletingLastPathComponent()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: config) { _, error in
            if let error {
                Task { @MainActor in self.fail(L("Terminal"), error.localizedDescription) }
            }
        }
    }

    private func count(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : Lp("%d items", urls.count)
    }

    private func confirm(_ title: String) {
        let id = OperationProgress.shared.start(title: title, itemCount: 1, onCancel: {})
        OperationProgress.shared.finish(id, outputs: [], failures: [])
    }

    private func fail(_ title: String, _ message: String) {
        let id = OperationProgress.shared.start(title: title, itemCount: 1, onCancel: {})
        OperationProgress.shared.finish(id, outputs: [], failures: [message])
    }
}
