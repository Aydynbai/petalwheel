import Foundation

struct ProcessError: LocalizedError {
    let tool: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
        return "\(tool) failed (exit \(status)).\n\(tail)"
    }
}

struct NurToError: LocalizedError {
    /// English text: used for logs, the HUD's "Details" and ErrorTranslator's pattern matching.
    let message: String
    /// What people see (the localized message).
    let localizedMessage: String
    init(_ message: String) { self.message = message; self.localizedMessage = message }
    /// Localized error: `key` is the English format string, filled with `args` in both languages.
    init(l key: String, _ args: CVarArg...) {
        self.message = String(format: key, arguments: args)
        self.localizedMessage = String(format: L(key), locale: Locale.current, arguments: args)
    }
    var errorDescription: String? { localizedMessage }
}

/// Locates helper executables: bundled copies first, then Homebrew / system paths.
final class ExternalTools {
    static let shared = ExternalTools()

    let ffmpeg: URL?
    let ffprobe: URL?
    let cwebp: URL?

    private init() {
        ffmpeg = Self.find("ffmpeg")
        ffprobe = Self.find("ffprobe")
        cwebp = Self.find("cwebp")
    }

    var hasFFmpeg: Bool { ffmpeg != nil && ffprobe != nil }
    var hasWebPEncoder: Bool { cwebp != nil }

    static func find(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Tools/\(name)"))
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func require(_ url: URL?, _ name: String) throws -> URL {
        guard let url else {
            throw NurToError(l: "%@ is not installed. Install it with: brew install %@", name, name == "cwebp" ? "webp" : "ffmpeg")
        }
        return url
    }
}

enum ProcessRunner {
    /// Runs a process to completion. `onStdoutLine` receives stdout line by line (used for ffmpeg -progress).
    @discardableResult
    static func run(_ executable: URL,
                    _ arguments: [String],
                    currentDirectory: URL? = nil,
                    onStdoutLine: ((String) -> Void)? = nil) async throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onLine: onStdoutLine)
        outPipe.fileHandleForReading.readabilityHandler = { h in collector.appendOut(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in collector.appendErr(h.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(stdout: String, stderr: String), Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    let (out, err) = collector.result()
                    if p.terminationStatus == 0 {
                        cont.resume(returning: (out, err))
                    } else if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(throwing: ProcessError(tool: executable.lastPathComponent, status: p.terminationStatus, stderr: err))
                    }
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data(), pending = Data()
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock()
        out.append(d)
        var lines: [String] = []
        if onLine != nil {
            pending.append(d)
            while let nl = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func appendErr(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); err.append(d); lock.unlock()
    }

    func result() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
