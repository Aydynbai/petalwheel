import Foundation

/// Reads a zip's central directory without extracting anything: encryption flags, declared sizes and
/// the raw bytes of names (to spot Windows-made zips whose names are in CP866 / CP1251).
struct ZipInspection {
    var entryCount = 0
    var encrypted = false
    var totalUncompressed: Int64 = 0
    /// bsdtar `hdrcharset` to use, nil when names are UTF-8 / ASCII.
    var nameCharset: String?
}

enum ArchiveInspector {
    /// nil when the file isn't a readable zip (split zips, damaged files): callers fall back to bsdtar alone.
    static func inspectZip(_ url: URL) -> ZipInspection? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let fileSize = try? h.seekToEnd(), fileSize >= 22 else { return nil }

        // End of central directory: in the last 64 KB + 22 bytes.
        let tailLength = min(fileSize, 65_557)
        guard (try? h.seek(toOffset: fileSize - tailLength)) != nil,
              let tail = try? h.read(upToCount: Int(tailLength)), tail.count >= 22 else { return nil }
        let t = [UInt8](tail)
        var eocd: Int?
        var i = t.count - 22
        while i >= 0 {
            if t[i] == 0x50, t[i + 1] == 0x4B, t[i + 2] == 0x05, t[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { return nil }
        var count = UInt64(le16(t, e + 10))
        var cdSize = UInt64(le32(t, e + 12))
        var cdOffset = UInt64(le32(t, e + 16))
        let disk = le16(t, e + 4)
        if disk != 0 { return nil }   // spanned archive: offsets are per volume

        // ZIP64: the locator sits right before the EOCD.
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, e >= 20,
           t[e - 20] == 0x50, t[e - 19] == 0x4B, t[e - 18] == 0x06, t[e - 17] == 0x07 {
            let z64Offset = le64(t, e - 20 + 8)
            guard (try? h.seek(toOffset: z64Offset)) != nil,
                  let rec = try? h.read(upToCount: 56), rec.count == 56 else { return nil }
            let r = [UInt8](rec)
            guard r[0] == 0x50, r[1] == 0x4B, r[2] == 0x06, r[3] == 0x06 else { return nil }
            count = le64(r, 32)
            cdSize = le64(r, 40)
            cdOffset = le64(r, 48)
        }
        guard cdOffset + cdSize <= fileSize, cdSize < 512 << 20,
              (try? h.seek(toOffset: cdOffset)) != nil,
              let cdData = try? h.read(upToCount: Int(cdSize)), cdData.count == Int(cdSize) else { return nil }
        let cd = [UInt8](cdData)

        var result = ZipInspection()
        var rawNames: [[UInt8]] = []
        var p = 0
        var n: UInt64 = 0
        while n < count, p + 46 <= cd.count {
            guard cd[p] == 0x50, cd[p + 1] == 0x4B, cd[p + 2] == 0x01, cd[p + 3] == 0x02 else { break }
            let flags = le16(cd, p + 8)
            var size = UInt64(le32(cd, p + 24))
            let nameLen = Int(le16(cd, p + 28)), extraLen = Int(le16(cd, p + 30)), commentLen = Int(le16(cd, p + 32))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { break }
            let name = Array(cd[(p + 46)..<(p + 46 + nameLen)])
            if size == 0xFFFF_FFFF {
                // ZIP64 extra field (0x0001): uncompressed size comes first.
                var x = p + 46 + nameLen
                let end = x + extraLen
                while x + 4 <= end {
                    let id = le16(cd, x), len = Int(le16(cd, x + 2))
                    if id == 0x0001, len >= 8, x + 12 <= end { size = le64(cd, x + 4); break }
                    x += 4 + len
                }
            }
            if flags & 0x1 != 0 { result.encrypted = true }
            result.totalUncompressed &+= Int64(clamping: size)
            if flags & 0x800 == 0 { rawNames.append(name) }   // bit 11: names are UTF-8
            p += 46 + nameLen + extraLen + commentLen
            n += 1
        }
        result.entryCount = Int(n)
        result.nameCharset = guessCharset(rawNames)
        return result
    }

    /// For names stored without the UTF-8 flag: nil when they are ASCII or valid UTF-8, otherwise the
    /// Cyrillic DOS/Windows code page that reads best.
    static func guessCharset(_ names: [[UInt8]]) -> String? {
        let nonASCII = names.filter { $0.contains { $0 >= 0x80 } }
        guard !nonASCII.isEmpty else { return nil }
        if nonASCII.allSatisfy({ String(bytes: $0, encoding: .utf8) != nil }) { return nil }
        var score866 = 0, score1251 = 0
        for name in nonASCII {
            for b in name where b >= 0x80 {
                // CP866: А-Я а-п 0x80-0xAF, р-я 0xE0-0xEF, Ё/ё 0xF0/0xF1; 0xB0-0xDF are box drawing.
                if b <= 0xAF || (0xE0...0xF1).contains(b) { score866 += 1 } else { score866 -= 2 }
                // CP1251: А-я 0xC0-0xFF, Ё/ё 0xA8/0xB8.
                if b >= 0xC0 || b == 0xA8 || b == 0xB8 { score1251 += 1 } else { score1251 -= 2 }
            }
        }
        // Explorer and most Windows zippers use the OEM code page (CP866) in Russian Windows.
        return score1251 > score866 ? "CP1251" : "CP866"
    }

    private static func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func le64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(le32(b, o)) | UInt64(le32(b, o + 4)) << 32 }
}
