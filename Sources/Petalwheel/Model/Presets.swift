import AppKit
import Combine
import SwiftUI

// MARK: - Codable mirrors

/// Codable mirror of `ConversionOptions`.
struct CodableConversionOptions: Codable, Equatable {
    var quality: String = Quality.high.rawValue
    var preserveMetadata = true
    var videoMaxHeight: Int? = nil
    var audioBitrateKbps = 192
    var gifFrameRate = 15
    var gifMaxWidth = 640

    init() {}

    init(_ o: ConversionOptions) {
        quality = o.quality.rawValue
        preserveMetadata = o.preserveMetadata
        videoMaxHeight = o.videoMaxHeight
        audioBitrateKbps = o.audioBitrateKbps
        gifFrameRate = o.gifFrameRate
        gifMaxWidth = o.gifMaxWidth
    }

    var options: ConversionOptions {
        var o = ConversionOptions()
        o.quality = Quality(rawValue: quality) ?? o.quality
        o.preserveMetadata = preserveMetadata
        o.videoMaxHeight = videoMaxHeight
        o.audioBitrateKbps = audioBitrateKbps
        o.gifFrameRate = gifFrameRate
        o.gifMaxWidth = gifMaxWidth
        return o
    }

    // Tolerant decoding: missing keys fall back to defaults so older files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CodableConversionOptions()
        quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? d.quality
        preserveMetadata = try c.decodeIfPresent(Bool.self, forKey: .preserveMetadata) ?? d.preserveMetadata
        videoMaxHeight = try c.decodeIfPresent(Int.self, forKey: .videoMaxHeight)
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? d.audioBitrateKbps
        gifFrameRate = try c.decodeIfPresent(Int.self, forKey: .gifFrameRate) ?? d.gifFrameRate
        gifMaxWidth = try c.decodeIfPresent(Int.self, forKey: .gifMaxWidth) ?? d.gifMaxWidth
    }
}

/// Codable mirror of `ToolOptions` (which holds an `NSColor` and enums without Codable).
struct CodableToolOptions: Codable, Equatable {
    var videoCompressionMode: String?
    var quality: String
    var targetSizeKB: Int?
    var aspect: String
    var padding: Double
    var cornerRadius: Double
    var shadow: Bool
    /// sRGB components 0...1: r, g, b, a.
    var backgroundRGBA: [Double]
    var collageColumns: Int
    var collageSpacing: Double
    var trimStart: Double
    var trimEnd: Double?
    var speed: Double
    var snapshotCount: Int
    var splitParts: Int
    var mono: Bool
    var silenceThresholdDB: Double
    var loudnessLUFS: Double
    var faceBlurStyle: String
    // archives (the zip password is never stored)
    var archiveFormat: String?
    var archiveLevel: Int?

    init(_ o: ToolOptions = ToolOptions()) {
        videoCompressionMode = o.videoCompressionMode?.rawValue
        quality = o.quality.rawValue
        targetSizeKB = o.targetSizeKB
        aspect = o.aspect.rawValue
        padding = o.padding
        cornerRadius = o.cornerRadius
        shadow = o.shadow
        let c = o.backgroundColor.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1)
        backgroundRGBA = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent)]
        collageColumns = o.collageColumns
        collageSpacing = o.collageSpacing
        trimStart = o.trimStart
        trimEnd = o.trimEnd
        speed = o.speed
        snapshotCount = o.snapshotCount
        splitParts = o.splitParts
        mono = o.mono
        silenceThresholdDB = o.silenceThresholdDB
        loudnessLUFS = o.loudnessLUFS
        faceBlurStyle = o.faceBlurStyle.rawValue
        archiveFormat = o.archiveFormat.rawValue
        archiveLevel = o.archiveLevel
    }

    var options: ToolOptions {
        var o = ToolOptions()
        o.videoCompressionMode = videoCompressionMode.flatMap(VideoCompressionMode.init(rawValue:))
        o.quality = Quality(rawValue: quality) ?? o.quality
        o.targetSizeKB = targetSizeKB
        o.aspect = AspectRatio(rawValue: aspect) ?? o.aspect
        o.padding = padding
        o.cornerRadius = cornerRadius
        o.shadow = shadow
        if backgroundRGBA.count == 4 {
            o.backgroundColor = NSColor(srgbRed: backgroundRGBA[0], green: backgroundRGBA[1],
                                        blue: backgroundRGBA[2], alpha: backgroundRGBA[3])
        }
        o.collageColumns = collageColumns
        o.collageSpacing = collageSpacing
        o.trimStart = trimStart
        o.trimEnd = trimEnd
        o.speed = speed
        o.snapshotCount = snapshotCount
        o.splitParts = splitParts
        o.mono = mono
        o.silenceThresholdDB = silenceThresholdDB
        o.loudnessLUFS = loudnessLUFS
        o.faceBlurStyle = RedactionStyle(rawValue: faceBlurStyle) ?? o.faceBlurStyle
        o.archiveFormat = archiveFormat.flatMap(FileFormat.init(rawValue:)) ?? o.archiveFormat
        o.archiveLevel = archiveLevel ?? o.archiveLevel
        return o
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CodableToolOptions()
        videoCompressionMode = try c.decodeIfPresent(String.self, forKey: .videoCompressionMode)
        quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? d.quality
        targetSizeKB = try c.decodeIfPresent(Int.self, forKey: .targetSizeKB)
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect) ?? d.aspect
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? d.shadow
        backgroundRGBA = try c.decodeIfPresent([Double].self, forKey: .backgroundRGBA) ?? d.backgroundRGBA
        collageColumns = try c.decodeIfPresent(Int.self, forKey: .collageColumns) ?? d.collageColumns
        collageSpacing = try c.decodeIfPresent(Double.self, forKey: .collageSpacing) ?? d.collageSpacing
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? d.trimStart
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        snapshotCount = try c.decodeIfPresent(Int.self, forKey: .snapshotCount) ?? d.snapshotCount
        splitParts = try c.decodeIfPresent(Int.self, forKey: .splitParts) ?? d.splitParts
        mono = try c.decodeIfPresent(Bool.self, forKey: .mono) ?? d.mono
        silenceThresholdDB = try c.decodeIfPresent(Double.self, forKey: .silenceThresholdDB) ?? d.silenceThresholdDB
        loudnessLUFS = try c.decodeIfPresent(Double.self, forKey: .loudnessLUFS) ?? d.loudnessLUFS
        faceBlurStyle = try c.decodeIfPresent(String.self, forKey: .faceBlurStyle) ?? d.faceBlurStyle
        archiveFormat = try c.decodeIfPresent(String.self, forKey: .archiveFormat)
        archiveLevel = try c.decodeIfPresent(Int.self, forKey: .archiveLevel)
    }
}

// MARK: - Preset action

/// What a preset (or a history entry) runs: a conversion target or a non-interactive tool.
/// Stored as plain strings so unknown formats/tools from newer versions don't break decoding.
struct PresetAction: Codable, Hashable {
    enum Kind: String, Codable { case format, tool }
    var kind: Kind
    var raw: String

    static func convert(_ f: FileFormat) -> PresetAction { PresetAction(kind: .format, raw: f.rawValue) }
    static func tool(_ t: FileTool) -> PresetAction { PresetAction(kind: .tool, raw: t.rawValue) }

    var format: FileFormat? { kind == .format ? FileFormat(rawValue: raw) : nil }
    var tool: FileTool? { kind == .tool ? FileTool(rawValue: raw) : nil }
    var isValid: Bool { format != nil || tool != nil }

    var title: String {
        if let f = format { return L("Convert to %@", f.title) }
        if let t = tool { return t.title }
        return raw
    }

    var symbol: String {
        if let t = tool { return t.symbol }
        return "arrow.triangle.2.circlepath"
    }

    /// Tools a preset can run unattended (interactive editors need a window, so they're excluded).
    static var presettableTools: [FileTool] {
        FileTool.allCases.filter { !$0.isInteractive && !FolderCatalog.folderOnlyTools.contains($0) }
    }
}

// MARK: - Preset

/// A user recipe: name + action + an options snapshot. Runs without the options panel.
struct UserPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var action: PresetAction
    var conversion = CodableConversionOptions()
    var tool = CodableToolOptions()
    /// Conversions only: downmix the result to mono (audio targets).
    var downmixToMono = false
    /// Optional SF Symbol for the petal; defaults to the action's symbol.
    var symbolName: String? = nil
    /// Optional restriction to input groups (FormatGroup raw values), e.g. ["images"]. nil = any input the action accepts.
    var onlyFor: [String]? = nil

    var symbol: String { symbolName ?? (downmixToMono ? "mic" : (action.kind == .format ? "star" : action.symbol)) }

    /// Short description, e.g. "Compress · 2 MB" or "Convert to MP3 · mono · 64 kbps".
    var summary: String {
        var parts = [action.title]
        if let t = action.tool {
            let o = tool.options
            switch t {
            case .compress:
                if let mode = o.videoCompressionMode {
                    parts.append(mode.title)
                } else if let kb = o.targetSizeKB {
                    parts.append(kb >= 1024 && kb % 1024 == 0 ? "≤ \(kb / 1024) MB" : "≤ \(kb) KB")
                } else { parts.append(o.quality.title) }
            case .cropImage, .cropVideo: parts.append(o.aspect.rawValue)
            case .changeVideoSpeed: parts.append(String(format: "%g×", o.speed))
            case .audioChannels: parts.append(o.mono ? L("mono") : L("stereo"))
            case .normalizeAudio: parts.append("\(Int(o.loudnessLUFS)) LUFS")
            case .videoSnapshots: parts.append(Lp("%d frames", o.snapshotCount))
            case .splitVideo: parts.append(Lp("%d parts", o.splitParts))
            case .frameImage: parts.append(L("padding %d", Int(o.padding)))
            case .blurFaces: parts.append(o.faceBlurStyle.title.lowercased())
            case .trimSilence: parts.append("\(Int(o.silenceThresholdDB)) dB")
            default: break
            }
        } else if let f = action.format {
            let o = conversion.options
            if downmixToMono { parts.append(L("mono")) }
            if f.group == .audio || f.group == .video { parts.append("\(o.audioBitrateKbps) kbps") }
            parts.append(o.quality.title)
        }
        return parts.joined(separator: " · ")
    }

    /// Whether this preset can run on every one of `urls`.
    func applies(to urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        if let groups = onlyFor, !groups.isEmpty {
            let ok = urls.allSatisfy { url in FileFormat.detect(url).map { groups.contains($0.group.rawValue) } ?? false }
            guard ok else { return false }
        }
        if let f = action.format {
            guard ConversionCatalog.commonOutputs(for: urls).contains(f) else { return false }
            if downmixToMono { return f.group == .audio && ExternalTools.shared.hasFFmpeg }
            return true
        }
        if let t = action.tool {
            return !t.isInteractive && FileTool.available(for: urls).contains(t)
        }
        return false
    }

    // Tolerant decoding.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        action = try c.decode(PresetAction.self, forKey: .action)
        conversion = try c.decodeIfPresent(CodableConversionOptions.self, forKey: .conversion) ?? CodableConversionOptions()
        tool = try c.decodeIfPresent(CodableToolOptions.self, forKey: .tool) ?? CodableToolOptions()
        downmixToMono = try c.decodeIfPresent(Bool.self, forKey: .downmixToMono) ?? false
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName)
        onlyFor = try c.decodeIfPresent([String].self, forKey: .onlyFor)
    }

    init(id: UUID = UUID(), name: String, action: PresetAction,
         conversion: ConversionOptions = ConversionOptions(), tool: ToolOptions = ToolOptions(),
         downmixToMono: Bool = false, symbolName: String? = nil, onlyFor: [FormatGroup]? = nil) {
        self.id = id
        self.name = name
        self.action = action
        self.conversion = CodableConversionOptions(conversion)
        self.tool = CodableToolOptions(tool)
        self.downmixToMono = downmixToMono
        self.symbolName = symbolName
        self.onlyFor = onlyFor?.map(\.rawValue)
    }

    /// Built-in starter recipes, written on first launch.
    static var seeds: [UserPreset] {
        var email = ToolOptions()
        email.targetSizeKB = 2048
        var insta = ToolOptions()
        insta.aspect = .fourFive
        var voice = ConversionOptions()
        voice.quality = .compact
        voice.audioBitrateKbps = 64
        return [
            UserPreset(name: L("Email (≤2 MB JPG)"), action: .tool(.compress), tool: email, symbolName: "envelope",
                       onlyFor: [.images]),
            UserPreset(name: "Instagram 4:5", action: .tool(.cropImage), tool: insta, symbolName: "camera.aperture",
                       onlyFor: [.images]),
            UserPreset(name: L("Voice memo → MP3 mono"), action: .convert(.mp3), conversion: voice,
                       downmixToMono: true, symbolName: "mic", onlyFor: [.audio]),
        ]
    }
}

// MARK: - Store

/// Shared Application Support folder (`~/Library/Application Support/Petalwheel`).
enum KQSupportDirectory {
    /// Overridable for tests (harness points it at a scratch folder).
    static var overrideURL: URL?

    static var url: URL {
        if let overrideURL { return overrideURL }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Petalwheel", isDirectory: true)
    }

    static func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    static func writeJSON<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .deferredToDate
        try enc.encode(value).write(to: file(name), options: .atomic)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .deferredToDate
        return try? dec.decode(type, from: data)
    }
}

/// User presets persisted in Application Support/Petalwheel/presets.json.
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    static let fileName = "presets.json"

    @Published private(set) var presets: [UserPreset] = []

    private struct FileFormatV1: Codable {
        var version = 1
        var presets: [UserPreset]
    }

    init() { reload() }

    /// Loads from disk; seeds the starter recipes when no file exists yet.
    func reload() {
        let path = KQSupportDirectory.file(Self.fileName).path
        if !FileManager.default.fileExists(atPath: path) {
            presets = UserPreset.seeds
            save()
            return
        }
        presets = (KQSupportDirectory.readJSON(FileFormatV1.self, from: Self.fileName)?.presets ?? [])
            .filter { $0.action.isValid }
    }

    func save() {
        do {
            try KQSupportDirectory.writeJSON(FileFormatV1(presets: presets), to: Self.fileName)
        } catch {
            NSLog("Petalwheel: couldn't save presets: \(error.localizedDescription)")
        }
    }

    func preset(_ id: UUID) -> UserPreset? { presets.first { $0.id == id } }

    func applicable(to urls: [URL]) -> [UserPreset] { presets.filter { $0.applies(to: urls) } }

    func upsert(_ preset: UserPreset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[i] = preset
        } else {
            presets.append(preset)
        }
        save()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func restoreDefaults() {
        let existing = Set(presets.map(\.name))
        presets += UserPreset.seeds.filter { !existing.contains($0.name) }
        save()
    }
}
