import CryptoKit
import Foundation

/// Stores objects as files under a root directory (NAS mount, iCloud Drive, Dropbox, ...).
///
/// The root may be on a network volume that goes away. Every call runs on `ioQueue`, never on the caller's
/// thread or Swift's cooperative pool, because a dead mount can block a system call for minutes. A missing root
/// or an unreachable volume throws `unavailable`, never `notFound`, and a listing either sees every object or
/// throws: a partial listing would look like deletions made on another Mac.
///
/// When the root is a share's mount point, an empty local folder can be left at its path after an unmount. So
/// the root's identity (device and inode) is recorded on first use and a different folder at the same path is
/// `unavailable`, and with `store` set a root without a NoteIt store in it is too (see `StorePolicy`).
public final class FolderBackend: StorageBackend, @unchecked Sendable {
    /// How a root without a NoteIt store (`RemoteLayout.root`, or Inkwell's `legacyRoot`) in it is treated.
    public enum StorePolicy: Sendable {
        /// No store needed; any keys.
        case unchecked
        /// A missing store means this isn't the folder that was synced: every call throws `unavailable`.
        case existing
        /// Connecting to a folder: a missing store reads as empty and may be created. Once seen, like `existing`.
        case creatable
    }

    private static let ioQueue = DispatchQueue(label: "NoteIt.FolderBackend.io", qos: .utility, attributes: .concurrent)

    static let hashedSizeLimit: Int64 = 256 * 1024
    static let lockFileName = ".noteit-lock"

    public let root: URL
    public let store: StorePolicy
    private let lock = NSLock()
    private let stateLock = NSLock()
    private var rootIdentity: RootIdentity?
    private var storeSeen = false
    private let fileManager = FileManager.default
    private let cacheLock = NSLock()
    private var hashCache: [String: (stamp: Stamp, etag: String)] = [:]
    private var _hashedFileReads = 0

    /// Number of small files read to compute an etag; lets tests check that `list` stays cheap.
    var hashedFileReads: Int { cacheLock.withLock { _hashedFileReads } }

    public init(root: URL, store: StorePolicy = .unchecked) {
        self.root = root.standardizedFileURL
        self.store = store
    }

    public func list(prefix: String) async throws -> [RemoteObject] {
        try await onIOQueue { try self.listSync(prefix: prefix) }
    }

    private func listSync(prefix: String) throws -> [RemoteObject] {
        try requireRoot()
        let rootPath = root.resolvingSymlinksInPath().path
        func relativeKey(_ url: URL) -> String? {
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : nil
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                // Folders that can't hold listed keys (a NAS's #recycle, say) may stay unreadable.
                if let key = relativeKey(url), !key.hasPrefix(prefix), !prefix.hasPrefix(key + "/") { return true }
                enumerationError = error
                return false
            }
        ) else {
            throw StorageError.io("Cannot enumerate \(root.path)")
        }
        var objects: [RemoteObject] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(".icloud") || name.contains(".tmp-") { continue }
            guard let key = relativeKey(url), key.hasPrefix(prefix) else { continue }
            let isRegularFile: Bool
            do {
                isRegularFile = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            } catch {
                if Self.posixCode(of: error) == ENOENT { continue }  // Removed since it was enumerated.
                throw storageError(error, key: key)
            }
            guard isRegularFile else { continue }
            let path = rootPath + "/" + key
            let info: (etag: String, size: Int)
            do {
                info = try fileInfo(key: key, path: path)
            } catch StorageError.notFound {
                continue  // Deleted by another Mac since it was enumerated.
            }
            objects.append(RemoteObject(key: key, etag: info.etag, size: info.size))
        }
        if let enumerationError { throw storageError(enumerationError, key: prefix) }
        // An unmount ends the enumeration early without an error; files that vanished with it were skipped above.
        try requireRoot()
        return objects.sorted { $0.key < $1.key }
    }

    public func get(_ key: String) async throws -> (data: Data, etag: String) {
        try await onIOQueue { try self.getSync(key) }
    }

    private func getSync(_ key: String) throws -> (data: Data, etag: String) {
        let url = try fileURL(for: key)
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw storageError(errno, key: key) }
        defer { close(fd) }
        // Stat and read the same open file so a concurrent rename can't pair these bytes with another write's etag.
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw storageError(errno, key: key) }
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            throw storageError(error, key: key)
        }
        return (data, etag(key: key, stamp: Stamp(st), content: data))
    }

    @discardableResult
    public func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        try await onIOQueue { try self.putSync(key, data: data, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch) }
    }

    private func putSync(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) throws -> String {
        let url = try fileURL(for: key)
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let stamp: Stamp
        do {
            try makeDirectories(for: key)
            stamp = try writeNewFile(temp.path, data, key: key)
        } catch {
            unlink(temp.path)
            if let error = error as? StorageError { throw error }
            throw storageError(error, key: key)
        }
        // rename keeps the inode and mtime, so the temp file's stat describes the final object.
        let newETag = etag(key: key, stamp: stamp, content: data)

        return try withStoreLock {
            let current: String?
            do {
                current = try fileInfo(key: key, path: url.path).etag
            } catch StorageError.notFound {
                current = nil
            } catch {
                unlink(temp.path)
                throw error
            }
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
                let error = storageError(errno, key: key)
                unlink(temp.path)
                throw error
            }
            return newETag
        }
    }

    public func delete(_ key: String) async throws {
        try await delete(key, ifMatch: nil)
    }

    public func delete(_ key: String, ifMatch: String?) async throws {
        try await onIOQueue { try self.deleteSync(key, ifMatch: ifMatch) }
    }

    private func deleteSync(_ key: String, ifMatch: String?) throws {
        let url = try fileURL(for: key)
        try withStoreLock {
            if let ifMatch {
                let current = try fileInfo(key: key, path: url.path).etag
                if current != ifMatch { throw StorageError.preconditionFailed(key) }
            }
            cacheLock.withLock { hashCache[key] = nil }
            guard unlink(url.path) == 0 else { throw storageError(errno, key: key) }
        }
    }

    /// Serializes conditional writes within this process (NSLock) and across processes/machines
    /// sharing the folder (advisory flock on a hidden lock file). If the volume doesn't support
    /// locking, falls back to the in-process lock only.
    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            try requireRoot()
            let fd = Darwin.open(root.appendingPathComponent(Self.lockFileName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
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
        try await onIOQueue {
            try self.requireRoot()
            let url = self.root.appendingPathComponent(".noteit-probe-\(UUID().uuidString)")
            do {
                try Data("probe".utf8).write(to: url)
                try self.fileManager.removeItem(at: url)
            } catch {
                throw self.storageError(error, key: url.lastPathComponent)
            }
        }
    }

    /// Runs blocking file-system work on `ioQueue`, so a hung network mount never holds a cooperative thread.
    private func onIOQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// The root is the folder this backend first used, and holds a store unless `store` is `unchecked`.
    private func requireRoot() throws {
        var st = stat()
        guard stat(root.path, &st) == 0 else {
            let code = errno
            throw code == ENOENT || code == ENOTDIR ? unavailable() : Self.storageError(code, key: root.path)
        }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw unavailable() }
        if store != .unchecked {
            let present = [RemoteLayout.root, RemoteLayout.legacyRoot].contains { isDirectory(root.appendingPathComponent($0).path) }
            let seen = stateLock.withLock {
                if present { storeSeen = true }
                return storeSeen
            }
            if !present, store == .existing || seen { throw unavailable() }
        }
        let identity = RootIdentity(device: st.st_dev, inode: st.st_ino)
        let recorded = stateLock.withLock {
            if rootIdentity == nil { rootIdentity = identity }
            return rootIdentity
        }
        guard recorded == identity else { throw unavailable() }
    }

    private func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    private func unavailable() -> StorageError {
        .unavailable(root.lastPathComponent)
    }

    /// Creates the key's folders below the root, never the root itself: a share that was unmounted must not be
    /// replaced by an empty local folder at its mount point.
    private func makeDirectories(for key: String) throws {
        try requireRoot()
        var dir = root
        for part in key.split(separator: "/").dropLast() {
            dir.appendPathComponent(String(part), isDirectory: true)
            if mkdir(dir.path, 0o755) != 0, errno != EEXIST { throw storageError(errno, key: key) }
        }
    }

    /// `notFound` only while the root is there; a missing root means the volume went away.
    private func storageError(_ code: Int32, key: String) -> StorageError {
        if code == ENOENT || code == ENOTDIR {
            do { try requireRoot() } catch let error as StorageError { return error } catch {}
            return .notFound(key)
        }
        return Self.storageError(code, key: key)
    }

    private func storageError(_ error: Error, key: String) -> StorageError {
        if let error = error as? StorageError { return error }
        if let code = Self.posixCode(of: error) { return storageError(code, key: key) }
        return .io(error.localizedDescription)
    }

    private func fileURL(for key: String) throws -> URL {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard !key.isEmpty, !key.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw StorageError.io("Invalid key: \(key)")
        }
        return root.appendingPathComponent(key)
    }

    private func writeNewFile(_ path: String, _ data: Data, key: String) throws -> Stamp {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw storageError(errno, key: key) }
        defer { close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw storageError(errno, key: key) }
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
        guard stat(path, &st) == 0 else { throw storageError(errno, key: key) }
        let stamp = Stamp(st)
        guard stamp.size <= Self.hashedSizeLimit else { return (stamp.etag, Int(stamp.size)) }
        // Files whose stat is unchanged reuse the cached hash instead of being re-read.
        if let cached = cacheLock.withLock({ hashCache[key] }), cached.stamp == stamp {
            return (cached.etag, Int(stamp.size))
        }
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw storageError(errno, key: key) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw storageError(errno, key: key) }
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            throw storageError(error, key: key)
        }
        cacheLock.withLock { _hashedFileReads += 1 }
        let openedStamp = Stamp(opened)
        return (etag(key: key, stamp: openedStamp, content: data), data.count)
    }

    /// Errors a network volume returns when its server is gone, asleep or unreachable.
    static let unreachableCodes: Set<Int32> = [ENOTCONN, ETIMEDOUT, ESTALE, EIO, ENXIO, EHOSTDOWN, EHOSTUNREACH,
                                               ENETDOWN, ENETUNREACH, ENODEV, ECONNRESET, ECONNABORTED, EAUTH, ENEEDAUTH]

    static func storageError(_ code: Int32, key: String) -> StorageError {
        let message = String(cString: strerror(code))
        return unreachableCodes.contains(code) ? .unavailable(message) : .io(message)
    }

    static func posixCode(of error: Error) -> Int32? {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    private struct RootIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
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
