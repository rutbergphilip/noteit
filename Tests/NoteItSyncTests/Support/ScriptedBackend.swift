import Foundation
@testable import NoteItSync

/// A crash that aborts `sync()`: fatal to the pass, like a process dying mid-request. A fresh `SyncEngine` over the
/// same state file and backend then models the restart (web-app Task 0.4).
let testCrash = StorageError.unavailable("TestCrash")

/// One request as the engine sent it.
struct RecordedOp: Equatable, CustomStringConvertible {
    enum Kind: String { case list, get, put, delete }
    var kind: Kind
    var key: String
    var ifMatch: String?
    var ifNoneMatch = false

    var description: String {
        "\(kind.rawValue) \(key)" + (ifMatch.map { " If-Match:\($0)" } ?? "") + (ifNoneMatch ? " If-None-Match:*" : "")
    }

    var isConditional: Bool { ifMatch != nil || ifNoneMatch }
}

/// A request the test holds: the caller already saw a timeout, and `release()` applies it later, evaluating its
/// preconditions at that moment (a late-landing request).
final class HeldRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var work: (@Sendable () async throws -> Void)?
    private(set) var released = false

    var isArmed: Bool { lock.withLock { work != nil } }

    fileprivate func arm(_ work: @escaping @Sendable () async throws -> Void) {
        lock.withLock { self.work = work }
    }

    /// Applies the held request; returns its error (a 412 when its precondition no longer holds), if any.
    @discardableResult
    func release() async -> Error? {
        let pending: (@Sendable () async throws -> Void)? = lock.withLock {
            defer { work = nil; released = true }
            return work
        }
        guard let pending else { return nil }
        do {
            try await pending()
            return nil
        } catch {
            return error
        }
    }
}

/// Wraps an `InMemoryBackend`, records every request and injects the faults Task 0.4's tests need.
actor ScriptedBackend: StorageBackend {
    enum Fault {
        /// The request lands, then the caller crashes before seeing the response.
        case crashAfter
        /// The caller crashes while the request is out; it never lands.
        case crashDuring
        /// The caller sees a timeout; the request lands on `release()`.
        case hold(HeldRequest)
        /// The request lands, then the caller sees `.network` (a lost response).
        case landThenFail
        /// The request lands, then the caller sees 412 (an HTTP stack that silently replayed it).
        case replay412
        /// The caller sees `.network` and the request never lands.
        case failBefore
        /// Runs `action` against the store, then forwards the request.
        case before(@Sendable () async -> Void)
    }

    let inner: InMemoryBackend
    private(set) var ops: [RecordedOp] = []
    private var faults: [(kind: RecordedOp.Kind, pattern: String, fault: Fault)] = []
    private var snapshot: [RemoteObject]?
    private var serveStaleListOnce = false

    init(_ inner: InMemoryBackend) { self.inner = inner }

    /// Arms `fault` for the next `kind` request whose key contains `pattern`.
    func on(_ kind: RecordedOp.Kind, _ pattern: String, _ fault: Fault) {
        faults.append((kind, pattern, fault))
    }

    /// The next `list` returns the store as it was before the last applied write (a lagging listing).
    func staleListOnce() { serveStaleListOnce = true }

    func clearOps() { ops = [] }

    func ops(_ kind: RecordedOp.Kind, containing pattern: String = "") -> [RecordedOp] {
        ops.filter { $0.kind == kind && (pattern.isEmpty || $0.key.contains(pattern)) }
    }

    private func takeFault(_ kind: RecordedOp.Kind, _ key: String) -> Fault? {
        guard let index = faults.firstIndex(where: { $0.kind == kind && ($0.pattern.isEmpty || key.contains($0.pattern)) }) else { return nil }
        return faults.remove(at: index).fault
    }

    func list(prefix: String) async throws -> [RemoteObject] {
        ops.append(RecordedOp(kind: .list, key: prefix))
        if serveStaleListOnce, let snapshot {
            serveStaleListOnce = false
            return snapshot.filter { $0.key.hasPrefix(prefix) }
        }
        return try await inner.list(prefix: prefix)
    }

    func get(_ key: String) async throws -> (data: Data, etag: String) {
        ops.append(RecordedOp(kind: .get, key: key))
        return try await inner.get(key)
    }

    @discardableResult
    func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        ops.append(RecordedOp(kind: .put, key: key, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch))
        let inner = inner
        let apply: @Sendable () async throws -> String = { try await inner.put(key, data: data, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch) }
        return try await run(.put, key, apply)
    }

    func delete(_ key: String) async throws {
        ops.append(RecordedOp(kind: .delete, key: key))
        let inner = inner
        _ = try await run(.delete, key) { try await inner.delete(key); return "" }
    }

    func delete(_ key: String, ifMatch: String?) async throws {
        guard let ifMatch else { return try await delete(key) }
        ops.append(RecordedOp(kind: .delete, key: key, ifMatch: ifMatch))
        let inner = inner
        _ = try await run(.delete, key) { try await inner.delete(key, ifMatch: ifMatch); return "" }
    }

    private func run(_ kind: RecordedOp.Kind, _ key: String, _ apply: @escaping @Sendable () async throws -> String) async throws -> String {
        let fault = takeFault(kind, key)
        if case .crashDuring = fault { throw testCrash }
        if case .failBefore = fault { throw StorageError.network("injected before \(key)") }
        if case .hold(let held) = fault {
            held.arm { _ = try await apply() }
            throw StorageError.network("timed out: \(key)")
        }
        if case .before(let action) = fault { await action() }
        snapshot = try await inner.list(prefix: "")
        let result = try await apply()
        switch fault {
        case .crashAfter?: throw testCrash
        case .landThenFail?: throw StorageError.network("response lost: \(key)")
        case .replay412?: throw StorageError.preconditionFailed(key)
        default: return result
        }
    }

    func probe() async throws {}

    func atomicConditionalWrites() async -> Bool { await inner.atomicConditionalWrites() }
    func atomicConditionalDelete() async -> Bool { await inner.atomicConditionalDelete() }
}
