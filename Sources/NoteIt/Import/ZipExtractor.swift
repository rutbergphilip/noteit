import Compression
import Darwin
import Foundation
import zlib

/// Unpacks a ZIP archive entry by entry as its central directory lists them, so the sizes and counts checked against
/// the directory are the ones written. Local headers are only used to find each entry's data and must agree with the
/// directory. Stored and deflated entries are supported; output is counted as it is written and checked against
/// each entry's stated size and CRC-32. Names are written in precomposed (NFC) form, and folders are opened one
/// component at a time without following symbolic links. On any failure or cancellation the destination is removed.
enum ZipExtractor {
    enum Failure: Error, Equatable, LocalizedError {
        /// Not a readable ZIP archive.
        case unreadable
        /// More entries or bytes than allowed, or an entry unpacking past its stated size.
        case tooLarge
        /// A name that is empty, absolute or climbs out with `..`.
        case unsafeName(String)
        /// An entry whose headers or data don't match the directory.
        case damaged(String)
        case symlink(String)
        case encrypted(String)
        case unsupportedMethod(String, UInt16)

        var errorDescription: String? {
            switch self {
            case .unreadable: "the file isn't a readable ZIP archive"
            case .tooLarge: "it unpacks to more files or data than allowed"
            case .unsafeName(let name): "“\(name)” would be unpacked outside the archive's folder"
            case .damaged(let name): "“\(name)” in it is damaged"
            case .symlink(let name): "“\(name)” in it is a symbolic link"
            case .encrypted(let name): "“\(name)” in it is encrypted"
            case .unsupportedMethod(let name, let method): "“\(name)” in it uses a compression method NoteIt can't read (\(method))"
            }
        }
    }

    struct Result {
        var folder: URL
        var entries: Int
        /// Bytes actually written.
        var bytes: Int64
        /// Bytes written for each file, by its "/"-separated path in NFC.
        var fileSizes: [String: Int64]
    }

    static let chunkSize = 64 * 1024

    /// Unpacks `archive` into `destination`, which must not exist yet.
    static func extract(_ archive: URL, to destination: URL, maxEntries: Int, maxBytes: Int64) throws -> Result {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { throw Failure.unreadable }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), let directory = ZipDirectory.read(handle, fileSize: fileSize) else {
            throw Failure.unreadable
        }
        guard directory.entries.count <= maxEntries, directory.totalUncompressedSize <= UInt64(max(maxBytes, 0)) else {
            throw Failure.tooLarge
        }
        let plans = try directory.entries.map(plan)
        guard mkdir(destination.path, 0o700) == 0 else { throw Failure.unreadable }
        do {
            return try unpack(directory, plans: plans, from: handle.fileDescriptor, fileSize: fileSize,
                              into: destination, maxBytes: maxBytes)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private struct Plan {
        var components: [String]
        var isDirectory: Bool
    }

    /// Checks an entry before anything is written: its name, type, encryption and method.
    private static func plan(_ entry: ZipDirectory.Entry) throws -> Plan {
        let name = entry.name
        var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isDirectory = name.hasSuffix("/")
        if isDirectory { parts.removeLast() }
        guard MarkdownImporter.isSafeZipEntry(name), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw Failure.unsafeName(name)
        }
        if (entry.externalAttributes >> 16) & UInt32(S_IFMT) == UInt32(S_IFLNK) { throw Failure.symlink(name) }
        if entry.flags & 0x0041 != 0 || entry.method == 99 { throw Failure.encrypted(name) }
        guard entry.method == 0 || entry.method == 8 else { throw Failure.unsupportedMethod(name, entry.method) }
        if entry.method == 0, entry.compressedSize != entry.uncompressedSize { throw Failure.damaged(name) }
        if isDirectory, entry.uncompressedSize != 0 { throw Failure.damaged(name) }
        return Plan(components: parts.map(\.precomposedStringWithCanonicalMapping), isDirectory: isDirectory)
    }

    private static func unpack(_ directory: ZipDirectory, plans: [Plan], from fd: Int32, fileSize: UInt64,
                               into destination: URL, maxBytes: Int64) throws -> Result {
        let root = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.unreadable }
        defer { close(root) }
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { input.deallocate(); output.deallocate() }
        var total: Int64 = 0
        var sizes: [String: Int64] = [:]
        for (entry, plan) in zip(directory.entries, plans) {
            try Task.checkCancellation()
            let folders = plan.isDirectory ? plan.components : Array(plan.components.dropLast())
            let parent = try openFolder(folders, under: root, entry: entry.name)
            defer { close(parent) }
            if plan.isDirectory { continue }
            let dataStart = try locateData(entry, in: fd, fileSize: fileSize, directoryOffset: directory.directoryOffset)
            let file = openat(parent, plan.components.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard file >= 0 else { throw Failure.damaged(entry.name) }
            defer { close(file) }
            var written: UInt64 = 0
            var crc = zlib.crc32(0, nil, 0)
            let sink: (UnsafePointer<UInt8>, Int) throws -> Void = { bytes, count in
                guard count > 0 else { return }
                try Task.checkCancellation()
                written += UInt64(count)
                total += Int64(count)
                guard written <= entry.uncompressedSize, total <= maxBytes else { throw Failure.tooLarge }
                crc = zlib.crc32(crc, bytes, uInt(count))
                try writeAll(file, bytes, count, entry: entry.name)
            }
            if entry.method == 0 {
                try copy(entry, from: fd, at: dataStart, buffer: input, into: sink)
            } else {
                try inflate(entry, from: fd, at: dataStart, input: input, output: output, into: sink)
            }
            guard written == entry.uncompressedSize, UInt32(crc) == entry.crc32 else { throw Failure.damaged(entry.name) }
            sizes[plan.components.joined(separator: "/"), default: 0] += Int64(written)
        }
        return Result(folder: destination, entries: directory.entries.count, bytes: total, fileSizes: sizes)
    }

    /// Opens (creating as needed) the folders below `root`, refusing any that is a symbolic link or not a folder.
    private static func openFolder(_ components: [String], under root: Int32, entry: String) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else { throw Failure.damaged(entry) }
        for component in components {
            if mkdirat(current, component, 0o755) != 0, errno != EEXIST {
                close(current)
                throw Failure.damaged(entry)
            }
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw Failure.damaged(entry) }
            current = next
        }
        return current
    }

    /// Where the entry's data starts, after checking that its local header names the same entry and method.
    private static func locateData(_ entry: ZipDirectory.Entry, in fd: Int32, fileSize: UInt64, directoryOffset: UInt64) throws -> UInt64 {
        let headerEnd = entry.localHeaderOffset.addingReportingOverflow(30)
        guard !headerEnd.overflow, headerEnd.partialValue <= directoryOffset else { throw Failure.damaged(entry.name) }
        var header = [UInt8](repeating: 0, count: 30)
        guard readFully(fd, &header, at: entry.localHeaderOffset), header.u32(0) == 0x0403_4b50,
              header.u16(8) == entry.method, header.u16(6) & 0x0041 == entry.flags & 0x0041 else {
            throw Failure.damaged(entry.name)
        }
        let nameLength = Int(header.u16(26))
        let extraLength = UInt64(header.u16(28))
        var name = [UInt8](repeating: 0, count: nameLength)
        guard nameLength == entry.rawName.count, readFully(fd, &name, at: headerEnd.partialValue), name == entry.rawName else {
            throw Failure.damaged(entry.name)
        }
        let dataStart = headerEnd.partialValue + UInt64(nameLength) + extraLength
        let dataEnd = dataStart.addingReportingOverflow(entry.compressedSize)
        guard !dataEnd.overflow, dataEnd.partialValue <= directoryOffset, dataEnd.partialValue <= fileSize else {
            throw Failure.damaged(entry.name)
        }
        return dataStart
    }

    private static func copy(_ entry: ZipDirectory.Entry, from fd: Int32, at start: UInt64, buffer: UnsafeMutablePointer<UInt8>,
                             into sink: (UnsafePointer<UInt8>, Int) throws -> Void) throws {
        var offset = start
        var remaining = entry.compressedSize
        while remaining > 0 {
            let count = Int(min(remaining, UInt64(chunkSize)))
            guard read(fd, buffer, count, at: offset) else { throw Failure.damaged(entry.name) }
            try sink(buffer, count)
            offset += UInt64(count)
            remaining -= UInt64(count)
        }
    }

    /// Raw deflate, streamed through bounded buffers.
    private static func inflate(_ entry: ZipDirectory.Entry, from fd: Int32, at start: UInt64, input: UnsafeMutablePointer<UInt8>,
                                output: UnsafeMutablePointer<UInt8>, into sink: (UnsafePointer<UInt8>, Int) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.damaged(entry.name)
        }
        defer { compression_stream_destroy(stream) }
        var offset = start
        var remaining = entry.compressedSize
        stream.pointee.src_ptr = UnsafePointer(input)
        stream.pointee.src_size = 0
        while true {
            if stream.pointee.src_size == 0, remaining > 0 {
                let count = Int(min(remaining, UInt64(chunkSize)))
                guard read(fd, input, count, at: offset) else { throw Failure.damaged(entry.name) }
                offset += UInt64(count)
                remaining -= UInt64(count)
                stream.pointee.src_ptr = UnsafePointer(input)
                stream.pointee.src_size = count
            }
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = chunkSize
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let produced = chunkSize - stream.pointee.dst_size
            try sink(output, produced)
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                if produced == 0, stream.pointee.src_size == 0, remaining == 0 { throw Failure.damaged(entry.name) }
            default:
                throw Failure.damaged(entry.name)
            }
        }
    }

    private static func read(_ fd: Int32, _ buffer: UnsafeMutablePointer<UInt8>, _ count: Int, at offset: UInt64) -> Bool {
        var done = 0
        while done < count {
            let n = pread(fd, buffer + done, count - done, off_t(offset) + off_t(done))
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            done += n
        }
        return true
    }

    private static func readFully(_ fd: Int32, _ bytes: inout [UInt8], at offset: UInt64) -> Bool {
        let count = bytes.count
        guard count > 0 else { return true }
        return bytes.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, count, at: offset) }
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafePointer<UInt8>, _ count: Int, entry: String) throws {
        var done = 0
        while done < count {
            let n = write(fd, bytes + done, count - done)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw Failure.damaged(entry) }
            done += n
        }
    }
}

private extension Array where Element == UInt8 {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
}
