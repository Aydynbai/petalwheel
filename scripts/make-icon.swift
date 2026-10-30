#!/usr/bin/env swift
// Draws Petalwheel's app icon (a wheel of six coloured petals around a cream disc on a
// warm graphite rounded square) at every iconset size, then runs iconutil.
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
var renderPixels = 1024

func drawIcon(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(8, 16, 24, 0.35))
    ctx.addPath(tile); ctx.setFillColor(rgb(16, 22, 31)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(37, 60, 74), rgb(12, 20, 31)], [0, 1]),
        start: CGPoint(x: 180, y: 920), end: CGPoint(x: 850, y: 100), options: [])
    ctx.restoreGState()
    ctx.setLineWidth(95); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(89, 209, 183))
    ctx.move(to: CGPoint(x: 330, y: 315))
    ctx.addLine(to: CGPoint(x: 330, y: 710))
    ctx.addLine(to: CGPoint(x: 694, y: 315))
    ctx.addLine(to: CGPoint(x: 694, y: 710))
    ctx.strokePath()
}

func renderPNG(pixels: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    renderPixels = pixels
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx)
    guard let image = ctx.makeImage() else { throw NSError(domain: "make-icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "make-icon", code: 3) }
    try data.write(to: url)
}

let iconset = fm.temporaryDirectory.appendingPathComponent("Petalwheel-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

// Keep a large preview next to the .icns for docs / inspection.
try fm.createDirectory(at: outICNS.deletingLastPathComponent(), withIntermediateDirectories: true)
let preview = outICNS.deletingLastPathComponent().appendingPathComponent(outICNS.deletingPathExtension().lastPathComponent + "-1024.png")
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
