import Foundation

extension FileTool {
    var title: String {
        switch self {
        case .compress: return L("Compress")
        case .removeMetadata: return L("Strip Metadata")
        case .cropImage: return L("Crop")
        case .frameImage: return L("Frame")
        case .removeBackground: return L("Remove BG")
        case .blurFaces: return L("Blur Faces")
        case .readQRCode: return L("Read QR")
        case .recognizeText: return L("Extract Text")
        case .createCollage: return L("Collage")
        case .createPDF: return L("Make PDF")
        case .mergePDF: return L("Merge PDF")
        case .splitPDF: return L("Split PDF")
        case .trimMedia: return L("Trim")
        case .muteVideo: return L("Mute")
        case .changeVideoSpeed: return L("Speed")
        case .cropVideo: return L("Crop Video")
        case .joinVideos: return L("Join")
        case .videoSnapshots: return L("Snapshots")
        case .splitVideo: return L("Split")
        case .normalizeAudio: return L("Normalize")
        case .audioChannels: return L("Channels")
        case .trimSilence: return L("Cut Silence")
        case .audioToVideo: return L("Visualize")
        case .extractArchive: return L("Extract")
        case .createArchive: return L("Zip")
        case .annotateImage: return L("Annotate")
        case .adjustImage: return L("Adjust")
        case .redactImage: return L("Redact")
        case .organizePDF: return L("Organize PDF")
        case .redactVideo: return L("Redact Video")
        case .bleepAudio: return L("Bleep")
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: return "eye.slash"
        case .cropImage, .cropVideo: return "crop"
        case .frameImage: return "photo.artframe"
        case .removeBackground: return "person.crop.rectangle"
        case .blurFaces: return "face.dashed"
        case .readQRCode: return "qrcode.viewfinder"
        case .recognizeText: return "text.viewfinder"
        case .createCollage: return "square.grid.2x2"
        case .createPDF: return "doc.richtext"
        case .mergePDF: return "doc.on.doc"
        case .splitPDF: return "scissors"
        case .trimMedia: return "timeline.selection"
        case .muteVideo: return "speaker.slash"
        case .changeVideoSpeed: return "gauge.with.dots.needle.67percent"
        case .joinVideos: return "film.stack"
        case .videoSnapshots: return "camera"
        case .splitVideo: return "rectangle.split.3x1"
        case .normalizeAudio: return "waveform.badge.plus"
        case .audioChannels: return "speaker.wave.2"
        case .trimSilence: return "waveform.badge.minus"
        case .audioToVideo: return "waveform"
        case .extractArchive: return "archivebox"
        case .createArchive: return "doc.zipper"
        case .annotateImage: return "pencil.tip.crop.circle"
        case .adjustImage: return "camera.filters"
        case .redactImage, .redactVideo: return "eye.slash.circle"
        case .organizePDF: return "rectangle.grid.2x2"
        case .bleepAudio: return "speaker.wave.2.bubble"
        }
    }

    /// Tools that open an interactive editor window instead of an options panel.
    var isInteractive: Bool {
        switch self {
        case .annotateImage, .adjustImage, .redactImage, .organizePDF, .redactVideo, .bleepAudio, .trimMedia:
            return true
        default:
            return false
        }
    }

    /// Tools that show an options panel before running.
    var needsOptions: Bool {
        switch self {
        case .compress, .cropImage, .frameImage, .blurFaces, .createCollage,
             .changeVideoSpeed, .cropVideo, .videoSnapshots, .splitVideo, .normalizeAudio,
             .audioChannels, .trimSilence:
            return true
        default:
            return false
        }
    }

    /// Minimum number of files the tool needs.
    var minimumInputs: Int {
        switch self {
        case .createCollage, .mergePDF, .joinVideos: return 2
        default: return 1
        }
    }

    func accepts(_ format: FileFormat) -> Bool {
        let g = format.group
        let ffmpeg = ExternalTools.shared.hasFFmpeg
        let rasterImage = format.isRasterImage
        let movie = g == .video && format != .gif
        switch self {
        case .compress: return rasterImage || format == .pdf || ((g == .video || g == .audio) && ffmpeg)
        case .removeMetadata: return rasterImage || format == .pdf || ((g == .video || g == .audio) && ffmpeg)
        case .cropImage, .frameImage, .removeBackground, .blurFaces, .createCollage: return rasterImage
        case .readQRCode, .recognizeText: return rasterImage || format == .pdf
        case .createPDF: return rasterImage
        case .mergePDF, .splitPDF: return format == .pdf
        case .trimMedia: return (g == .video || g == .audio) && ffmpeg
        case .muteVideo, .changeVideoSpeed, .cropVideo, .joinVideos, .videoSnapshots, .splitVideo: return movie && ffmpeg
        case .normalizeAudio, .audioChannels, .trimSilence: return (g == .audio || movie) && ffmpeg
        case .audioToVideo: return g == .audio && ffmpeg
        case .extractArchive: return g == .archives
        case .createArchive: return true
        case .annotateImage, .adjustImage, .redactImage: return rasterImage
        case .organizePDF: return format == .pdf
        case .redactVideo: return movie && ffmpeg
        case .bleepAudio: return (g == .audio || movie) && ffmpeg
        }
    }

    /// Tools valid for every URL in the selection (folders only get createArchive).
    static func available(for urls: [URL]) -> [FileTool] {
        let formats = urls.map(FileFormat.detect)
        return allCases.filter { tool in
            guard urls.count >= tool.minimumInputs else { return false }
            if tool == .createArchive { return true }
            return formats.allSatisfy { f in f.map(tool.accepts) ?? false }
        }
    }
}

extension FileAction {
    var title: String {
        switch self {
        case .float: return L("Float")
        case .airDrop: return L("AirDrop")
        case .copy: return L("Copy")
        case .copyPath: return L("Copy Path")
        case .move: return L("Move To…")
        case .openTerminal: return L("Terminal")
        }
    }

    var symbol: String {
        switch self {
        case .float: return "tray.and.arrow.down"
        case .airDrop: return "airplayaudio"
        case .copy: return "doc.on.clipboard"
        case .copyPath: return "link"
        case .move: return "folder"
        case .openTerminal: return "terminal"
        }
    }
}

extension FanCategory {
    var title: String {
        switch self {
        case .convert: return L("Convert")
        case .optimize: return L("Optimize")
        case .edit: return L("Edit")
        case .combine: return L("Combine & Split")
        case .extract: return L("Extract")
        case .share: return L("Share & Files")
        case .favorites: return L("Presets")
        }
    }

    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .optimize: return "arrow.down.right.and.arrow.up.left"
        case .edit: return "slider.horizontal.3"
        case .combine: return "square.on.square"
        case .extract: return "text.viewfinder"
        case .share: return "square.and.arrow.up"
        case .favorites: return "star"
        }
    }

    /// Tools belonging to each category, in display order.
    var tools: [FileTool] {
        switch self {
        case .convert, .share, .favorites: return []
        case .optimize: return [.compress, .removeMetadata, .normalizeAudio, .trimSilence]
        case .edit: return [.annotateImage, .adjustImage, .cropImage, .frameImage, .removeBackground, .redactImage,
                            .blurFaces, .trimMedia, .redactVideo, .bleepAudio, .changeVideoSpeed, .cropVideo,
                            .muteVideo, .audioChannels, .organizePDF]
        case .combine: return [.createCollage, .createPDF, .mergePDF, .splitPDF, .joinVideos,
                               .splitVideo, .audioToVideo, .createArchive]
        case .extract: return [.readQRCode, .recognizeText, .videoSnapshots, .extractArchive]
        }
    }
}

enum FanCatalog {
    /// Category petals that have at least one item for these files.
    static func categories(for urls: [URL]) -> [FanItem] {
        FanCategory.allCases.filter { !items(in: $0, urls: urls).isEmpty }.map {
            FanItem(kind: .category($0), title: $0.title, symbol: $0.symbol)
        }
    }

    static func items(in category: FanCategory, urls: [URL]) -> [FanItem] {
        switch category {
        case .convert: return items(for: .conversions, urls: urls)
        case .share: return items(for: .actions, urls: urls)
        case .favorites:
            return PresetStore.shared.applicable(to: urls).map {
                FanItem(kind: .preset($0.id), title: $0.name, symbol: $0.symbol)
            }
        default:
            let available = Set(FileTool.available(for: urls))
            return category.tools.filter(available.contains).map {
                FanItem(kind: .tool($0), title: $0.title, symbol: $0.symbol)
            }
        }
    }

    static func items(for mode: FanMode, urls: [URL]) -> [FanItem] {
        switch mode {
        case .conversions:
            return ConversionCatalog.commonOutputs(for: urls).map {
                FanItem(kind: .format($0), title: $0.title, symbol: nil)
            }
        case .tools:
            return FileTool.available(for: urls).map {
                FanItem(kind: .tool($0), title: $0.title, symbol: $0.symbol)
            }
        case .actions:
            return FileAction.allCases.map {
                FanItem(kind: .action($0), title: $0.title, symbol: $0.symbol)
            }
        case .categories:
            return categories(for: urls)
        }
    }
}
