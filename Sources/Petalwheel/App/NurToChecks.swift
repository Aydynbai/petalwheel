import Foundation
import AppKit

/// Small regression checks for state isolation and contextual navigation.
enum NurToChecks {
    static func run() -> Int32 {
        let video = URL(fileURLWithPath: "/tmp/nurto-check.mp4")
        let photo = URL(fileURLWithPath: "/tmp/nurto-check.png")
        let audio = URL(fileURLWithPath: "/tmp/nurto-check.wav")
        let gif = URL(fileURLWithPath: "/tmp/nurto-check.gif")
        var saved = ToolOptions(); saved.videoCompressionMode = .quality
        for url in [photo, audio, gif] {
            let model = ToolOptionsModel(tool: .compress, inputs: [url], initial: saved)
            guard model.options.videoCompressionMode == nil else { return fail("Video settings leaked to \(url.pathExtension)") }
            model.useTargetSize = true; model.targetSizeText = "2"; model.targetUnitMB = true
            guard model.result().targetSizeKB == 2048 else { return fail("Target-size controls lost") }
        }
        let mixed = ToolOptionsModel(tool: .compress, inputs: [video, photo], initial: saved)
        guard mixed.options.videoCompressionMode == nil else { return fail("Mixed files inherited video mode") }
        let videoModel = ToolOptionsModel(tool: .compress, inputs: [video], initial: saved)
        guard videoModel.result().videoCompressionMode == .quality, videoModel.result().targetSizeKB == nil else {
            return fail("Video mode not retained")
        }
        do {
            let encoded = try JSONEncoder().encode(CodableToolOptions(saved))
            let restored = try JSONDecoder().decode(CodableToolOptions.self, from: encoded)
            guard restored.options.videoCompressionMode == .quality else { return fail("Preset roundtrip") }
            let legacy = try JSONDecoder().decode(CodableToolOptions.self, from: Data("{}".utf8))
            guard legacy.options.videoCompressionMode == nil else { return fail("Legacy preset compatibility") }
        } catch { return fail(error.localizedDescription) }
        for url in [video, photo, audio] {
            let root = FanCatalog.categories(for: [url])
            guard (4...5).contains(root.count), Set(root.map(\.id)).count == root.count,
                  root.contains(where: { $0.kind == .category(.more) }),
                  root.contains(where: { $0.kind == .tool(.compress) }) else { return fail("Quick actions") }
            let more = FanCatalog.items(in: .more, urls: [url])
            guard !more.isEmpty, !more.contains(where: { $0.kind == .category(.more) }) else { return fail("More navigation recurses") }
        }
        guard MainActor.assumeIsolated({ clickHandoffCheck() }) else { return fail("Releasing the captured drag must not click a function") }
        var gate = WheelHoldGate()
        guard gate.update(down: true, now: 0) == .none,
              gate.update(down: true, now: 2.49) == .none,
              gate.update(down: true, now: 2.5) == .open,
              gate.update(down: true, now: 5) == .none,
              gate.update(down: false, now: 5.1) == .close,
              gate.update(down: false, now: 5.2) == .none,
              gate.update(down: true, now: 6) == .none,
              gate.update(down: false, now: 7) == .none else { return fail("2.5-second hold/release") }
        print("PASS: media-state isolation, target size, video selection, preset compatibility, 4–5 quick actions, More navigation")
        return 0
    }
    @MainActor
    private static func clickHandoffCheck() -> Bool {
        _ = NSApplication.shared
        let view = FanView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
        view.configure(mode: .categories, items: FanCatalog.categories(for: [URL(fileURLWithPath: "/tmp/demo.wav")]))
        view.clickEnabled = true; view.captureDrops = true
        var clicks = 0; view.onClick = { _ in clicks += 1 }
        guard let petal = view.layout.petals.first else { return false }
        let point = petal.labelCenter(view.center)
        guard let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
              let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        view.mouseUp(with: up)
        guard clicks == 0 else { return false }
        view.mouseDown(with: down); view.mouseUp(with: up)
        guard clicks == 1 else { return false }
        view.mouseUp(with: up)
        return clicks == 1
    }

    @MainActor
    static func renderWheel(to path: String) -> Int32 {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 360, height: 360)
        let view = FanView(frame: frame)
        view.configure(mode: .categories, items: FanCatalog.categories(for: [URL(fileURLWithPath: "/tmp/demo.wav")]))
        view.fileCount = 1
        view.thumbnail = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor.darkGray]))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return 1 }
        bitmap.size = frame.size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        context.cgContext.setFillColor(NSColor(srgbRed: 0.86, green: 0.89, blue: 0.94, alpha: 1).cgColor)
        context.cgContext.fill(frame)
        view.draw(frame)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return 1 }
        do { try png.write(to: URL(fileURLWithPath: path)); return 0 } catch { return 1 }
    }
    private static func fail(_ message: String) -> Int32 { fputs("FAIL: \(message)\n", stderr); return 1 }
}
