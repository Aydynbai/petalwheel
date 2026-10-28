import Foundation

/// Process runner for the archive tools. Unlike `ProcessRunner` it can set the environment, feed stdin
/// from files (multi-volume archives) or bytes (hdiutil -stdinpass), send stdout straight to a file and
/// report stderr chunks as they arrive (bsdtar -v progress). Arguments are never logged: they may hold a password.
enum ArchiveProcess {
    enum Input {
        case none
        case files([URL])
        case data(Data)
    }

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String],
                    environment: [String: String]? = nil,
                    input: Input = .none,
                    stdoutTo: FileHandle? = nil,
                    onStderr: (@Sendable (Data) -> Void)? = nil) async throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = stdoutTo ?? outPipe
        process.standardError = errPipe
        var inPipe: Pipe?
        switch input {
        case .none: process.standardInput = FileHandle.nullDevice
        case .files, .data:
            let p = Pipe()
            // A reader that exits early must not kill Petalwheel with SIGPIPE.
            _ = fcntl(p.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = p
            inPipe = p
        }

        let collector = ArchiveOutputCollector()
        if stdoutTo == nil {
            outPipe.fileHandleForReading.readabilityHandler = { h in collector.appendOut(h.availableData) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            collector.appendErr(d)
            if !d.isEmpty { onStderr?(d) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(stdout: String, stderr: String), Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if stdoutTo == nil { collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile()) }
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
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                if let inPipe { feed(inPipe.fileHandleForWriting, input) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Writes stdin on a background thread and closes it when done (or when the reader goes away).
    private static func feed(_ handle: FileHandle, _ input: Input) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? handle.close() }
            switch input {
            case .none: break
            case .data(let d): try? handle.write(contentsOf: d)
            case .files(let urls):
                for url in urls {
                    guard let r = try? FileHandle(forReadingFrom: url) else { return }
                    defer { try? r.close() }
                    while true {
                        guard let chunk = try? r.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                        do { try handle.write(contentsOf: chunk) } catch { return }
                    }
                }
            }
        }
    }
}

private final class ArchiveOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()

    func appendOut(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); out.append(d); lock.unlock()
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

/// Counts newline-terminated lines across stderr chunks (bsdtar -v prints one line per entry).
final class ArchiveLineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let onChange: (Int) -> Void

    init(onChange: @escaping (Int) -> Void) { self.onChange = onChange }

    func consume(_ d: Data) {
        let n = d.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        guard n > 0 else { return }
        lock.lock(); count += n; let c = count; lock.unlock()
        onChange(c)
    }
}
