import Foundation

/// A short, human message for a failure plus the technical detail behind it.
struct FriendlyError: Equatable {
    enum Kind: String {
        case cancelled, noAudio, noVideo, damaged, diskFull, permission, passwordProtected,
             unsupportedCodec, missingFile, missingTool, generic
    }
    let kind: Kind
    /// One line, shown in the HUD.
    let message: String
    /// Raw error text (ffmpeg stderr, NSError domain/code…), shown behind "Details".
    let detail: String
}

/// User-facing error strings, looked up by stable key in {en,ru}.lproj/Errors.strings.
enum ErrorStrings {
    private static func t(_ key: String, _ english: String) -> String {
        L10n.bundle.localizedString(forKey: key, value: english, table: "Errors")
    }

    static var cancelled: String { t("error.cancelled", "Cancelled") }
    static var noAudio: String { t("error.noAudio", "This file has no audio track") }
    static var noVideo: String { t("error.noVideo", "This file has no video track") }
    static func damaged(_ format: String?) -> String {
        if let format {
            return String(format: t("error.damaged.format", "The file is damaged or not a valid %@"), format)
        }
        return t("error.damaged", "The file is damaged or isn't a supported type")
    }
    static var diskFull: String { t("error.diskFull", "Not enough disk space") }
    static func permission(_ folder: String) -> String {
        String(format: t("error.permission.folder", "Permission denied: can't write to %@"), folder)
    }
    static var permissionRead: String { t("error.permission.read", "Permission denied: can't read this file") }
    static var passwordProtected: String { t("error.passwordProtected", "Password-protected PDF") }
    static func unsupportedCodec(_ codec: String) -> String {
        String(format: t("error.unsupportedCodec", "Unsupported codec %@"), codec)
    }
    static var unsupportedCodecUnknown: String { t("error.unsupportedCodec.unknown", "Unsupported codec") }
    static var missingFile: String { t("error.missingFile", "The file no longer exists") }
    static func missingTool(_ name: String) -> String {
        String(format: t("error.missingTool", "%@ isn't installed"), name)
    }
    static func toolFailed(_ tool: String) -> String {
        String(format: t("error.toolFailed", "%@ couldn't process this file"), tool)
    }
    static var details: String { t("hud.details", "Details") }
    static var copy: String { t("hud.copy", "Copy") }
}

/// Maps raw errors (ProcessError with ffmpeg stderr, NSError from ImageIO/PDFKit/Foundation, KumquatError)
/// to short human messages.
enum ErrorTranslator {
    /// - Parameters:
    ///   - file: the input the error happened on (used for the format name and the default output folder).
    ///   - outputDirectory: where results were being written (defaults to the input's folder).
    static func translate(_ error: Error, file: URL? = nil, outputDirectory: URL? = nil) -> FriendlyError {
        let detail = technicalDetail(error)
        let text = detail.lowercased()
        let format = file.flatMap(FileFormat.detect)?.title
        let outDir = outputDirectory ?? file?.deletingLastPathComponent()

        func make(_ kind: FriendlyError.Kind, _ message: String) -> FriendlyError {
            FriendlyError(kind: kind, message: message, detail: detail)
        }

        // Cancellation
        if error is CancellationError || (error as NSError).code == NSUserCancelledError && (error as NSError).domain == NSCocoaErrorDomain {
            return make(.cancelled, ErrorStrings.cancelled)
        }

        // Structured NSError codes first: they are unambiguous.
        for ns in nsErrorChain(error) {
            if ns.domain == NSCocoaErrorDomain {
                switch ns.code {
                case NSFileWriteOutOfSpaceError: return make(.diskFull, ErrorStrings.diskFull)
                case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                    return make(.permission, ErrorStrings.permission(folderName(writeTarget(ns) ?? outDir)))
                case NSFileReadNoPermissionError: return make(.permission, ErrorStrings.permissionRead)
                case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return make(.missingFile, ErrorStrings.missingFile)
                case NSFileReadCorruptFileError, NSFileReadUnknownError, NSPropertyListReadCorruptError:
                    return make(.damaged, ErrorStrings.damaged(format))
                default: break
                }
            }
            if ns.domain == NSPOSIXErrorDomain {
                switch Int32(ns.code) {
                case ENOSPC, EDQUOT: return make(.diskFull, ErrorStrings.diskFull)
                case EACCES, EPERM, EROFS: return make(.permission, ErrorStrings.permission(folderName(writeTarget(ns) ?? outDir)))
                case ENOENT: return make(.missingFile, ErrorStrings.missingFile)
                default: break
                }
            }
        }

        // Text patterns (ffmpeg stderr, KumquatError messages, NSError descriptions).
        if text.contains("no space left on device") || text.contains("disk full") || text.contains("not enough space")
            || text.contains("out of space") {
            return make(.diskFull, ErrorStrings.diskFull)
        }
        if text.contains("password-protected") || text.contains("password protected") || text.contains("is encrypted") {
            return make(.passwordProtected, ErrorStrings.passwordProtected)
        }
        if text.contains("has no audio") || text.contains("no audio track") || text.contains("does not contain any stream")
            || text.contains("matches no streams") && text.contains(":a") || text.contains("output file does not contain any stream")
            || (text.contains("stream map") && text.contains("0:a")) {
            return make(.noAudio, ErrorStrings.noAudio)
        }
        if text.contains("has no video track") || text.contains("no video track") {
            return make(.noVideo, ErrorStrings.noVideo)
        }
        if let codec = unsupportedCodec(in: detail) {
            return make(.unsupportedCodec, codec.isEmpty ? ErrorStrings.unsupportedCodecUnknown : ErrorStrings.unsupportedCodec(codec))
        }
        if text.contains("permission denied") || text.contains("operation not permitted") || text.contains("read-only file system") {
            return make(.permission, ErrorStrings.permission(folderName(outDir)))
        }
        if text.contains("no longer exists") || text.contains("no such file or directory") {
            return make(.missingFile, ErrorStrings.missingFile)
        }
        if text.contains("is not installed") {
            let tool = ["ffmpeg", "ffprobe", "cwebp"].first { text.contains($0) } ?? L("A helper")
            return make(.missingTool, ErrorStrings.missingTool(tool))
        }

        // A write that failed in a folder we can't write to.
        let writeish = text.contains("could not write") || text.contains("couldn't create") || text.contains("could not create")
            || text.contains("couldn’t be saved") || text.contains("couldn't be saved") || text.contains("finalize")
        if let outDir, !FileManager.default.isWritableFile(atPath: outDir.path), writeish || isGenericFailure(error) {
            return make(.permission, ErrorStrings.permission(folderName(outDir)))
        }

        let damagedPatterns = ["invalid data found", "moov atom not found", "could not read", "could not decode",
                               "could not open", "couldn't open", "couldn’t open", "can’t be read", "can't be read",
                               "isn't a valid", "is not a valid", "invalid argument", "end of file", "truncated",
                               "corrupt", "error while decoding", "header missing", "not a pdf", "isn't a supported archive",
                               "couldn't unzip", "isn’t in the correct format", "isn't in the correct format",
                               "failed to read", "unknown format", "no pages"]
        if damagedPatterns.contains(where: text.contains) {
            return make(.damaged, ErrorStrings.damaged(format))
        }

        // Fallbacks: keep messages already written for people, shorten tool dumps.
        if let p = error as? ProcessError {
            return make(.generic, ErrorStrings.toolFailed(p.tool))
        }
        let firstLine = (error.localizedDescription.split(separator: "\n").first.map(String.init) ?? error.localizedDescription)
        return make(.generic, shorten(firstLine))
    }

    /// Full technical text: ProcessError stderr, NSError domain/code chain, KumquatError message.
    static func technicalDetail(_ error: Error) -> String {
        if let p = error as? ProcessError {
            let err = p.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = err.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
            return "\(p.tool) exited with status \(p.status)\n\(tail)"
        }
        if let k = error as? KumquatError { return k.message }
        if error is CancellationError { return "CancellationError" }
        var lines: [String] = []
        for ns in nsErrorChain(error) {
            var line = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            if let reason = ns.localizedFailureReason { line += " (\(reason))" }
            if let path = ns.userInfo[NSFilePathErrorKey] as? String { line += " [\(path)]" }
            lines.append(line)
        }
        return lines.isEmpty ? String(describing: error) : lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func nsErrorChain(_ error: Error) -> [NSError] {
        if error is ProcessError || error is KumquatError || error is CancellationError { return [] }
        var chain: [NSError] = []
        var current: NSError? = error as NSError
        while let e = current, chain.count < 6 {
            chain.append(e)
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    private static func writeTarget(_ ns: NSError) -> URL? {
        if let url = ns.userInfo[NSURLErrorKey] as? URL { return url.hasDirectoryPath ? url : url.deletingLastPathComponent() }
        if let path = ns.userInfo[NSFilePathErrorKey] as? String {
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return nil
    }

    private static func folderName(_ url: URL?) -> String {
        guard let url else { return L("this folder") }
        let name = FileManager.default.displayName(atPath: url.path)
        return "“\(name)”"
    }

    private static func isGenericFailure(_ error: Error) -> Bool {
        error is ProcessError || (error as NSError).domain != NSCocoaErrorDomain
    }

    /// Finds the codec name in typical ffmpeg messages. Returns "" when a codec problem is detected without a name.
    static func unsupportedCodec(in text: String) -> String? {
        let patterns = [
            #"Decoder \(codec ([\w\-]+)\) not found"#,
            #"Encoder \(codec ([\w\-]+)\) not found"#,
            #"Unknown (?:de|en)coder '([\w\-]+)'"#,
            #"Could not find tag for codec ([\w\-]+) in stream"#,
            #"codec ([\w\-]+) is not supported"#,
            #"Unsupported codec (?:with id \d+ )?(?:for (?:input|output) stream \d+)?\s*'?([\w\-]*)"#,
            #"No decoder for codec ([\w\-]+)"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let m = re.firstMatch(in: text, range: range) {
                if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) { return String(text[r]) }
                return ""
            }
        }
        if text.lowercased().contains("codec not currently supported in container") { return "" }
        return nil
    }

    private static func shorten(_ s: String, limit: Int = 140) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }
}
