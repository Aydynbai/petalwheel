import Foundation

/// Decodes plain-text files of unknown encoding (used for txt, md, csv/tsv and subtitles).
/// Order: BOM (UTF-8 / UTF-16 / UTF-32) → strict UTF-8 → BOM-less UTF-16 heuristic →
/// Windows-1251 (when the bytes look Cyrillic) → MacRoman / Windows-1252.
enum DocumentTextDecoder {
    static func decode(contentsOf url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return decode(data)
    }

    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]),
           let s = String(data: Data(bytes.dropFirst(4)), encoding: .utf32LittleEndian) { return s }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]),
           let s = String(data: Data(bytes.dropFirst(4)), encoding: .utf32BigEndian) { return s }
        if bytes.starts(with: [0xFF, 0xFE]),
           let s = String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian) { return s }
        if bytes.starts(with: [0xFE, 0xFF]),
           let s = String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }

        // BOM-less UTF-16: lots of zero bytes in odd/even positions.
        if bytes.count >= 4 {
            let sample = bytes.prefix(4096)
            var evenZeros = 0, oddZeros = 0
            for (i, b) in sample.enumerated() where b == 0 { if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 } }
            let half = sample.count / 2
            if oddZeros > half / 3, evenZeros < half / 20,
               let s = String(data: data, encoding: .utf16LittleEndian) { return s }
            if evenZeros > half / 3, oddZeros < half / 20,
               let s = String(data: data, encoding: .utf16BigEndian) { return s }
        }

        // Single-byte legacy encodings. Windows-1251 if the high bytes are mostly Cyrillic letters
        // (0xC0–0xFF in cp1251), otherwise MacRoman / Windows-1252.
        // Latin-1 accented letters share the 0xC0–0xFF range, but in Western text they are a small
        // fraction of all letters, whereas in Russian text they dominate.
        let high = bytes.filter { $0 >= 0x80 }
        if !high.isEmpty {
            let cyr = high.filter { $0 >= 0xC0 || $0 == 0xA8 || $0 == 0xB8 }.count
            let ascii = bytes.filter { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }.count
            if Double(cyr) / Double(high.count) > 0.6, Double(cyr) > Double(ascii) * 0.5,
               let s = String(data: data, encoding: .windowsCP1251) { return s }
        }
        // MacRoman puts accented letters in 0x80–0x9F, where Windows-1252 has rare punctuation.
        let lowHigh = high.filter { $0 < 0xA0 }.count
        if lowHigh * 2 > high.count, let s = String(data: data, encoding: .macOSRoman) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .macOSRoman) { return s }
        return String(decoding: bytes, as: UTF8.self)
    }
}
