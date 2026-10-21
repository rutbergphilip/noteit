import Foundation

/// The central directory of a ZIP archive, read without unpacking it: entry names and their stated unpacked sizes.
/// Handles Zip64 archives. Names flagged as UTF-8 (general-purpose bit 11) are read as UTF-8; unflagged names are
/// read as UTF-8 when they are valid UTF-8 (as macOS's own tools write them) and as CP437 otherwise.
struct ZipDirectory: Equatable {
    struct Entry: Equatable {
        var name: String
        var uncompressedSize: UInt64
    }

    var entries: [Entry]

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

    private static func read(_ handle: FileHandle, fileSize: UInt64) -> ZipDirectory? {
        // End of central directory: 22 bytes plus a comment of up to 65,535 bytes, at the end of the file.
        let tailLength = min(fileSize, 22 + 65_535)
        guard tailLength >= 22, let tail = bytes(handle, at: fileSize - tailLength, count: Int(tailLength)) else { return nil }
        guard let eocd = (0...(tail.count - 22)).reversed().first(where: {
            tail.u32($0) == 0x0605_4b50 && $0 + 22 + Int(tail.u16($0 + 20)) <= tail.count
        }) else { return nil }
        var count = UInt64(tail.u16(eocd + 10))
        var size = UInt64(tail.u32(eocd + 12))
        var offset = UInt64(tail.u32(eocd + 16))
        let eocdOffset = fileSize - tailLength + UInt64(eocd)
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            guard eocdOffset >= 20, let locator = bytes(handle, at: eocdOffset - 20, count: 20),
                  locator.u32(0) == 0x0706_4b50 else { return nil }
            let recordOffset = locator.u64(8)
            guard recordOffset < fileSize, let record = bytes(handle, at: recordOffset, count: 56),
                  record.u32(0) == 0x0606_4b50 else { return nil }
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
            var uncompressed = UInt64(directory.u32(at + 24))
            let nameLength = Int(directory.u16(at + 28))
            let extraLength = Int(directory.u16(at + 30))
            let commentLength = Int(directory.u16(at + 32))
            let nameStart = at + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { return nil }
            if uncompressed == 0xFFFF_FFFF {
                guard let size = zip64Size(directory, from: extraStart, length: extraLength) else { return nil }
                uncompressed = size
            }
            let raw = directory[nameStart..<extraStart]
            guard let name = decodeName(Data(raw), utf8Flag: flags & 0x0800 != 0) else { return nil }
            entries.append(Entry(name: name, uncompressedSize: uncompressed))
            at = next
        }
        return ZipDirectory(entries: entries)
    }

    /// The uncompressed size in a Zip64 extended information field (tag 0x0001), which comes first.
    private static func zip64Size(_ data: [UInt8], from start: Int, length: Int) -> UInt64? {
        var at = start
        let end = start + length
        while at + 4 <= end {
            let tag = data.u16(at)
            let size = Int(data.u16(at + 2))
            guard at + 4 + size <= end else { return nil }
            if tag == 0x0001 {
                return size >= 8 ? data.u64(at + 4) : nil
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
