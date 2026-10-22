import Foundation

/// The central directory of a ZIP archive, read without unpacking it: entry names, their stated sizes and where their
/// data is. Handles Zip64 archives; split archives and directories whose entry counts disagree are refused. Names flagged as UTF-8 (general-purpose bit 11) are read as UTF-8; unflagged names are
/// read as UTF-8 when they are valid UTF-8 (as macOS's own tools write them) and as CP437 otherwise.
struct ZipDirectory: Equatable {
    struct Entry: Equatable {
        var name: String
        var uncompressedSize: UInt64
        var rawName: [UInt8] = []
        var compressedSize: UInt64 = 0
        var crc32: UInt32 = 0
        var method: UInt16 = 0
        var flags: UInt16 = 0
        var externalAttributes: UInt32 = 0
        var localHeaderOffset: UInt64 = 0
    }

    var entries: [Entry]
    /// Where the central directory starts; entry data lies before it.
    var directoryOffset: UInt64 = 0

    var totalUncompressedSize: UInt64 {
        entries.reduce(0) { $0.addingReportingOverflow($1.uncompressedSize).overflow ? .max : $0 + $1.uncompressedSize }
    }

    /// Central directories larger than this aren't read.
    static let maxDirectorySize: UInt64 = 256 << 20

    /// The archive's directory, or nil when the file isn't a readable ZIP archive.
    static func read(_ url: URL) -> ZipDirectory? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        return read(handle, fileSize: fileSize)
    }

    static func read(_ handle: FileHandle, fileSize: UInt64) -> ZipDirectory? {
        // End of central directory: 22 bytes plus a comment of up to 65,535 bytes, at the end of the file.
        let tailLength = min(fileSize, 22 + 65_535)
        guard tailLength >= 22, let tail = bytes(handle, at: fileSize - tailLength, count: Int(tailLength)) else { return nil }
        guard let eocd = (0...(tail.count - 22)).reversed().first(where: {
            tail.u32($0) == 0x0605_4b50 && $0 + 22 + Int(tail.u16($0 + 20)) <= tail.count
        }) else { return nil }
        guard tail.u16(eocd + 4) == 0, tail.u16(eocd + 6) == 0, tail.u16(eocd + 8) == tail.u16(eocd + 10) else { return nil }
        var count = UInt64(tail.u16(eocd + 10))
        var size = UInt64(tail.u32(eocd + 12))
        var offset = UInt64(tail.u32(eocd + 16))
        let eocdOffset = fileSize - tailLength + UInt64(eocd)
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            guard eocdOffset >= 20, let locator = bytes(handle, at: eocdOffset - 20, count: 20),
                  locator.u32(0) == 0x0706_4b50 else { return nil }
            let recordOffset = locator.u64(8)
            guard recordOffset < fileSize, let record = bytes(handle, at: recordOffset, count: 56),
                  record.u32(0) == 0x0606_4b50, record.u32(16) == 0, record.u32(20) == 0,
                  record.u64(24) == record.u64(32) else { return nil }
            count = record.u64(32)
            size = record.u64(40)
            offset = record.u64(48)
        }
        guard size <= maxDirectorySize, offset <= fileSize, size <= fileSize - offset,
              count <= size / 46 + 1 else { return nil }
        guard let directory = bytes(handle, at: offset, count: Int(size)) else { return nil }
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var at = 0
        for _ in 0..<count {
            guard at + 46 <= directory.count, directory.u32(at) == 0x0201_4b50 else { return nil }
            let flags = directory.u16(at + 8)
            var compressed = UInt64(directory.u32(at + 20))
            var uncompressed = UInt64(directory.u32(at + 24))
            var localOffset = UInt64(directory.u32(at + 42))
            let disk = directory.u16(at + 34)
            let nameLength = Int(directory.u16(at + 28))
            let extraLength = Int(directory.u16(at + 30))
            let commentLength = Int(directory.u16(at + 32))
            let nameStart = at + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { return nil }
            var wide = [uncompressed, compressed, localOffset].map { $0 == 0xFFFF_FFFF }
            wide.append(disk == 0xFFFF)
            if wide.contains(true) {
                guard let values = zip64Values(directory, from: extraStart, length: extraLength, wide: wide) else { return nil }
                var next = values.makeIterator()
                if wide[0] { uncompressed = next.next()! }
                if wide[1] { compressed = next.next()! }
                if wide[2] { localOffset = next.next()! }
                if wide[3] { guard next.next()! == 0 else { return nil } }
            }
            guard wide[3] || disk == 0 else { return nil }
            let raw = Array(directory[nameStart..<extraStart])
            guard let name = decodeName(Data(raw), utf8Flag: flags & 0x0800 != 0) else { return nil }
            entries.append(Entry(name: name, uncompressedSize: uncompressed, rawName: raw, compressedSize: compressed,
                                 crc32: directory.u32(at + 16), method: directory.u16(at + 10), flags: flags,
                                 externalAttributes: directory.u32(at + 38), localHeaderOffset: localOffset))
            at = next
        }
        guard at == directory.count else { return nil }
        return ZipDirectory(entries: entries, directoryOffset: offset)
    }

    /// The values in a Zip64 extended information field (tag 0x0001) for the fields marked `wide`, in their order:
    /// uncompressed size, compressed size and local header offset (8 bytes each), then the disk number (4 bytes).
    private static func zip64Values(_ data: [UInt8], from start: Int, length: Int, wide: [Bool]) -> [UInt64]? {
        var at = start
        let end = start + length
        while at + 4 <= end {
            let tag = data.u16(at)
            let size = Int(data.u16(at + 2))
            guard at + 4 + size <= end else { return nil }
            if tag == 0x0001 {
                var values: [UInt64] = []
                var field = at + 4
                for (index, isWide) in wide.enumerated() where isWide {
                    let width = index == 3 ? 4 : 8
                    guard field + width <= at + 4 + size else { return nil }
                    values.append(width == 8 ? data.u64(field) : UInt64(data.u32(field)))
                    field += width
                }
                return values
            }
            at += 4 + size
        }
        return nil
    }

    static func decodeName(_ data: Data, utf8Flag: Bool) -> String? {
        if let name = String(data: data, encoding: .utf8) { return name }
        guard !utf8Flag else { return nil }
        return String(data: data, encoding: cp437)
    }

    private static let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    private static func bytes(_ handle: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return [UInt8](data)
    }
}

private extension Array where Element == UInt8 {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
}
