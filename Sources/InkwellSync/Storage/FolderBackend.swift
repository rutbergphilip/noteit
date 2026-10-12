import Foundation

/// Stores objects as files under a root directory (NAS mount, iCloud Drive, Dropbox, ...).
public final class FolderBackend: StorageBackend, @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let fileManager = FileManager.default

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
            guard key.hasPrefix(prefix), let info = try? fileInfo(at: path) else { continue }
            objects.append(RemoteObject(key: key, etag: info.etag, size: info.size))
        }
        return objects.sorted { $0.key < $1.key }
    }

    public func get(_ key: String) async throws -> (data: Data, etag: String) {
        let url = try fileURL(for: key)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if !fileManager.fileExists(atPath: url.path) { throw StorageError.notFound(key) }
            throw StorageError.io(error.localizedDescription)
        }
        return (data, try etag(for: key, at: url))
    }

    @discardableResult
    public func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        let url = try fileURL(for: key)
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: temp)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw StorageError.io(error.localizedDescription)
        }

        return try lock.withLock {
            // Preconditions are only enforced within this process; across machines this is best effort.
            let current = try? fileInfo(at: url.path).etag
            if (ifNoneMatch && current != nil) || (ifMatch != nil && current != ifMatch) {
                try? fileManager.removeItem(at: temp)
                throw StorageError.preconditionFailed(key)
            }
            guard rename(temp.path, url.path) == 0 else {
                let message = String(cString: strerror(errno))
                try? fileManager.removeItem(at: temp)
                throw StorageError.io(message)
            }
            return try etag(for: key, at: url)
        }
    }

    public func delete(_ key: String) async throws {
        let url = try fileURL(for: key)
        guard unlink(url.path) == 0 else {
            if errno == ENOENT { throw StorageError.notFound(key) }
            throw StorageError.io(String(cString: strerror(errno)))
        }
    }

    public func probe() async throws {
        try requireRoot()
        let url = root.appendingPathComponent(".inkwell-probe")
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

    private func etag(for key: String, at url: URL) throws -> String {
        do {
            return try fileInfo(at: url.path).etag
        } catch StorageError.notFound {
            throw StorageError.notFound(key)
        }
    }

    private func fileInfo(at path: String) throws -> (etag: String, size: Int) {
        var st = stat()
        guard stat(path, &st) == 0 else {
            if errno == ENOENT { throw StorageError.notFound(path) }
            throw StorageError.io(String(cString: strerror(errno)))
        }
        let mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return ("\(mtimeNs)-\(st.st_size)", Int(st.st_size))
    }
}
