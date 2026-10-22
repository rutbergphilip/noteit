import Compression
import Darwin
import Foundation
import zlib

/// Unpacks a ZIP archive entry by entry as its central directory lists them, so the sizes and counts checked against
/// the directory are the ones written. Local headers are only used to find each entry's data and must agree with the
/// directory. Stored and deflated entries are supported; output is counted as it is written and checked against
/// each entry's stated size and CRC-32. Names are written in precomposed (NFC) form, and folders are opened one
/// component at a time without following symbolic links. Nothing is overwritten: an entry whose name is already taken
/// on disk (a repeated name, or one differing only in case or Unicode form) gets the next free "name 2.ext" that no
/// entry of the archive has as its own name.
/// On any failure or cancellation the destination is removed.
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
        /// A name nested more than `maxDepth` folders deep, with a part longer than `maxComponentLength`, or whose
        /// path on disk would pass `maxPathBytes` (which file APIs taking paths can't reach, not even to delete it).
        case nameTooLong(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "the file isn't a readable ZIP archive"
            case .tooLarge: "it unpacks to more files or data than allowed"
            case .unsafeName(let name): "“\(name)” would be unpacked outside the archive's folder"
            case .damaged(let name): "“\(name)” in it is damaged"
            case .symlink(let name): "“\(name)” in it is a symbolic link"
            case .encrypted(let name): "“\(name)” in it is encrypted"
            case .unsupportedMethod(let name, let method): "“\(name)” in it uses a compression method NoteIt can't read (\(method))"
            case .nameTooLong(let name):
                "“\(name.count > 80 ? name.prefix(80) + "…" : name)” in it is too deeply nested or too long to unpack"
            }
        }
    }

    struct Result {
        var folder: URL
        var entries: Int
        /// Bytes actually written.
        var bytes: Int64
        /// Bytes written for each file, by its "/"-separated path on disk, in NFC.
        var fileSizes: [String: Int64]
        /// Files and folders written under another name because theirs was taken.
        var renamed = 0
    }

    static let chunkSize = 64 * 1024
    static let maxDepth = 256
    /// APFS's limit for one name, counted in UTF-16 units of the name as written (NFC here), not in bytes.
    static let maxComponentLength = 255
    static let maxPathBytes = Int(PATH_MAX) - 1

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
        let base = realLength(of: destination)
        let plans = try directory.entries.map { entry in
            try Task.checkCancellation()
            return try plan(entry, under: base)
        }
        var naming = try Naming(plans: plans)
        guard mkdir(destination.path, 0o700) == 0 else { throw Failure.unreadable }
        do {
            return try unpack(directory, plans: plans, naming: &naming, from: handle.fileDescriptor, fileSize: fileSize,
                              into: destination, at: base, maxBytes: maxBytes)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// The length of `destination`'s path with its folder's symbolic links resolved ("/var" is "/private/var"), as
    /// the system counts it against `PATH_MAX`.
    private static func realLength(of destination: URL) -> Int {
        let folder = destination.deletingLastPathComponent().path
        guard let real = realpath(folder, nil) else { return destination.path.utf8.count }
        defer { free(real) }
        return max(strlen(real) + 1 + destination.lastPathComponent.utf8.count, destination.path.utf8.count)
    }

    private struct Plan {
        /// The name's parts, in NFC.
        var components: [String]
        /// `components` case-folded, as `Naming` compares them.
        var folded: [String]
        var isDirectory: Bool
        /// How many of `components` are folders.
        var folderCount: Int { isDirectory ? components.count : components.count - 1 }
    }

    /// Checks an entry before anything is written: its name, type, encryption and method.
    private static func plan(_ entry: ZipDirectory.Entry, under base: Int) throws -> Plan {
        let name = entry.name
        var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isDirectory = name.hasSuffix("/")
        if isDirectory { parts.removeLast() }
        guard MarkdownImporter.isSafeZipEntry(name), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw Failure.unsafeName(name)
        }
        guard parts.count <= maxDepth else { throw Failure.nameTooLong(name) }
        let components = parts.map(\.precomposedStringWithCanonicalMapping)
        guard components.allSatisfy({ $0.utf16.count <= maxComponentLength }),
              components.reduce(base, { $0 + 1 + $1.utf8.count }) <= maxPathBytes else {
            throw Failure.nameTooLong(name)
        }
        if (entry.externalAttributes >> 16) & UInt32(S_IFMT) == UInt32(S_IFLNK) { throw Failure.symlink(name) }
        if entry.flags & 0x0041 != 0 || entry.method == 99 { throw Failure.encrypted(name) }
        guard entry.method == 0 || entry.method == 8 else { throw Failure.unsupportedMethod(name, entry.method) }
        if entry.method == 0, entry.compressedSize != entry.uncompressedSize { throw Failure.damaged(name) }
        if isDirectory, entry.uncompressedSize != 0 { throw Failure.damaged(name) }
        return Plan(components: components, folded: components.map(Naming.fold), isDirectory: isDirectory)
    }

    private static func unpack(_ directory: ZipDirectory, plans: [Plan], naming: inout Naming, from fd: Int32,
                               fileSize: UInt64, into destination: URL, at base: Int, maxBytes: Int64) throws -> Result {
        let root = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.unreadable }
        defer { close(root) }
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { input.deallocate(); output.deallocate() }
        var total: Int64 = 0
        var sizes: [String: Int64] = [:]
        // The folder the last entry was in, kept open as entries of a folder usually follow each other.
        var last: (id: Int, fd: Int32, path: [String])?
        defer { if let last { close(last.fd) } }
        for (index, (entry, plan)) in zip(directory.entries, plans).enumerated() {
            try Task.checkCancellation()
            let folderIDs = naming.folderIDs[index]
            let folderID = folderIDs.last ?? 0
            let (parent, path): (Int32, [String])
            if let last, last.id == folderID {
                (parent, path) = (dup(last.fd), last.path)
                guard parent >= 0 else { throw Failure.damaged(entry.name) }
            } else {
                (parent, path) = try openFolder(plan, ids: folderIDs, under: root, at: base, entry: entry.name,
                                                naming: &naming)
                if let last { close(last.fd) }
                let kept = dup(parent)
                last = kept >= 0 ? (folderID, kept, path) : nil
            }
            defer { close(parent) }
            if plan.isDirectory { continue }
            let dataStart = try locateData(entry, in: fd, fileSize: fileSize, directoryOffset: directory.directoryOffset)
            let wanted = plan.components.last!
            var file: Int32 = -1
            var tooLong = false
            let folderBytes = path.reduce(base, { $0 + 1 + $1.utf8.count })
            let created = try naming.firstFree(wanted, folded: plan.folded.last!, in: folderID,
                                               resume: true) { name in
                guard fits(name, after: folderBytes) else { tooLong = true; return nil }
                file = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
                if file < 0, errno == ENAMETOOLONG { tooLong = true }
                return file >= 0 ? true : errno == EEXIST ? false : nil
            }
            guard let name = created, file >= 0 else {
                throw tooLong ? Failure.nameTooLong(entry.name) : Failure.damaged(entry.name)
            }
            defer { close(file) }
            if name != wanted { naming.renamed += 1 }
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
            sizes[(path + [name]).joined(separator: "/")] = Int64(written)
        }
        return Result(folder: destination, entries: directory.entries.count, bytes: total, fileSizes: sizes, renamed: naming.renamed)
    }

    /// "readme.md", 2 → "readme 2.md"; "LICENSE", 2 → "LICENSE 2".
    static func numbered(_ name: String, _ number: Int) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty || stem.isEmpty ? "\(name) \(number)" : "\(stem) \(number).\(ext)"
    }

    /// How names that are taken on disk are replaced, for one archive. Names are compared case-folded and in NFC,
    /// as a case-insensitive volume compares them ("Straße" and "STRASSE" are one name). Each folder of the archive
    /// gets a number (the archive's root is 0), so its case variants are one folder.
    private struct Naming {
        struct Key: Hashable {
            var folder: Int
            var name: String
        }

        /// For each entry, the numbers of the folders it lies in, outermost first.
        let folderIDs: [[Int]]
        /// The case-folded names entries of the archive have in each folder, which a numbered name never takes.
        let reserved: [Int: Set<String>]
        /// The name each folder was given on disk.
        var folders: [Int: String] = [:]
        /// Where the numbered search for a file name in a folder resumes.
        var nextNumbers: [Key: Int] = [:]
        var renamed = 0
        let attempts: Int

        init(plans: [Plan]) throws {
            var ids: [Key: Int] = [:]
            var reserved: [Int: Set<String>] = [:]
            var folderIDs: [[Int]] = []
            folderIDs.reserveCapacity(plans.count)
            for plan in plans {
                try Task.checkCancellation()
                var parent = 0
                var entryIDs: [Int] = []
                for (depth, name) in plan.folded.enumerated() {
                    reserved[parent, default: []].insert(name)
                    guard depth < plan.folderCount else { break }
                    let key = Key(folder: parent, name: name)
                    let id = ids[key] ?? ids.count + 1
                    ids[key] = id
                    entryIDs.append(id)
                    parent = id
                }
                folderIDs.append(entryIDs)
            }
            self.folderIDs = folderIDs
            self.reserved = reserved
            attempts = 2 * plans.count + 2
        }

        static func fold(_ name: String) -> String {
            name.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        }

        /// Tries `name`, then numbered names not reserved in `folder`, until `create` succeeds (true) or fails other
        /// than because the name is taken (nil). With `resume`, the numbered search starts where the last one for
        /// this name stopped, so a name repeated many times doesn't make each search start again at "name 2".
        mutating func firstFree(_ name: String, folded: String, in folder: Int, resume: Bool,
                                create: (String) -> Bool?) throws -> String? {
            switch create(name) {
            case true?: return name
            case nil: return nil
            case false?: break
            }
            let taken = reserved[folder] ?? []
            let resumeKey = Key(folder: folder, name: folded)
            var number = resume ? nextNumbers[resumeKey] ?? 2 : 2
            for _ in 0..<attempts {
                try Task.checkCancellation()
                let candidate = numbered(name, number)
                number += 1
                if taken.contains(Self.fold(candidate)) { continue }
                switch create(candidate) {
                case true?:
                    if resume { nextNumbers[resumeKey] = number }
                    return candidate
                case nil: return nil
                case false?: continue
                }
            }
            return nil
        }
    }

    /// Whether `name` can be created in a folder whose path takes `bytes`, numbered names included.
    private static func fits(_ name: String, after bytes: Int) -> Bool {
        name.utf16.count <= maxComponentLength && bytes + 1 + name.utf8.count <= maxPathBytes
    }

    /// Opens (creating as needed) the folders `plan` lies in below `root`, never following a symbolic link. A
    /// folder whose name is taken by a file gets a numbered name, remembered by its number in `naming` so later
    /// entries in it and its case variants land in the same place; the numbered search starts at 2 each time, so
    /// an existing numbered folder is reused before a new one is made. Returns the folder and its path on disk.
    private static func openFolder(_ plan: Plan, ids: [Int], under root: Int32, at base: Int, entry: String,
                                   naming: inout Naming) throws -> (Int32, [String]) {
        var current = dup(root)
        guard current >= 0 else { throw Failure.damaged(entry) }
        var path: [String] = []
        var bytes = base
        var tooLong = false
        for (depth, id) in ids.enumerated() {
            let component = plan.components[depth]
            var next: Int32 = -1
            var name = naming.folders[id] ?? component
            if naming.folders[id] != nil {
                next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } else {
                // An existing folder of the plain name is merged into; a file or link there means a numbered name.
                let parent = current
                let found: String?
                do {
                    found = try naming.firstFree(component, folded: plan.folded[depth], in: depth == 0 ? 0 : ids[depth - 1],
                                                 resume: false) { candidate in
                        guard fits(candidate, after: bytes) else { tooLong = true; return nil }
                        if mkdirat(parent, candidate, 0o755) != 0, errno != EEXIST {
                            if errno == ENAMETOOLONG { tooLong = true }
                            return nil
                        }
                        next = openat(parent, candidate, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        if next < 0, errno == ENAMETOOLONG { tooLong = true }
                        return next >= 0 ? true : errno == ENOTDIR || errno == ELOOP ? false : nil
                    }
                } catch {
                    close(current)
                    throw error
                }
                if let found, next >= 0 {
                    name = found
                    naming.folders[id] = name
                    if name != component { naming.renamed += 1 }
                }
            }
            close(current)
            guard next >= 0 else { throw tooLong ? Failure.nameTooLong(entry) : Failure.damaged(entry) }
            current = next
            path.append(name)
            bytes += 1 + name.utf8.count
        }
        return (current, path)
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
