import AppKit

/// Questions the archive tools ask while running. In CLI mode (no NSApplication) nothing is shown:
/// the password comes from `--password` and risky extractions are refused.
enum ArchivePrompts {
    static var isInteractive: Bool {
        get async { await MainActor.run { NSApp != nil } }
    }

    /// Asks for the archive password in the tool options panel. `previous` is the password that just
    /// failed (the panel then says it was wrong). nil = cancelled or not interactive.
    static func askPassword(tool: FileTool, archive: URL, previous: String?) async -> String? {
        guard await isInteractive else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            Task { @MainActor in
                var initial = ToolOptions()
                initial.archivePassword = previous
                ToolOptionsPanel.present(tool: tool, inputs: [archive], initial: initial) { result in
                    cont.resume(returning: result?.archivePassword)
                }
            }
        }
    }

    /// Zip-bomb guard: true when the user chose to extract anyway.
    static func confirmLargeExtraction(archive: URL, packed: Int64, unpacked: Int64) async -> Bool {
        guard await isInteractive else { return false }
        return await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("“%@” unpacks to %@", archive.lastPathComponent, ArchiveSupport.formatSize(unpacked))
            alert.informativeText = L("That is %d times its own size (%@). It may be a zip bomb that fills up the disk. Extract anyway?",
                                      Int(unpacked / max(packed, 1)), ArchiveSupport.formatSize(packed))
            alert.addButton(withTitle: L("Cancel"))
            alert.addButton(withTitle: L("Extract Anyway"))
            KQWindowing.activate()
            return alert.runModal() == .alertSecondButtonReturn
        }
    }
}
