import AppKit
import SwiftUI

/// Window listing text results (decoded QR codes, recognized text…) with Copy / Open buttons.
@MainActor
enum TextResultsWindow {
    private static var windows: [NSWindow] = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Shows text results (e.g. decoded QR codes) with per-item Copy and Copy All.
    static func show(title: String, messages: [String]) {
        let view = TextResultsView(title: title, messages: messages)
        let window = KQWindowing.makeWindow(title: title, size: NSSize(width: 480, height: 420), content: view)
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 360, height: 240)
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        windows.append(window)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                              object: window, queue: .main) { note in
            guard let closed = note.object as? NSWindow else { return }
            let key = ObjectIdentifier(closed)
            MainActor.assumeIsolated {
                windows.removeAll { ObjectIdentifier($0) == key }
                if let obs = observers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(obs) }
            }
        }
        observers[ObjectIdentifier(window)] = observer
        KQWindowing.activate()
        window.makeKeyAndOrderFront(nil)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A URL if the whole message is a web/mail/etc. link.
    static func link(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), !t.contains("\n"), let url = URL(string: t),
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host != nil ? url : nil
        case "mailto", "tel", "sms", "facetime", "maps", "geo": return url
        default: return nil
        }
    }
}

struct TextResultsView: View {
    let title: String
    let messages: [String]
    @StateObject private var state = CopyFeedback()

    var body: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            HStack(spacing: 10) {
                Image(systemName: "text.quote")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(KQTheme.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(Lp("%d results", messages.count))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Nothing found").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            row(index: index, message: message)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    TextResultsWindow.copy(messages.joined(separator: "\n\n"))
                    flash(all: true)
                } label: {
                    Label(state.copiedAll ? L("Copied") : L("Copy All"), systemImage: state.copiedAll ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(KQProminentButtonStyle())
                .disabled(messages.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 16)
        .frame(minWidth: 360, minHeight: 240)
        .background(VisualEffectBackground(material: .windowBackground).ignoresSafeArea())
    }

    private func row(index: Int, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message)
                .font(.system(size: 12, design: message.count < 200 ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                Button {
                    TextResultsWindow.copy(message)
                    flash(index: index)
                } label: {
                    Label(state.copiedIndex == index ? L("Copied") : L("Copy"),
                          systemImage: state.copiedIndex == index ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 64)
                }
                .buttonStyle(KQSecondaryButtonStyle())
                if let url = TextResultsWindow.link(in: message) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square").frame(minWidth: 64)
                    }
                    .buttonStyle(KQSecondaryButtonStyle())
                }
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func flash(index: Int? = nil, all: Bool = false) {
        let state = self.state
        withAnimation { state.copiedIndex = index; state.copiedAll = all }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation {
                if state.copiedIndex == index { state.copiedIndex = nil }
                if all { state.copiedAll = false }
            }
        }
    }
}

final class CopyFeedback: ObservableObject {
    @Published var copiedIndex: Int?
    @Published var copiedAll = false
}
