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
    // macOS Big Sur+ grid: 824pt body centered in 1024 with a ~185pt corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(20, 12, 6, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(38, 33, 29))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: warm graphite, slightly lighter at the top.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(54, 47, 41), rgb(28, 25, 22)], [0, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft warm glow behind the wheel.
    ctx.drawRadialGradient(gradient([rgb(240, 122, 34, 0.22), rgb(240, 122, 34, 0)], [0, 1]),
                           startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])
    ctx.restoreGState()

    // The wheel: six petals (annular sectors with gaps), category colours, top one highlighted.
    let center = CGPoint(x: 512, y: 512)
    let colors: [CGColor] = [
        rgb(240, 122, 34),   // Convert – orange (top)
        rgb(79, 138, 91),    // Optimize – leaf
        rgb(227, 167, 47),   // Edit – honey
        rgb(196, 90, 60),    // Combine – terracotta
        rgb(74, 120, 166),   // Extract – denim
        rgb(62, 140, 134),   // Share – lagoon
    ]
    let n = colors.count
    let step = 2 * CGFloat.pi / CGFloat(n)
    let gap: CGFloat = 0.075            // radians between petals
    let inner: CGFloat = 150, outer: CGFloat = 318, rounding: CGFloat = 26
    for i in 0..<n {
        let mid = CGFloat.pi / 2 - CGFloat(i) * step            // start at the top, go clockwise
        let a0 = mid + step / 2 - gap / 2, a1 = mid - step / 2 + gap / 2
        let highlighted = i == 0
        let r1 = highlighted ? outer + 34 : outer
        let r0 = inner + (highlighted ? 6 : 0)
        let path = CGMutablePath()
        // Inset by half the stroke so the rounded stroke keeps the intended size.
        let o = r1 - rounding / 2, inR = r0 + rounding / 2
        let da = (rounding / 2) / o, dai = (rounding / 2) / inR
        path.addArc(center: center, radius: o, startAngle: a0 - da, endAngle: a1 + da, clockwise: true)
        path.addArc(center: center, radius: inR, startAngle: a1 + dai, endAngle: a0 - dai, clockwise: false)
        path.closeSubpath()
        ctx.saveGState()
        if highlighted {
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 28, color: rgb(240, 122, 34, 0.55))
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 14, color: rgb(0, 0, 0, 0.35))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // one shadow for fill + rounded stroke
        ctx.addPath(path)
        ctx.setFillColor(colors[i])
        ctx.setStrokeColor(colors[i])
        ctx.setLineWidth(rounding)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // Centre disc: warm cream with a soft inner shadow edge.
    let disc = CGRect(x: center.x - 112, y: center.y - 112, width: 224, height: 224)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0, 0, 0, 0.4))
    ctx.addEllipse(in: disc)
    ctx.setFillColor(rgb(251, 244, 234))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(255, 252, 246), rgb(242, 222, 196)], [0, 1]),
                           start: CGPoint(x: 512, y: disc.maxY), end: CGPoint(x: 512, y: disc.minY), options: [])
    ctx.restoreGState()

    // Tiny document glyph in the centre (folded corner), in graphite. Too noisy below 64 px.
    guard renderPixels >= 64 else { return }
    let doc = CGRect(x: 512 - 42, y: 512 - 56, width: 84, height: 112)
    let fold: CGFloat = 28
    let page = CGMutablePath()
    page.move(to: CGPoint(x: doc.minX, y: doc.minY))
    page.addLine(to: CGPoint(x: doc.maxX, y: doc.minY))
    page.addLine(to: CGPoint(x: doc.maxX, y: doc.maxY - fold))
    page.addLine(to: CGPoint(x: doc.maxX - fold, y: doc.maxY))
    page.addLine(to: CGPoint(x: doc.minX, y: doc.maxY))
    page.closeSubpath()
    ctx.saveGState()
    ctx.addPath(page)
    ctx.setStrokeColor(rgb(54, 47, 41))
    ctx.setLineWidth(12)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: doc.maxX - fold, y: doc.maxY))
    ctx.addLine(to: CGPoint(x: doc.maxX - fold, y: doc.maxY - fold))
    ctx.addLine(to: CGPoint(x: doc.maxX, y: doc.maxY - fold))
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
