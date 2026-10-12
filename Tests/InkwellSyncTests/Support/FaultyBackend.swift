import Foundation
@testable import InkwellSync

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
    private var unauthorizedGets = false

    init(_ inner: InMemoryBackend) { self.inner = inner }

    /// Arms `fault` for the next put whose key contains `fragment`.
    func onNextPut(keyContaining fragment: String, _ fault: Fault) { putFaults.append((fragment, fault)) }
    func rejectGets() { unauthorizedGets = true }

    func list(prefix: String) async throws -> [RemoteObject] { try await inner.list(prefix: prefix) }

    func get(_ key: String) async throws -> (data: Data, etag: String) {
        if unauthorizedGets { throw StorageError.unauthorized("denied") }
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

    func delete(_ key: String) async throws { try await inner.delete(key) }
    func probe() async throws {}
}
