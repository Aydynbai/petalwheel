import AppKit
import SwiftUI

/// The "Grove" palette: a warm citrus accent plus earthy category colours.
/// Every colour is a light/dark pair resolved by the current appearance.
enum KQPalette {
    /// sRGB colour from a 0xRRGGBB literal.
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Appearance-dependent colour: `light` in Aqua, `dark` in Dark Aqua.
    static func dynamic(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        let l = rgb(light), d = rgb(dark)
        return NSColor(name: NSColor.Name("kq." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        }
    }

    // Raw palette (light / dark)
    static let ember = dynamic("ember", light: 0x239F89, dark: 0x59D1B7)
    /// Prominent fill under white text (light); accent-coloured text on dark backgrounds (dark).
    static let peel = dynamic("peel", light: 0x167A69, dark: 0x85E3CE)
    static let pith = dynamic("pith", light: 0xF1F8F7, dark: 0x15242A)
    static let leaf = dynamic("leaf", light: 0x4F8A5B, dark: 0x7DB889)
    static let honey = dynamic("honey", light: 0xE3A72F, dark: 0xF2C25E)
    static let terracotta = dynamic("terracotta", light: 0xC45A3C, dark: 0xE58466)
    static let denim = dynamic("denim", light: 0x4A78A6, dark: 0x86AED6)
    static let lagoon = dynamic("lagoon", light: 0x3E8C86, dark: 0x74BDB6)
    static let driftwood = dynamic("driftwood", light: 0x8B7B6B, dark: 0xBFAE9C)
    static let ink = dynamic("ink", light: 0x2A2521, dark: 0xECF4F8)
    static let inkSecondary = dynamic("inkSecondary", light: 0x6F655C, dark: 0xA5B8C6)
    static let brick = dynamic("brick", light: 0xC8443A, dark: 0xF07468)
    /// Dark window / fan glass base and its raised panel tone (appearance-independent).
    static let graphite = rgb(0x10161F)
    static let graphiteRaised = rgb(0x17212D)

    // Fixed (non-dynamic) values for surfaces that stay dark in both appearances (the fan).
    enum Dark {
        static let ember = rgb(0x59D1B7)
        static let peel = rgb(0x167A69)
        static let leaf = rgb(0x7DB889)
        static let honey = rgb(0xF2C25E)
        static let terracotta = rgb(0xE58466)
        static let denim = rgb(0x86AED6)
        static let lagoon = rgb(0x74BDB6)
        static let driftwood = rgb(0xBFAE9C)
        static let ink = rgb(0x10161F)
        static let text = rgb(0xECF4F8)
        static let textSecondary = rgb(0xA5B8C6)
    }
}

/// Shared look & feel for NurTo's windows: semantic colour tokens plus metrics.
enum KQTheme {
    // MARK: Semantic tokens (NSColor)

    /// NurTo: tints, strokes, selection rings and fills that carry dark text.
    static let accentNS = KQPalette.ember
    /// Accent-coloured text/icons on window backgrounds (Peel in light, light peel in dark): readable at small sizes.
    static let accentTextNS = KQPalette.peel
    /// Fill of prominent buttons and selected chips: Peel (light) / NurTo (dark).
    static let accentProminentFillNS = KQPalette.dynamic("accentProminentFill", light: 0x167A69, dark: 0x59D1B7)
    /// Pressed state of the prominent fill.
    static let accentProminentPressedNS = KQPalette.dynamic("accentProminentPressed", light: 0x126554, dark: 0x39B99E)
    /// Text/icons on `accentProminentFill`: white (light) / graphite (dark).
    static let onAccentProminentNS = KQPalette.dynamic("onAccentProminent", light: 0xFFFFFF, dark: 0x10161F)
    /// Warm surface tint (Pith).
    static let surfaceTintNS = KQPalette.pith
    static let successNS = KQPalette.leaf
    static let warningNS = KQPalette.honey
    static let dangerNS = KQPalette.brick
    /// Dark text on any palette fill (NurTo, Leaf, Honey…), in both appearances.
    static let textOnFillNS = KQPalette.dynamic("textOnFill", light: 0x2A2521, dark: 0x10161F)

    // MARK: Semantic tokens (SwiftUI)

    static let accent = Color(nsColor: accentNS)
    static let accentText = Color(nsColor: accentTextNS)
    static let accentProminentFill = Color(nsColor: accentProminentFillNS)
    static let accentProminentPressed = Color(nsColor: accentProminentPressedNS)
    static let onAccentProminent = Color(nsColor: onAccentProminentNS)
    static let surfaceTint = Color(nsColor: surfaceTintNS)
    static let success = Color(nsColor: successNS)
    static let warning = Color(nsColor: warningNS)
    static let danger = Color(nsColor: dangerNS)
    static let textOnFill = Color(nsColor: textOnFillNS)
    static let ink = Color(nsColor: KQPalette.ink)
    static let inkSecondary = Color(nsColor: KQPalette.inkSecondary)

    // Category colours
    static let convert = Color(nsColor: KQPalette.ember)
    static let optimize = Color(nsColor: KQPalette.leaf)
    static let edit = Color(nsColor: KQPalette.honey)
    static let combine = Color(nsColor: KQPalette.terracotta)
    static let extract = Color(nsColor: KQPalette.denim)
    static let share = Color(nsColor: KQPalette.lagoon)
    static let presets = Color(nsColor: KQPalette.driftwood)

    /// Deep end of the accent (Peel, fixed) for illustrations.
    static let accentDeep = Color(nsColor: KQPalette.rgb(0x167A69))
    /// Icon-tile gradient (NurTo → Peel) under white glyphs; identical in both appearances, like an app icon.
    static let gradient = LinearGradient(colors: [Color(nsColor: KQPalette.rgb(0x239F89)), accentDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let corner: CGFloat = 14
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 16
}

/// Material background usable as a SwiftUI view.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Prominent accent button: Peel with white text (light), NurTo with graphite text (dark).
struct KQProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(KQTheme.onAccentProminent)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isPressed ? KQTheme.accentProminentPressed : KQTheme.accentProminentFill))
            .contentShape(Rectangle())
    }
}

/// Subtle secondary button style.
struct KQSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Rectangle())
    }
}

/// An NSPanel that can become key (needed for text fields in borderless/non-activating panels).
final class KQPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

enum KQWindowing {
    /// Brings the accessory app forward so its windows can take focus.
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Screen under the mouse pointer (falls back to main).
    static var mouseScreen: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    /// Frame of `size` centered near the mouse, clamped to the visible frame.
    static func frameNearMouse(size: NSSize, offset: NSPoint = .zero) -> NSRect {
        let p = NSEvent.mouseLocation
        var origin = NSPoint(x: p.x - size.width / 2 + offset.x, y: p.y - size.height / 2 + offset.y)
        if let vf = mouseScreen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        return NSRect(origin: origin, size: size)
    }

    /// A standard titled window hosting a SwiftUI view.
    static func makeWindow<V: View>(title: String, size: NSSize, content: V) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content)
        w.setContentSize(size)
        w.center()
        return w
    }
}

extension View {
    /// Rounded material card.
    func kqCard(cornerRadius: CGFloat = KQTheme.corner) -> some View {
        background(ZStack {
                VisualEffectBackground(material: .hudWindow)
                KQTheme.surfaceTint.opacity(0.45)   // warm Pith wash over the material
            })
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
