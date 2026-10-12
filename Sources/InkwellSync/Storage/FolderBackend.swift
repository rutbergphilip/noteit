import CryptoKit
import Foundation

/// Stores objects as files under a root directory (NAS mount, iCloud Drive, Dropbox, ...).
public final class FolderBackend: StorageBackend, @unchecked Sendable {
    static let hashedSizeLimit: Int64 = 256 * 1024

    public let root: URL
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let cacheLock = NSLock()
    private var hashCache: [String: (stamp: Stamp, etag: String)] = [:]
    private var _hashedFileReads = 0

    /// Number of small files read to compute an etag; lets tests check that `list` stays cheap.
    var hashedFileReads: Int { cacheLock.withLock { _hashedFileReads } }

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func list(prefix: String) async throws -> [RemoteObject] {
        try listSync(prefix: prefix)
    }

    private func listSync(prefix: String) throws -> [RemoteObject] {
        try requireRoot()
        let rootPath = root.resolvingSymlinksInPath().path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw StorageError.io("Cannot enumerate \(root.path)")
        }
        var objects: [RemoteObject] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(".icloud") || name.contains(".tmp-") { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let key = String(path.dropFirst(rootPath.count + 1))
            guard key.hasPrefix(prefix), let info = try? fileInfo(key: key, path: path) else { continue }
            objects.append(RemoteObject(key: key, etag: info.etag, size: info.size))
        }
        return objects.sorted { $0.key < $1.key }
    }

    public func get(_ key: String) async throws -> (data: Data, etag: String) {
        let url = try fileURL(for: key)
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw StorageError.notFound(key) }
            throw StorageError.io(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        // Stat and read the same open file so a concurrent rename can't pair these bytes with another write's etag.
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw StorageError.io(String(cString: strerror(errno))) }
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            throw StorageError.io(error.localizedDescription)
        }
        return (data, etag(key: key, stamp: Stamp(st), content: data))
    }

    @discardableResult
    public func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        let url = try fileURL(for: key)
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let stamp: Stamp
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            stamp = try writeNewFile(temp.path, data)
        } catch {
            try? fileManager.removeItem(at: temp)
            if let error = error as? StorageError { throw error }
            throw StorageError.io(error.localizedDescription)
        }
        // rename keeps the inode and mtime, so the temp file's stat describes the final object.
        let newETag = etag(key: key, stamp: stamp, content: data)

        return try withStoreLock {
            let current = try? fileInfo(key: key, path: url.path).etag
            if (ifNoneMatch && current != nil) || (ifMatch != nil && current != ifMatch) {
                try? fileManager.removeItem(at: temp)
                throw StorageError.preconditionFailed(key)
            }
            if ifNoneMatch {
                // Exclusive rename makes create-if-absent atomic across processes on local volumes.
                if renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 { return newETag }
                if errno == EEXIST {
                    try? fileManager.removeItem(at: temp)
                    throw StorageError.preconditionFailed(key)
                }
            }
            guard rename(temp.path, url.path) == 0 else {
                let message = String(cString: strerror(errno))
                try? fileManager.removeItem(at: temp)
                throw StorageError.io(message)
            }
            return newETag
        }
    }

    public func delete(_ key: String) async throws {
        try await delete(key, ifMatch: nil)
    }

    public func delete(_ key: String, ifMatch: String?) async throws {
        let url = try fileURL(for: key)
        try withStoreLock {
            if let ifMatch {
                let current: String
                do {
                    current = try fileInfo(key: key, path: url.path).etag
                } catch {
                    if access(url.path, F_OK) != 0 { throw StorageError.notFound(key) }
                    throw error
                }
                if current != ifMatch { throw StorageError.preconditionFailed(key) }
            }
            cacheLock.withLock { hashCache[key] = nil }
            guard unlink(url.path) == 0 else {
                if errno == ENOENT { throw StorageError.notFound(key) }
                throw StorageError.io(String(cString: strerror(errno)))
            }
        }
    }

    /// Serializes conditional writes within this process (NSLock) and across processes/machines
    /// sharing the folder (advisory flock on a hidden lock file). If the volume doesn't support
    /// locking, falls back to the in-process lock only.
    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            let fd = Darwin.open(root.appendingPathComponent(".inkwell-lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return try body() }
            defer { close(fd) }
            var locked = false
            for attempt in 0..<200 {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
                if errno != EWOULDBLOCK { break }
                if attempt < 199 { usleep(10_000) }
            }
            defer { if locked { flock(fd, LOCK_UN) } }
            return try body()
        }
    }

    public func probe() async throws {
        try requireRoot()
        let url = root.appendingPathComponent(".inkwell-probe-\(UUID().uuidString)")
        do {
            try Data("probe".utf8).write(to: url)
            try fileManager.removeItem(at: url)
        } catch {
            throw StorageError.io(error.localizedDescription)
        }
    }

    private func requireRoot() throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw StorageError.notFound(root.path)
        }
    }

    private func fileURL(for key: String) throws -> URL {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard !key.isEmpty, !key.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw StorageError.io("Invalid key: \(key)")
        }
        return root.appendingPathComponent(key)
    }

    private func writeNewFile(_ path: String, _ data: Data) throws -> Stamp {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw StorageError.io(String(cString: strerror(errno))) }
        defer { close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw StorageError.io(String(cString: strerror(errno))) }
        return Stamp(st)
    }

    /// Small files (every meta, tombstone and the manifest) get a content hash, because coarse-mtime
    /// volumes (FAT/exFAT, some SMB) give same-size rewrites equal stat etags. Larger bodies use stat.
    private func etag(key: String, stamp: Stamp, content: Data) -> String {
        guard stamp.size <= Self.hashedSizeLimit else { return stamp.etag }
        let etag = "h" + SHA256.hash(data: content).prefix(16).map { String(format: "%02x", $0) }.joined()
        cacheLock.withLock { hashCache[key] = (stamp, etag) }
        return etag
    }

    private func fileInfo(key: String, path: String) throws -> (etag: String, size: Int) {
        var st = stat()
        guard stat(path, &st) == 0 else {
            if errno == ENOENT { throw StorageError.notFound(key) }
            throw StorageError.io(String(cString: strerror(errno)))
        }
        let stamp = Stamp(st)
        guard stamp.size <= Self.hashedSizeLimit else { return (stamp.etag, Int(stamp.size)) }
        // Files whose stat is unchanged reuse the cached hash instead of being re-read.
        if let cached = cacheLock.withLock({ hashCache[key] }), cached.stamp == stamp {
            return (cached.etag, Int(stamp.size))
        }
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw StorageError.notFound(key) }
            throw StorageError.io(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw StorageError.io(String(cString: strerror(errno))) }
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            throw StorageError.io(error.localizedDescription)
        }
        cacheLock.withLock { _hashedFileReads += 1 }
        let openedStamp = Stamp(opened)
        return (etag(key: key, stamp: openedStamp, content: data), data.count)
    }

    private struct Stamp: Equatable {
        var mtimeNs: Int64
        var ctimeNs: Int64
        var size: Int64
        var inode: UInt64

        init(_ st: stat) {
            mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
            ctimeNs = Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec)
            size = Int64(st.st_size)
            inode = UInt64(st.st_ino)
        }

        var etag: String { "\(mtimeNs)-\(size)-\(inode)" }
    }
}
