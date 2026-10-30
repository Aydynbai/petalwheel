import AppKit
import SwiftUI

extension FanCategory {
    /// Category colour from the Grove palette (light/dark dynamic).
    var color: NSColor {
        switch self {
        case .convert: return KQPalette.ember
        case .optimize: return KQPalette.leaf
        case .edit: return KQPalette.honey
        case .combine: return KQPalette.terracotta
        case .extract: return KQPalette.denim
        case .share: return KQPalette.lagoon
        case .more: return NSColor(srgbRed: 0.45, green: 0.5, blue: 0.6, alpha: 1)
        case .favorites: return KQPalette.driftwood
        }
    }

    /// SwiftUI version of `color`.
    var swiftUIColor: Color { Color(nsColor: color) }

    /// The category colour as drawn on the fan, which is dark glass in both appearances.
    var fanColor: NSColor {
        switch self {
        case .convert: return KQPalette.Dark.ember
        case .optimize: return KQPalette.Dark.leaf
        case .edit: return KQPalette.Dark.honey
        case .combine: return KQPalette.Dark.terracotta
        case .extract: return KQPalette.Dark.denim
        case .share: return KQPalette.Dark.lagoon
        case .more: return NSColor(srgbRed: 0.55, green: 0.62, blue: 0.75, alpha: 1)
        case .favorites: return KQPalette.Dark.driftwood
        }
    }
}
