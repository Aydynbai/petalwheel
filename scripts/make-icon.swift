#!/usr/bin/env swift
// Draws Kumquat's app icon (a whole oval kumquat with a leaf on a warm
// rounded-square background) at every iconset size, then runs iconutil.
//
// Usage: swift scripts/make-icon.swift [output.icns]   (default: Resources/AppIcon.icns)

import AppKit
import CoreGraphics

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let outICNS = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("Resources/AppIcon.icns")

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// Draws the icon into a 1024×1024 coordinate space (origin bottom-left).
func drawIcon(_ ctx: CGContext) {
    // macOS Big Sur+ grid: 824pt body centered in 1024 with a ~185pt corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(80, 30, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(255, 160, 70))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: warm vertical gradient, cream at the top to orange at the bottom.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(255, 233, 196), rgb(255, 190, 112), rgb(255, 128, 38)], [0, 0.5, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft glow behind the fruit.
    ctx.drawRadialGradient(gradient([rgb(255, 250, 235, 0.65), rgb(255, 250, 235, 0)], [0, 1]),
                           startCenter: CGPoint(x: 470, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 560), endRadius: 420, options: [])
    // Subtle top sheen.
    ctx.drawLinearGradient(gradient([rgb(255, 255, 255, 0.28), rgb(255, 255, 255, 0)], [0, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 680), options: [])
    ctx.restoreGState()

    // The fruit: a tilted oval.
    let fruitCenter = CGPoint(x: 492, y: 470)
    let fruitW: CGFloat = 400, fruitH: CGFloat = 520
    var t = CGAffineTransform(translationX: fruitCenter.x, y: fruitCenter.y).rotated(by: -0.42)
    let fruit = CGPath(ellipseIn: CGRect(x: -fruitW / 2, y: -fruitH / 2, width: fruitW, height: fruitH), transform: &t)

    // Contact shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 10, height: -26), blur: 40, color: rgb(120, 40, 0, 0.45))
    ctx.addPath(fruit)
    ctx.setFillColor(rgb(240, 110, 20))
    ctx.fillPath()
    ctx.restoreGState()

    // Fruit body shading.
    ctx.saveGState()
    ctx.addPath(fruit)
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(255, 196, 92), rgb(255, 140, 30), rgb(226, 86, 10), rgb(178, 56, 6)], [0, 0.38, 0.78, 1]),
                           startCenter: CGPoint(x: 420, y: 600), startRadius: 10,
                           endCenter: CGPoint(x: 500, y: 450), endRadius: 330, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Peel texture: tiny pores.
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rand() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) % 10_000) / 10_000
    }
    for _ in 0..<170 {
        let x = 260 + rand() * 470, y = 190 + rand() * 560
        let r = 3 + rand() * 4
        ctx.setFillColor(rgb(255, 214, 140, 0.18 + rand() * 0.12))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
    }
    // Rim light on the lower right.
    ctx.drawRadialGradient(gradient([rgb(255, 170, 80, 0), rgb(255, 170, 80, 0), rgb(255, 196, 120, 0.55)], [0, 0.8, 1]),
                           startCenter: CGPoint(x: 470, y: 500), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 500), endRadius: 300, options: [])
    ctx.restoreGState()

    // Specular highlight: a soft elongated glow (no hard edge).
    ctx.saveGState()
    ctx.addPath(fruit)
    ctx.clip()
    ctx.translateBy(x: 400, y: 612)
    ctx.rotate(by: -0.42)
    ctx.scaleBy(x: 1, y: 1.7)
    ctx.drawRadialGradient(gradient([rgb(255, 255, 255, 0.92), rgb(255, 250, 230, 0.45), rgb(255, 245, 220, 0)], [0, 0.45, 1]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 78, options: [])
    ctx.restoreGState()

    // Stem dimple at the top of the fruit.
    let stem = CGPoint(x: 590, y: 705)
    ctx.setFillColor(rgb(150, 70, 10, 0.55))
    ctx.fillEllipse(in: CGRect(x: stem.x - 22, y: stem.y - 14, width: 44, height: 28))
    ctx.setFillColor(rgb(96, 120, 40))
    ctx.fillEllipse(in: CGRect(x: stem.x - 12, y: stem.y - 6, width: 24, height: 16))

    // Short stem.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(18)
    ctx.setStrokeColor(rgb(98, 112, 38))
    ctx.move(to: CGPoint(x: stem.x, y: stem.y + 2))
    ctx.addQuadCurve(to: CGPoint(x: 618, y: 768), control: CGPoint(x: 600, y: 742))
    ctx.strokePath()
    ctx.restoreGState()

    // Leaf: a pointed almond shape sweeping to the upper right.
    let base = CGPoint(x: 616, y: 762)
    let tip = CGPoint(x: 830, y: 820)
    let leaf = CGMutablePath()
    leaf.move(to: base)
    leaf.addCurve(to: tip, control1: CGPoint(x: 650, y: 880), control2: CGPoint(x: 770, y: 900))
    leaf.addCurve(to: base, control1: CGPoint(x: 790, y: 720), control2: CGPoint(x: 680, y: 700))
    leaf.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: rgb(40, 60, 0, 0.35))
    ctx.addPath(leaf)
    ctx.setFillColor(rgb(70, 140, 50))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(leaf)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(140, 200, 80), rgb(72, 150, 52), rgb(36, 102, 40)], [0, 0.5, 1]),
                           start: CGPoint(x: 700, y: 880), end: CGPoint(x: 740, y: 720), options: [])
    // Midrib.
    ctx.setLineCap(.round)
    ctx.setLineWidth(7)
    ctx.setStrokeColor(rgb(210, 240, 160, 0.7))
    ctx.move(to: base)
    ctx.addQuadCurve(to: CGPoint(x: tip.x - 14, y: tip.y - 2), control: CGPoint(x: 720, y: 805))
    ctx.strokePath()
    ctx.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx)
    guard let image = ctx.makeImage() else { throw NSError(domain: "make-icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "make-icon", code: 3) }
    try data.write(to: url)
}

let iconset = fm.temporaryDirectory.appendingPathComponent("Kumquat-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

// Keep a large preview next to the .icns for docs / inspection.
try fm.createDirectory(at: outICNS.deletingLastPathComponent(), withIntermediateDirectories: true)
let preview = outICNS.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png")
try renderPNG(pixels: 1024, to: preview)

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outICNS.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed with status \(p.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(outICNS.path)")
print("Preview \(preview.path)")
