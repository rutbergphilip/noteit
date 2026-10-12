import Foundation

/// Process-local backend for tests and development. Etags are fresh UUIDs on every write.
public actor InMemoryBackend: StorageBackend {
    private var storage: [String: (Data, String)] = [:]
    private var pendingPutFailures = 0

    public private(set) var listCount = 0
    public private(set) var getCount = 0
    public private(set) var putCount = 0
    public private(set) var deleteCount = 0

    public init() {}

    /// Makes the next `n` calls to `put` throw `.network`.
    public func failNextPuts(_ n: Int) {
        pendingPutFailures = max(0, n)
    }

    public func list(prefix: String) async throws -> [RemoteObject] {
        listCount += 1
        return storage
            .filter { $0.key.hasPrefix(prefix) }
            .map { RemoteObject(key: $0.key, etag: $0.value.1, size: $0.value.0.count) }
            .sorted { $0.key < $1.key }
    }

    public func get(_ key: String) async throws -> (data: Data, etag: String) {
        getCount += 1
        guard let (data, etag) = storage[key] else { throw StorageError.notFound(key) }
        return (data, etag)
    }

    @discardableResult
    public func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        putCount += 1
        if pendingPutFailures > 0 {
            pendingPutFailures -= 1
            throw StorageError.network("Simulated failure for \(key)")
        }
        let current = storage[key]?.1
        if ifNoneMatch, current != nil {
            throw StorageError.preconditionFailed(key)
        }
        if let ifMatch, current != ifMatch {
            throw StorageError.preconditionFailed(key)
        }
        let etag = UUID().uuidString
        storage[key] = (data, etag)
        return etag
    }

    public func delete(_ key: String) async throws {
        deleteCount += 1
        guard storage.removeValue(forKey: key) != nil else { throw StorageError.notFound(key) }
    }

    public func probe() async throws {}
}
