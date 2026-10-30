import Foundation

/// Multi-volume archives: `name.part1.rar…`, `name.rar + name.r00…`, `name.z01… + name.zip`,
/// `name.7z.001…` / `name.zip.001…`.
struct ArchiveVolumeSet {
    enum Kind {
        /// One file, read directly.
        case single
        /// RAR volumes and split zips: concatenated into bsdtar's stdin (libarchive reads them as one stream).
        case streamed
        /// Byte-split 7z / zip: joined into a temporary file first (7z needs to seek).
        case joined
    }

    let volumes: [URL]
    let kind: Kind
    /// Identifies the set, so dropping several of its volumes extracts it only once.
    var key: String { volumes.first.map { $0.standardizedFileURL.path.lowercased() } ?? "" }
    var totalSize: Int64 { volumes.reduce(0) { $0 + ArchiveSupport.fileSize($1) } }

    static func resolve(_ url: URL) throws -> ArchiveVolumeSet {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let lower = name.lowercased()
        let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])

        func numbered(_ regex: String) -> [(Int, String)] {
            guard let re = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive]) else { return [] }
            return siblings.compactMap { s in
                let r = NSRange(s.startIndex..., in: s)
                guard let m = re.firstMatch(in: s, range: r), m.numberOfRanges > 1,
                      let nr = Range(m.range(at: 1), in: s), let n = Int(s[nr]) else { return nil }
                return (n, s)
            }.sorted { $0.0 < $1.0 }
        }
        func checkContiguous(_ parts: [(Int, String)], from first: Int) throws {
            for (i, p) in parts.enumerated() where p.0 != first + i {
                throw NurToError(l: "Part %d of “%@” is missing.", first + i, name)
            }
        }
        func escaped(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

        // name.part1.rar, name.part01.rar…
        if let m = lower.range(of: #"\.part\d+\.rar$"#, options: .regularExpression) {
            let stem = String(name[name.startIndex..<m.lowerBound])
            let parts = numbered("^" + escaped(stem) + #"\.part(\d+)\.rar$"#)
            if parts.count > 1 {
                try checkContiguous(parts, from: parts[0].0 == 0 ? 0 : 1)
                return ArchiveVolumeSet(volumes: parts.map { dir.appendingPathComponent($0.1) }, kind: .streamed)
            }
            return ArchiveVolumeSet(volumes: [url], kind: .single)
        }
        // name.rar + name.r00, name.r01…
        if lower.hasSuffix(".rar") || lower.range(of: #"\.r\d\d$"#, options: .regularExpression) != nil {
            let stem = (name as NSString).deletingPathExtension
            let parts = numbered("^" + escaped(stem) + #"\.r(\d\d)$"#)
            guard !parts.isEmpty else { return ArchiveVolumeSet(volumes: [url], kind: .single) }
            guard let main = siblings.first(where: { $0.lowercased() == (stem + ".rar").lowercased() }) else {
                throw NurToError(l: "The first part of “%@” (.rar) is missing.", name)
            }
            try checkContiguous(parts, from: 0)
            return ArchiveVolumeSet(volumes: [dir.appendingPathComponent(main)] + parts.map { dir.appendingPathComponent($0.1) },
                                    kind: .streamed)
        }
        // name.z01, name.z02… + name.zip (the .zip holds the last part)
        if lower.hasSuffix(".zip") || lower.range(of: #"\.z\d\d$"#, options: .regularExpression) != nil {
            let stem = (name as NSString).deletingPathExtension
            let parts = numbered("^" + escaped(stem) + #"\.z(\d\d)$"#)
            guard !parts.isEmpty else { return ArchiveVolumeSet(volumes: [url], kind: .single) }
            guard let last = siblings.first(where: { $0.lowercased() == (stem + ".zip").lowercased() }) else {
                throw NurToError(l: "The last part of “%@” (.zip) is missing.", name)
            }
            try checkContiguous(parts, from: 1)
            return ArchiveVolumeSet(volumes: parts.map { dir.appendingPathComponent($0.1) } + [dir.appendingPathComponent(last)],
                                    kind: .streamed)
        }
        // name.7z.001, name.zip.001…
        if lower.range(of: #"\.(7z|zip)\.\d{3}$"#, options: .regularExpression) != nil {
            let stem = (name as NSString).deletingPathExtension
            let parts = numbered("^" + escaped(stem) + #"\.(\d{3})$"#)
            try checkContiguous(parts, from: 1)
            return ArchiveVolumeSet(volumes: parts.map { dir.appendingPathComponent($0.1) }, kind: parts.count > 1 ? .joined : .single)
        }
        return ArchiveVolumeSet(volumes: [url], kind: .single)
    }
}

/// When several volumes of one set are dropped together, each arrives as its own job: the first one
/// claims the set and the others are skipped. Claims expire shortly after the run so it can be repeated.
actor ArchiveVolumeClaims {
    static let shared = ArchiveVolumeClaims()
    private var claimed: [String: Date] = [:]

    func claim(_ key: String) -> Bool {
        let now = Date()
        claimed = claimed.filter { $0.value > now }
        if claimed[key] != nil { return false }
        claimed[key] = .distantFuture
        return true
    }

    func release(_ key: String) {
        claimed[key] = Date().addingTimeInterval(5)
    }
}
