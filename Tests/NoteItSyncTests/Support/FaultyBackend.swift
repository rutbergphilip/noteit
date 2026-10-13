import Foundation
@testable import NoteItSync

/// Wraps an `InMemoryBackend` to inject faults at precise points of a pass.
actor FaultyBackend: StorageBackend {
    enum Fault {
        /// The put never reaches storage.
        case failBefore
        /// The put is stored but the caller sees an error (a crash right after the write).
        case failAfter
        /// Runs `action` against the real storage, then forwards the put.
        case before(@Sendable () async -> Void)
    }

    let inner: InMemoryBackend
    private var putFaults: [(fragment: String, fault: Fault)] = []
    private var deleteFaults: [(fragment: String, fault: Fault)] = []
    private var ignoreDeleteConditions = false
    private var getError: StorageError?

    init(_ inner: InMemoryBackend) { self.inner = inner }

    /// Arms `fault` for the next put whose key contains `fragment`.
    func onNextPut(keyContaining fragment: String, _ fault: Fault) { putFaults.append((fragment, fault)) }
    /// Arms `fault` for the next delete whose key contains `fragment`.
    func onNextDelete(keyContaining fragment: String, _ fault: Fault) { deleteFaults.append((fragment, fault)) }
    /// Simulates a provider that accepts but ignores `If-Match` on deletes.
    func ignoreDeleteIfMatch() { ignoreDeleteConditions = true }
    func rejectGets(with error: StorageError = .unauthorized("denied")) { getError = error }

    func list(prefix: String) async throws -> [RemoteObject] { try await inner.list(prefix: prefix) }

    func get(_ key: String) async throws -> (data: Data, etag: String) {
        if let getError { throw getError }
        return try await inner.get(key)
    }

    @discardableResult
    func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        if let index = putFaults.firstIndex(where: { key.contains($0.fragment) }) {
            let fault = putFaults.remove(at: index).fault
            switch fault {
            case .failBefore:
                throw StorageError.network("injected before \(key)")
            case .failAfter:
                try await inner.put(key, data: data, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
                throw StorageError.network("injected after \(key)")
            case .before(let action):
                await action()
            }
        }
        return try await inner.put(key, data: data, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
    }

    func delete(_ key: String) async throws { try await delete(key, ifMatch: nil) }

    func delete(_ key: String, ifMatch: String?) async throws {
        if let index = deleteFaults.firstIndex(where: { key.contains($0.fragment) }) {
            switch deleteFaults.remove(at: index).fault {
            case .failBefore:
                throw StorageError.network("injected before deleting \(key)")
            case .failAfter:
                try await inner.delete(key, ifMatch: ifMatch)
                throw StorageError.network("injected after deleting \(key)")
            case .before(let action):
                await action()
            }
        }
        try await inner.delete(key, ifMatch: ignoreDeleteConditions ? nil : ifMatch)
    }
    func probe() async throws {}
}
