import Foundation
import AppKit
import ImageIO

/// Crop, frame and collage.
enum ImageLayout {
    // MARK: Crop

    static func crop(_ url: URL, aspect: AspectRatio) async throws -> URL {
        let format = FileFormat.detect(url) ?? .png
        let loaded = try ImageCodec.load(url, format: format)
        let img = loaded.image
        let w = Double(img.width), h = Double(img.height), a = aspect.value
        var rect: CGRect
        if w / h > a {
            let nw = (h * a).rounded()
            rect = CGRect(x: ((w - nw) / 2).rounded(), y: 0, width: nw, height: h)
        } else {
            let nh = (w / a).rounded()
            rect = CGRect(x: 0, y: ((h - nh) / 2).rounded(), width: w, height: nh)
        }
        rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cropped = img.cropping(to: rect) else { throw NurToError(l: "Could not crop %@.", url.lastPathComponent) }

        var outFormat = format
        if outFormat == .webp && !ExternalTools.shared.hasWebPEncoder { outFormat = .png }
        else if outFormat != .webp && !ImageCodec.canEncode(outFormat) { outFormat = .png }
        let out = OutputNaming.url(for: url, ext: outFormat.fileExtension, suffix: "cropped")
        let meta = ImageCodec.carriedMetadata(loaded.properties, width: cropped.width, height: cropped.height)
        try await ImageCodec.write(cropped, to: out, format: outFormat, quality: 0.92, metadata: meta)
        return out
    }

    // MARK: Frame

    /// Two-colour diagonal gradient derived from one base colour.
    static func gradientColors(from color: NSColor) -> (CGColor, CGColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        func wrap(_ x: CGFloat) -> CGFloat { x < 0 ? x + 1 : (x > 1 ? x - 1 : x) }
        let light = NSColor(colorSpace: .sRGB, hue: wrap(hue + 0.035), saturation: sat * 0.75, brightness: min(1, bri * 1.08 + 0.05), alpha: 1)
        let dark = NSColor(colorSpace: .sRGB, hue: wrap(hue - 0.05), saturation: min(1, sat * 1.05 + 0.05), brightness: bri * 0.82, alpha: 1)
        return (light.cgColor, dark.cgColor)
    }

    static func frame(_ url: URL, options: ToolOptions) throws -> URL {
        let img = try ImageCodec.load(url).image
        let w = CGFloat(img.width), h = CGFloat(img.height)
        // Options are in points for a ~1200 px image; scale them for big photos.
        let s = max(1, max(w, h) / 1200)
        let pad = max(0, CGFloat(options.padding) * s)
        let radius = min(max(0, CGFloat(options.cornerRadius) * s), min(w, h) / 2)
        let cw = Int((w + 2 * pad).rounded()), ch = Int((h + 2 * pad).rounded())
        guard let ctx = ImageCodec.makeContext(width: cw, height: ch, opaque: false) else {
            throw NurToError(l: "Could not allocate an image of %d×%d.", cw, ch)
        }
        let canvas = CGRect(x: 0, y: 0, width: cw, height: ch)
        let (c1, c2) = gradientColors(from: options.backgroundColor)
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c1, c2] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.maxY), end: CGPoint(x: canvas.maxX, y: 0), options: [])
        }
        let imageRect = CGRect(x: pad, y: pad, width: w, height: h)
        let clip = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.interpolationQuality = .high
        if options.shadow && pad > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.18), blur: pad * 0.55,
                          color: CGColor(gray: 0, alpha: 0.35))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(clip)
        ctx.clip()
        ctx.draw(img, in: imageRect)
        ctx.endTransparencyLayer()
        guard let result = ctx.makeImage() else { throw NurToError(l: "Could not render the frame.") }
        let out = OutputNaming.url(for: url, ext: "png", suffix: "framed")
        try ImageCodec.encode(result, format: .png, quality: 1).write(to: out, options: .atomic)
        return out
    }

    // MARK: Collage

    /// Decodes an image downscaled to at most `maxSide` pixels, orientation applied.
    static func thumbnail(_ url: URL, maxSide: Int) throws -> CGImage {
        if FileFormat.detect(url) == .svg { return ImageCodec.limited(try ImageCodec.renderSVG(url), maxSide: maxSide) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
              ] as CFDictionary) else {
            throw NurToError(l: "Could not read the image %@.", url.lastPathComponent)
        }
        return img
    }

    static func collage(_ inputs: [URL], options: ToolOptions, progress: @escaping ProgressHandler) throws -> URL {
        let sizes = inputs.map { ImageCodec.pixelSize($0) ?? CGSize(width: 1000, height: 1000) }
        let aspects = sizes.map { $0.width / max(1, $0.height) }.sorted()
        let aspect = aspects[aspects.count / 2]
        let widths = sizes.map(\.width).sorted()
        let cellW = min(1200, max(300, widths[widths.count / 2])).rounded()
        let cellH = (cellW / aspect).rounded()
        let cols = max(1, min(options.collageColumns, inputs.count))
        let rows = (inputs.count + cols - 1) / cols
        let gap = max(0, CGFloat(options.collageSpacing) * max(1, cellW / 600)).rounded()
        let W = Int(CGFloat(cols) * cellW + CGFloat(cols + 1) * gap)
        let H = Int(CGFloat(rows) * cellH + CGFloat(rows + 1) * gap)
        guard W * H <= 300_000_000, let ctx = ImageCodec.makeContext(width: W, height: H, opaque: true) else {
            throw NurToError(l: "The collage would be too large.")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .high
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let img = try autoreleasepool { try thumbnail(url, maxSide: Int(max(cellW, cellH) * 1.5)) }
            let row = i / cols, col = i % cols
            // Centre the last row if it's not full.
            let inRow = row == rows - 1 ? inputs.count - row * cols : cols
            let rowOffset = CGFloat(cols - inRow) * (cellW + gap) / 2
            let cell = CGRect(x: gap + CGFloat(col) * (cellW + gap) + rowOffset,
                              y: CGFloat(H) - gap - CGFloat(row + 1) * cellH - CGFloat(row) * gap,
                              width: cellW, height: cellH)
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let scale = min(cell.width / iw, cell.height / ih)
            let dw = iw * scale, dh = ih * scale
            ctx.draw(img, in: CGRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh))
            progress(Double(i + 1) / Double(inputs.count) * 0.9)
        }
        guard let result = ctx.makeImage() else { throw NurToError(l: "Could not render the collage.") }
        let out = OutputNaming.url(named: "Collage", ext: "png", in: inputs[0].deletingLastPathComponent())
        try ImageCodec.encode(result, format: .png, quality: 1).write(to: out, options: .atomic)
        progress(1)
        return out
    }
}
