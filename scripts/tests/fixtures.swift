// Fixture generator and inspection helper for scripts/test-suite.sh.
// Compiled once per run with `swiftc -O`; every output is deterministic (no dates, no randomness).
//
//   fixtures orient-jpg <out>            400x300 pixels, EXIF orientation 6, Make/GPS tags
//   fixtures alpha-png <out>             256x256 RGBA, transparent background, opaque disc
//   fixtures subject-png <out>           640x480 photo-like subject on a plain background
//   fixtures qr <out> <text>             QR code (CoreImage) with a white quiet zone
//   fixtures text-image <out> <text>     1400x360 white image with large black text
//   fixtures pdf <out> <pages>           vector PDF, one "Page N" + Cyrillic line per page
//   fixtures image-pdf <out> <image>     single-page PDF holding only a raster image
//   fixtures pages <pdf>                 prints the page count (PDFKit)
//   fixtures pdf-text <pdf>              prints the PDF text layer
//   fixtures image-info <image>          prints "<w> <h> <alpha 0|1> <orientation>" as displayed
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ w: Int, _ h: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
    return ctx
}

func write(_ image: CGImage, to path: String, type: UTType, properties: [CFString: Any] = [:]) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, type.identifier as CFString, 1, nil) else { fail("dest \(path)") }
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("write \(path)") }
}

func drawText(_ text: String, in ctx: CGContext, rect: CGRect, size: CGFloat, color: NSColor = .black) {
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Helvetica-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size),
        .foregroundColor: color, .paragraphStyle: style,
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let h = str.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
    str.draw(with: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h),
             options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: fixtures <command> <path> [arg]") }
let command = args[1], path = args[2]

switch command {
case "orient-jpg":
    // Stored landscape 400x300; orientation 6 means "rotate 90° CW to display" → shown as 300x400.
    let ctx = context(400, 300)
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
    drawText("TOP", in: ctx, rect: CGRect(x: 0, y: 100, width: 400, height: 100), size: 60)
    write(ctx.makeImage()!, to: path, type: .jpeg, properties: [
        kCGImagePropertyOrientation: 6,
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFMake: "PetalwheelTestCam", kCGImagePropertyTIFFModel: "KQ-1"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.75, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 37.62, kCGImagePropertyGPSLongitudeRef: "E"],
    ])

case "alpha-png":
    let ctx = context(256, 256)
    ctx.clear(CGRect(x: 0, y: 0, width: 256, height: 256))
    ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 48, y: 48, width: 160, height: 160))
    write(ctx.makeImage()!, to: path, type: .png)

case "subject-png":
    // A simple "object on a table" scene: Vision's foreground mask needs a salient subject.
    let w = 640, h = 480
    let ctx = context(w, h)
    let bg = CGGradient(colorsSpace: srgb, colors: [CGColor(gray: 0.93, alpha: 1), CGColor(gray: 0.80, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: h), options: [])
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
    ctx.fillEllipse(in: CGRect(x: 200, y: 70, width: 260, height: 40))
    let fruit = CGGradient(colorsSpace: srgb, colors: [CGColor(red: 1, green: 0.75, blue: 0.2, alpha: 1),
                                                       CGColor(red: 0.85, green: 0.35, blue: 0.0, alpha: 1)] as CFArray,
                           locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 210, y: 90, width: 240, height: 280)); ctx.clip()
    ctx.drawRadialGradient(fruit, startCenter: CGPoint(x: 290, y: 300), startRadius: 10,
                           endCenter: CGPoint(x: 330, y: 230), endRadius: 160, options: [])
    ctx.restoreGState()
    ctx.setFillColor(CGColor(red: 0.2, green: 0.55, blue: 0.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 320, y: 350, width: 90, height: 40))
    write(ctx.makeImage()!, to: path, type: .png)

case "qr":
    guard args.count >= 4 else { fail("qr needs text") }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = args[3].data(using: .utf8)!
    filter.correctionLevel = "M"
    let scaled = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let quiet: CGFloat = 48
    let canvas = CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -quiet, dy: -quiet))
    let composed = scaled.composited(over: canvas)
    let ci = CIContext()
    guard let cg = ci.createCGImage(composed, from: composed.extent, format: .RGBA8, colorSpace: srgb) else { fail("qr") }
    write(cg, to: path, type: .png)

case "text-image":
    guard args.count >= 4 else { fail("text-image needs text") }
    let ctx = context(1400, 360)
    ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 1400, height: 360))
    drawText(args[3], in: ctx, rect: CGRect(x: 20, y: 20, width: 1360, height: 320), size: 120)
    write(ctx.makeImage()!, to: path, type: .png)

case "pdf":
    let pages = Int(args.count >= 4 ? args[3] : "3") ?? 3
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box,
                              [kCGPDFContextCreator: "Petalwheel tests", kCGPDFContextTitle: "Fixture"] as CFDictionary) else { fail("pdf") }
    for i in 1...pages {
        ctx.beginPDFPage(nil)
        drawText("Page \(i)", in: ctx, rect: CGRect(x: 40, y: 600, width: 515, height: 120), size: 48)
        drawText("Привет, мир \(i)", in: ctx, rect: CGRect(x: 40, y: 450, width: 515, height: 80), size: 28)
        ctx.endPDFPage()
    }
    ctx.closePDF()

case "image-pdf":
    guard args.count >= 4, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("image-pdf needs a readable image") }
    var box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else { fail("pdf") }
    ctx.beginPDFPage(nil)
    ctx.draw(img, in: box)
    ctx.endPDFPage()
    ctx.closePDF()

case "pages":
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { fail("not a PDF: \(path)") }
    print(doc.pageCount)

case "pdf-text":
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { fail("not a PDF: \(path)") }
    print(doc.string ?? "")

case "image-info":
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { fail("unreadable image") }
    var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    if orientation >= 5 { swap(&w, &h) }   // displayed size
    let alpha = (props[kCGImagePropertyHasAlpha] as? Bool ?? false) ? 1 : 0
    print("\(w) \(h) \(alpha) \(orientation)")

default:
    fail("unknown command \(command)")
}
