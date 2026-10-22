import AppKit
import SwiftUI

/// First-run onboarding window.
@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = WelcomeView(onDone: { [weak self] in self?.complete() })
            let w = KQWindowing.makeWindow(title: L("Welcome to Kumquat"), size: NSSize(width: 560, height: 520), content: view)
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.collectionBehavior = [.moveToActiveSpace]
            window = w
        }
        KQWindowing.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func complete() {
        AppSettings.shared.hasCompletedWelcome = true
        window?.close()
    }
}

struct WelcomeView: View {
    @ObservedObject var settings = AppSettings.shared
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            PetalWheelIllustration()
                .frame(width: 190, height: 190)
                .padding(.top, 8)

            VStack(spacing: 4) {
                Text("Welcome to Kumquat")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Convert files without leaving Finder.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                step(1, title: L("Start dragging files in Finder"),
                     detail: L("Pick one file or a whole selection and begin a drag."))
                step(2, title: L("Tap the key while dragging, pick a category"),
                     detail: nil, keys: true)
                step(3, title: L("Drop onto a petal"),
                     detail: L("Hover a category to open it, hover the centre to go back. Results are saved next to the originals."))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: KQTheme.corner, style: .continuous).fill(Color.primary.opacity(0.045)))

            Button(action: onDone) {
                Text("Get Started").frame(minWidth: 160)
            }
            .buttonStyle(KQProminentButtonStyle())
            .keyboardShortcut(.defaultAction)

            CreditsView(compact: true)
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .frame(width: 560)
        .background(ZStack { VisualEffectBackground(material: .windowBackground); KQTheme.surfaceTint.opacity(0.55) }.ignoresSafeArea())
    }

    private func step(_ n: Int, title: String, detail: String?, keys: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(n)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(KQTheme.onAccentProminent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(KQTheme.accentProminentFill))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if keys {
                    HStack(spacing: 10) {
                        keyHint(settings.triggerKey, L("opens the wheel"))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func keyHint(_ key: ModifierKey, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key.symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 24, minHeight: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 1))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A radial wheel of petals around a dragged file, drawn in SwiftUI.
struct PetalWheelIllustration: View {
    private let labels = ["JPG", "PNG", "PDF", "MP4", "GIF", "WEBP", "MP3", "HEIC"]
    private let highlighted = 1

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let radius = s * 0.36
            ZStack {
                Circle()
                    .fill(KQTheme.accent.opacity(0.10))
                    .frame(width: s, height: s)
                ForEach(labels.indices, id: \.self) { i in
                    let angle = Double(i) / Double(labels.count) * 2 * .pi - .pi / 2
                    let selected = i == highlighted
                    Text(labels[i])
                        .font(.system(size: s * 0.058, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? KQTheme.textOnFill : Color.primary.opacity(0.75))
                        .frame(width: s * 0.2, height: s * 0.2)
                        .background(Circle().fill(selected ? AnyShapeStyle(KQTheme.accent)
                                                           : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))))
                        .overlay(Circle().strokeBorder(selected ? Color.clear : Color.primary.opacity(0.1), lineWidth: 1))
                        .shadow(color: .black.opacity(selected ? 0.25 : 0.1), radius: selected ? 5 : 2, y: 1)
                        .scaleEffect(selected ? 1.15 : 1)
                        .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                }
                // Dragged file in the middle.
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: s * 0.025, style: .continuous)
                        .fill(Color.white)
                        .frame(width: s * 0.17, height: s * 0.21)
                        .overlay(
                            VStack(spacing: s * 0.018) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Capsule().fill(Color.gray.opacity(0.35)).frame(width: s * 0.1, height: s * 0.012)
                                }
                            }
                        )
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                    Image(systemName: "cursorarrow")
                        .font(.system(size: s * 0.09, weight: .regular))
                        .foregroundStyle(.black)
                        .shadow(color: .white, radius: 1)
                        .offset(x: s * 0.07, y: s * 0.12)
                }
                .rotationEffect(.degrees(-8))
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
