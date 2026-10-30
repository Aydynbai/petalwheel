import Foundation
import AppKit
import CoreImage
import ImageIO
import Metal

// MARK: - Parameters

enum AdjustGroup: String, CaseIterable, Identifiable {
    case light = "Light", color = "Color", detail = "Detail", effects = "Effects"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return L("Light")
        case .color: return L("Color")
        case .detail: return L("Detail")
        case .effects: return L("Effects")
        }
    }

    var params: [AdjustParam] {
        switch self {
        case .light: return [.exposure, .brightness, .contrast, .highlights, .shadows, .whites, .blacks, .gamma]
        case .color: return [.temperature, .tint, .saturation, .vibrance, .hue]
        case .detail: return [.clarity, .texture, .sharpness, .dehaze, .noiseReduction]
        case .effects: return [.fade, .vignette, .grain, .blur]
        }
    }

    var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .color: return "paintpalette"
        case .detail: return "triangle.lefthalf.filled"
        case .effects: return "sparkles"
        }
    }
}

enum AdjustParam: String, CaseIterable, Identifiable {
    case exposure, brightness, contrast, highlights, shadows, whites, blacks, gamma
    case temperature, tint, saturation, vibrance, hue
    case clarity, texture, sharpness, dehaze, noiseReduction
    case fade, vignette, grain, blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exposure: return L("Exposure")
        case .brightness: return L("Brightness")
        case .contrast: return L("Contrast")
        case .highlights: return L("Highlights")
        case .shadows: return L("Shadows")
        case .whites: return L("Whites")
        case .blacks: return L("Blacks")
        case .gamma: return L("Gamma")
        case .temperature: return L("Temperature")
        case .tint: return L("Tint")
        case .saturation: return L("Saturation")
        case .vibrance: return L("Vibrance")
        case .hue: return L("Hue")
        case .clarity: return L("Clarity")
        case .texture: return L("Texture")
        case .sharpness: return L("Sharpness")
        case .dehaze: return L("Dehaze")
        case .noiseReduction: return L("Noise Reduction")
        case .fade: return L("Fade")
        case .vignette: return L("Vignette")
        case .grain: return L("Grain")
        case .blur: return L("Blur")
        }
    }

    /// One-sided parameters start at 0 and only go up; the rest are centered at 0.
    var isBipolar: Bool { ![.sharpness, .noiseReduction, .fade, .grain, .blur].contains(self) }
    var range: ClosedRange<Double> { isBipolar ? -100...100 : 0...100 }

    func display(_ v: Double) -> String {
        let r = Int(v.rounded())
        if self == .hue { return r == 0 ? "0°" : String(format: "%+d°", Int((v * 1.8).rounded())) }
        if self == .exposure { return r == 0 ? "0" : String(format: "%+.2f EV", v / 50) }
        if !isBipolar || r == 0 { return "\(r)" }
        return String(format: "%+d", r)
    }
}

/// Immutable bag of slider values (−100…100 or 0…100; 0 = neutral).
struct AdjustSettings: Equatable {
    private(set) var values: [AdjustParam: Double] = [:]

    subscript(_ p: AdjustParam) -> Double {
        get { values[p] ?? 0 }
        set {
            let v = min(max(newValue.rounded(), p.range.lowerBound), p.range.upperBound)
            values[p] = v == 0 ? nil : v
        }
    }

    var isNeutral: Bool { values.isEmpty }

    init(_ pairs: [AdjustParam: Double] = [:]) {
        for (k, v) in pairs { self[k] = v }
    }
}

struct AdjustPreset: Identifiable {
    let name: String
    let settings: AdjustSettings
    var id: String { name }
    var title: String {
        switch name {
        case "Vivid": return L("Vivid")
        case "Warm": return L("Warm")
        case "Cool": return L("Cool")
        case "B&W": return L("B&W")
        case "Matte": return L("Matte")
        case "Punch": return L("Punch")
        default: return name
        }
    }

    static let all: [AdjustPreset] = [
        AdjustPreset(name: "Vivid", settings: AdjustSettings([.vibrance: 45, .saturation: 12, .contrast: 12, .clarity: 12])),
        AdjustPreset(name: "Warm", settings: AdjustSettings([.temperature: 40, .tint: 6, .vibrance: 12, .highlights: -10])),
        AdjustPreset(name: "Cool", settings: AdjustSettings([.temperature: -40, .tint: -4, .vibrance: 8, .contrast: 6])),
        AdjustPreset(name: "B&W", settings: AdjustSettings([.saturation: -100, .contrast: 22, .clarity: 18, .blacks: -8])),
        AdjustPreset(name: "Matte", settings: AdjustSettings([.fade: 40, .contrast: -14, .saturation: -12, .highlights: -15, .grain: 6])),
        AdjustPreset(name: "Punch", settings: AdjustSettings([.contrast: 30, .clarity: 30, .vibrance: 28, .dehaze: 18, .vignette: 25, .sharpness: 20])),
    ]
}

// MARK: - CoreImage pipeline

enum AdjustPipeline {
    /// Shared GPU-backed context (thread-safe), used for both the preview and the export.
    static let context: CIContext = {
        let opts: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "NurTo.Adjust"]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: opts) }
        return CIContext(options: opts)
    }()

    /// Applies `s` to `input`. Spatial radii scale with the image so a 1600 px proxy previews the full-size result.
    static func apply(_ s: AdjustSettings, to input: CIImage) -> CIImage {
        guard !s.isNeutral else { return input }
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1600
        func v(_ p: AdjustParam) -> Double { s[p] / 100 }
        var img = input

        // Light
        if v(.exposure) != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: v(.exposure) * 2])
        }
        if let curve = toneCurve(s) {
            img = img.applyingFilter("CIToneCurve", parameters: curve)
        }
        if v(.shadows) != 0 || v(.highlights) < 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(0, v(.highlights)) * 0.9,
                "inputShadowAmount": v(.shadows) * 0.9,
            ])
        }
        if v(.gamma) != 0 {
            img = img.applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(2.0, -v(.gamma) * 0.8)])
        }
        let dehaze = v(.dehaze)
        let contrast = 1 + v(.contrast) * 0.35 + dehaze * 0.18
        let saturation = max(0, 1 + v(.saturation) + dehaze * 0.15)
        let brightness = v(.brightness) * 0.2
        if contrast != 1 || saturation != 1 || brightness != 0 {
            // Contrast pivots around perceptual mid-grey, so apply it on gamma-encoded values.
            img = img.applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation,
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }

        // Color
        if v(.temperature) != 0 || v(.tint) != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - v(.temperature) * 2500, y: -v(.tint) * 60),
            ])
        }
        if v(.vibrance) != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": v(.vibrance)])
        }
        if v(.hue) != 0 {
            img = img.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: v(.hue) * .pi])
        }

        // Detail (convolutions sample outside the extent, so clamp first)
        if v(.noiseReduction) > 0 {
            img = img.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.005 + v(.noiseReduction) * 0.06, "inputSharpness": 0.4,
            ]).cropped(to: extent)
        }
        if v(.clarity) != 0 {
            img = img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 25 * unit, kCIInputIntensityKey: v(.clarity) * 0.9,
            ]).cropped(to: extent)
        }
        if v(.texture) != 0 {
            img = img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 2.5 * unit, kCIInputIntensityKey: v(.texture) * 1.2,
            ]).cropped(to: extent)
        }
        if v(.sharpness) > 0 {
            img = img.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: v(.sharpness) * 1.2, kCIInputRadiusKey: 1.5 * unit,
            ]).cropped(to: extent)
        }

        // Effects
        if v(.blur) > 0 {
            img = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: v(.blur) * 25 * unit,
            ]).cropped(to: extent)
        }
        if v(.vignette) != 0 {
            let diag = hypot(extent.width, extent.height)
            img = img.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: diag * 0.42,
                kCIInputIntensityKey: v(.vignette) > 0 ? v(.vignette) : v(.vignette) * 0.45,
                "inputFalloff": 0.6,
            ]).cropped(to: extent)
        }
        if v(.grain) > 0 {
            img = addGrain(to: img, amount: v(.grain), unit: unit)
        }
        return img.cropped(to: extent)
    }

    /// Whites, blacks, positive highlights, fade and dehaze's black point as a single 5-point curve.
    private static func toneCurve(_ s: AdjustSettings) -> [String: Any]? {
        let wh = s[.whites] / 100, bl = s[.blacks] / 100, fade = s[.fade] / 100
        let hl = max(0, s[.highlights] / 100), dz = s[.dehaze] / 100
        guard wh != 0 || bl != 0 || fade != 0 || hl != 0 || dz != 0 else { return nil }
        let x0 = max(0, -bl) * 0.15 + max(0, dz) * 0.05
        let y0 = max(0, bl) * 0.12 + fade * 0.22 + max(0, -dz) * 0.14
        let x4 = 1 - max(0, wh) * 0.15
        let y4 = 1 - max(0, -wh) * 0.15 - fade * 0.04 - max(0, -dz) * 0.04
        let y1 = min(0.45, max(y0 + 0.01, 0.25 + y0 * 0.45 - x0 * 0.3))
        let y3 = max(0.55, min(y4 - 0.01, 0.75 + (y4 - 1) * 0.45 + (1 - x4) * 0.3 + hl * 0.13))
        let y2 = 0.5 + (y0 - x0) * 0.2 + (y4 - x4) * 0.2 + hl * 0.04
        return [
            "inputPoint0": CIVector(x: x0, y: y0),
            "inputPoint1": CIVector(x: 0.25, y: y1),
            "inputPoint2": CIVector(x: 0.5, y: min(y3 - 0.01, max(y1 + 0.01, y2))),
            "inputPoint3": CIVector(x: 0.75, y: y3),
            "inputPoint4": CIVector(x: x4, y: y4),
        ]
    }

    /// Monochrome film grain: CIRandomGenerator noise, scaled, soft-light blended over the image.
    private static func addGrain(to img: CIImage, amount: Double, unit: CGFloat) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return img }
        let extent = img.extent
        let gray = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let size = max(1, unit * 1.3)
        let a = amount * 0.35
        let grain = gray
            .transformed(by: CGAffineTransform(scaleX: size, y: size))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.5 - 0.5 * a, y: 0.5 - 0.5 * a, z: 0.5 - 0.5 * a, w: 0),
            ])
            .cropped(to: extent)
        // Blend on gamma-encoded values so mid-grey noise leaves the average brightness alone.
        return grain.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: img.applyingFilter("CILinearToSRGBToneCurve"),
        ]).applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    // MARK: Loading & rendering

    /// Oriented, downscaled proxy for the live preview (long side ≤ `maxSide`).
    static func loadProxy(_ url: URL, maxSide: Int = 1600) -> CGImage? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(src) > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), opts as CFDictionary) {
                return img
            }
        }
        guard let loaded = try? ImageCodec.load(url) else { return nil }
        return ImageCodec.limited(loaded.image, maxSide: maxSide)
    }

    static func render(_ image: CIImage, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let cs = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: cs)
    }

    // MARK: Export

    static let keptFormats: [FileFormat] = [.jpg, .png, .heic, .tiff]

    /// Format of the adjusted copy: jpg/png/heic/tiff are kept, anything else becomes PNG.
    static func outputFormat(for url: URL) -> FileFormat {
        if let f = FileFormat.detect(url), keptFormats.contains(f), ImageCodec.canEncode(f) { return f }
        return .png
    }

    /// Full-resolution render of one file, written next to it as "<name> (adjusted).<ext>".
    static func exportFile(_ url: URL, settings: AdjustSettings) throws -> URL {
        let loaded = try ImageCodec.load(url)
        let source = loaded.image
        let ci = CIImage(cgImage: source)
        let cs: CGColorSpace = {
            if let c = source.colorSpace, c.model == .rgb { return c }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        guard var out = render(apply(settings, to: ci), colorSpace: cs) else {
            throw NurToError(l: "Could not render %@.", url.lastPathComponent)
        }
        if !ImageCodec.hasAlpha(source) { out = ImageCodec.flatten(out) }
        let format = outputFormat(for: url)
        let meta = ImageCodec.carriedMetadata(loaded.properties, width: out.width, height: out.height)
        let data = try ImageCodec.encode(out, format: format, quality: 0.92, metadata: meta)
        let dest = OutputNaming.url(for: url, ext: format.fileExtension, suffix: "adjusted")
        try data.write(to: dest, options: .withoutOverwriting)
        return dest
    }

    static func makeExport(inputs: [URL], settings: AdjustSettings) -> EditorExport {
        let files = inputs
        let snapshot = settings
        return { progress in
            try await Task.detached(priority: .userInitiated) {
                var outputs: [URL] = []
                for (i, url) in files.enumerated() {
                    try Task.checkCancellation()
                    progress(Double(i) / Double(files.count) + 0.05 / Double(files.count))
                    outputs.append(try exportFile(url, settings: snapshot))
                    progress(Double(i + 1) / Double(files.count))
                }
                return outputs
            }.value
        }
    }
}
