import Foundation

/// Process-local backend for tests and development. Etags are fresh UUIDs on every write (or `etag-<n>` with
/// `sequentialETags`, so traces are reproducible).
///
/// `atomic` and `atomicDelete` model the two capabilities (sync-security Task 3.0). With `atomic: false` a
/// conditional write is a check, then the `betweenCheckAndWrite` hook, then an unconditional write, as with the
/// HEAD-verify fallback; with `atomicDelete: false`, `delete(_:ifMatch:)` with an ETag sends nothing and throws
/// `conditionalDeleteUnsupported`.
public actor InMemoryBackend: StorageBackend {
    private var storage: [String: (data: Data, etag: String, written: Date)] = [:]
    private var pendingPutFailures = 0
    private let atomic: Bool
    private let atomicDelete: Bool
    private let sequentialETags: Bool
    private var etagCounter = 0
    private var clock: @Sendable () -> Date
    private var betweenCheckAndWrite: (@Sendable (String) async -> Void)?
    /// When true, `list` reports no `lastModified` (a provider that doesn't list it).
    private var hidesLastModified = false

    public private(set) var listCount = 0
    public private(set) var getCount = 0
    public private(set) var putCount = 0
    public private(set) var deleteCount = 0

    public init(atomic: Bool = true, atomicDelete: Bool = true, sequentialETags: Bool = false,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.atomic = atomic
        self.atomicDelete = atomicDelete
        self.sequentialETags = sequentialETags
        self.clock = now
    }

    /// Makes the next `n` calls to `put` throw `.network`.
    public func failNextPuts(_ n: Int) {
        pendingPutFailures = max(0, n)
    }

    /// Runs between the check and the write of every conditional `put` on a non-atomic backend.
    public func setBetweenCheckAndWrite(_ hook: (@Sendable (String) async -> Void)?) {
        betweenCheckAndWrite = hook
    }

    public func setClock(_ now: @escaping @Sendable () -> Date) {
        clock = now
    }

    public func setHidesLastModified(_ hides: Bool) {
        hidesLastModified = hides
    }

    /// The stored bytes and etag, without counting a request.
    public func object(_ key: String) -> (data: Data, etag: String)? {
        storage[key].map { ($0.data, $0.etag) }
    }

    /// Replaces an object as another writer would, without preconditions (tests only).
    @discardableResult
    public func overwrite(_ key: String, data: Data) -> String {
        let etag = nextETag()
        storage[key] = (data, etag, clock())
        return etag
    }

    /// Restores an object exactly, ETag included (tests that copy old ciphertext back, ABA).
    public func restore(_ key: String, data: Data, etag: String) {
        storage[key] = (data, etag, clock())
    }

    public func list(prefix: String) async throws -> [RemoteObject] {
        listCount += 1
        return storage
            .filter { $0.key.hasPrefix(prefix) }
            .map { RemoteObject(key: $0.key, etag: $0.value.etag, size: $0.value.data.count,
                                lastModified: hidesLastModified ? nil : $0.value.written) }
            .sorted { $0.key < $1.key }
    }

    public func get(_ key: String) async throws -> (data: Data, etag: String) {
        getCount += 1
        guard let object = storage[key] else { throw StorageError.notFound(key) }
        return (object.data, object.etag)
    }

    @discardableResult
    public func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        putCount += 1
        if pendingPutFailures > 0 {
            pendingPutFailures -= 1
            throw StorageError.network("Simulated failure for \(key)")
        }
        try checkPreconditions(key, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
        if !atomic, ifMatch != nil || ifNoneMatch, let hook = betweenCheckAndWrite {
            // The fallback's window: anything may land here, and the write below doesn't look again.
            await hook(key)
        } else if atomic {
            try checkPreconditions(key, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
        }
        let etag = nextETag()
        storage[key] = (data, etag, clock())
        return etag
    }

    public func delete(_ key: String) async throws {
        deleteCount += 1
        guard storage[key] != nil else { throw StorageError.notFound(key) }
        storage[key] = nil
    }

    public func delete(_ key: String, ifMatch: String?) async throws {
        guard let ifMatch else { return try await delete(key) }
        guard atomicDelete else { throw StorageError.conditionalDeleteUnsupported(key) }
        deleteCount += 1
        guard let current = storage[key]?.etag else { throw StorageError.notFound(key) }
        if current != ifMatch { throw StorageError.preconditionFailed(key) }
        storage[key] = nil
    }

    public func probe() async throws {}

    public func atomicConditionalWrites() async -> Bool { atomic }
    public func atomicConditionalDelete() async -> Bool { atomicDelete }

    private func checkPreconditions(_ key: String, ifMatch: String?, ifNoneMatch: Bool) throws {
        let current = storage[key]?.etag
        if ifNoneMatch, current != nil { throw StorageError.preconditionFailed(key) }
        if let ifMatch, current != ifMatch { throw StorageError.preconditionFailed(key) }
    }

    private func nextETag() -> String {
        guard sequentialETags else { return UUID().uuidString }
        etagCounter += 1
        return "etag-\(etagCounter)"
    }
}
