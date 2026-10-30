import Foundation
import AppKit

// Shared contracts between modules. Change only with the coordinator's agreement.

/// Progress callback: fraction 0...1 for the current file. May be called from any thread.
typealias ProgressHandler = @Sendable (Double) -> Void

enum Quality: String, CaseIterable, Identifiable {
    case compact, balanced, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return L("Compact")
        case .balanced: return L("Balanced")
        case .high: return L("High")
        }
    }
}

/// Options applied to plain format conversions.
struct ConversionOptions {
    var quality: Quality = .high
    var preserveMetadata = true
    var videoMaxHeight: Int? = nil     // nil = keep source
    var audioBitrateKbps = 192
    var gifFrameRate = 15
    var gifMaxWidth = 640
}

/// Every converter engine implements this. Returns the files it created (may be several,
/// e.g. one PNG per PDF page). Outputs go next to the source via `OutputNaming`.
protocol ConversionEngine {
    func canConvert(from source: FileFormat, to target: FileFormat) -> Bool
    func convert(_ source: URL, from: FileFormat, to target: FileFormat,
                 options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> [URL]
}

enum OutputNaming {
    /// `photo.heic` + ext "jpg" → `photo.jpg` (or `photo 2.jpg` if taken).
    /// With suffix "compressed" → `photo (compressed).jpg`.
    static func url(for source: URL, ext: String, suffix: String? = nil, directory: URL? = nil) -> URL {
        let dir = directory ?? source.deletingLastPathComponent()
        var base = source.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        if let suffix { base += " (\(suffix))" }
        return unique(dir.appendingPathComponent(base).appendingPathExtension(ext))
    }

    /// Output with an explicit base name inside a directory.
    static func url(named base: String, ext: String, in dir: URL) -> URL {
        unique(dir.appendingPathComponent(base).appendingPathExtension(ext))
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    /// Fresh temporary directory, caller removes it.
    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("petalwheel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Tools

enum FileTool: String, CaseIterable, Identifiable {
    // images
    case compress, removeMetadata, cropImage, frameImage, removeBackground, blurFaces,
         readQRCode, recognizeText, createCollage, createPDF
    // pdf
    case mergePDF, splitPDF
    // video
    case trimMedia, muteVideo, changeVideoSpeed, cropVideo, joinVideos, videoSnapshots, splitVideo
    // audio
    case normalizeAudio, audioChannels, trimSilence, audioToVideo
    // archives
    case extractArchive, createArchive, listArchive, testArchive, compressSingle
    // interactive editors
    case annotateImage, adjustImage, redactImage, organizePDF, redactVideo, bleepAudio
    // folders (contents of dropped folders, see FolderCatalog)
    case flattenFolder, folderReport

    var id: String { rawValue }
}

// MARK: - Interactive editors

/// The export an editor hands back after the user presses Save. The coordinator runs it with the progress HUD.
typealias EditorExport = (@escaping ProgressHandler) async throws -> [URL]
/// Called exactly once: with the export on Save, nil on Cancel / window close.
typealias EditorCompletion = (EditorExport?) -> Void

/// All tool parameters in one bag. Each tool reads what it needs.
enum VideoCompressionMode: String, CaseIterable, Identifiable, Codable {
    case fast, quality
    var id: String { rawValue }
    var title: String { self == .fast ? "Тез сығу" : "Сапаға басымдық" }
    var explanation: String {
        self == .fast
            ? "Mac аппараттық HEVC кодтауы. Жылдам нәтиже."
            : "HEVC бағдарламалық кодтауы. Баяуырақ, сапа мен көлемге басымдық."
    }
}

struct ToolOptions {
    // nil preserves legacy presets and non-video compression behaviour.
    var videoCompressionMode: VideoCompressionMode? = nil
    var quality: Quality = .balanced
    /// Compress to target size in KB (nil = use quality preset).
    var targetSizeKB: Int? = nil
    var aspect: AspectRatio = .square
    var padding: Double = 64
    var cornerRadius: Double = 24
    var shadow = true
    var backgroundColor: NSColor = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.1, alpha: 1)
    var collageColumns = 3
    var collageSpacing: Double = 12
    var trimStart: Double = 0          // seconds
    var trimEnd: Double? = nil         // seconds, nil = until end
    var speed: Double = 2.0
    var snapshotCount = 6
    var splitParts = 2
    var mono = true                    // audioChannels: true = mono, false = stereo
    var silenceThresholdDB: Double = -45
    var loudnessLUFS: Double = -16
    var faceBlurStyle: RedactionStyle = .blur
    // archives: createArchive / compressSingle target, zip/7z level 1...9, zip password (never logged or stored)
    var archiveFormat: FileFormat = .zip
    var archiveLevel = 6
    var archivePassword: String? = nil
}

enum AspectRatio: String, CaseIterable, Identifiable {
    case square = "1:1", fourThree = "4:3", threeTwo = "3:2", sixteenNine = "16:9", nineSixteen = "9:16", threeFour = "3:4", fourFive = "4:5"
    var id: String { rawValue }
    var value: Double {
        switch self {
        case .square: return 1
        case .fourThree: return 4.0 / 3
        case .threeTwo: return 3.0 / 2
        case .sixteenNine: return 16.0 / 9
        case .nineSixteen: return 9.0 / 16
        case .threeFour: return 3.0 / 4
        case .fourFive: return 4.0 / 5
        }
    }
}

enum RedactionStyle: String, CaseIterable, Identifiable {
    case blur, pixelate, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blur: return L("Blur")
        case .pixelate: return L("Pixelate")
        case .solid: return L("Solid")
        }
    }
}

/// What a tool produced.
struct ToolResult {
    var outputs: [URL] = []
    /// Text payload to show the user (QR codes found, etc.).
    var messages: [String] = []
}

/// A tool implementation module. `ToolRegistry` dispatches each FileTool to the module that handles it.
protocol ToolModule {
    /// Whether this module handles `tool` for inputs of `format` (nil = folder / unknown type).
    func canRun(_ tool: FileTool, format: FileFormat?) -> Bool
    func run(_ tool: FileTool, inputs: [URL], options: ToolOptions,
             progress: @escaping ProgressHandler) async throws -> ToolResult
}

// MARK: - Actions

enum FileAction: String, CaseIterable, Identifiable {
    case float, airDrop, copy, copyPath, move, openTerminal
    var id: String { rawValue }
}

// MARK: - Fan

enum FanMode: String, CaseIterable {
    /// Top level of the single wheel: category petals.
    case categories
    case conversions, tools, actions
}

/// Top-level petals of the wheel. Hovering one while dragging opens its items.
enum FanCategory: String, CaseIterable {
    case convert, optimize, edit, combine, extract, share
    /// User presets ("my recipes"); shown only when a preset applies.
    case favorites
}

/// A petal in the radial fan.
struct FanItem: Identifiable, Equatable {
    enum Kind: Equatable { case format(FileFormat), tool(FileTool), action(FileAction), category(FanCategory), preset(UUID) }
    let kind: Kind
    let title: String
    let symbol: String?     // SF Symbol name; nil → title only (formats)
    var id: String {
        switch kind {
        case .format(let f): return "format.\(f.rawValue)"
        case .tool(let t): return "tool.\(t.rawValue)"
        case .action(let a): return "action.\(a.rawValue)"
        case .category(let c): return "category.\(c.rawValue)"
        case .preset(let p): return "preset.\(p.uuidString)"
        }
    }
}
