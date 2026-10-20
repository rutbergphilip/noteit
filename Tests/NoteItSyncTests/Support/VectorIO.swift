import CryptoKit
import Foundation
import NoteItDocTestSupport
import XCTest
@testable import NoteItSync

/// Golden vector files for the v1 store format (foundations Task 2.4). With `NOTEIT_WRITE_VECTORS=1` the generated
/// cases are written; otherwise the committed file is loaded and must equal what the current engine generates.
enum VectorIO {
    static func check<Case: Codable & Equatable>(_ name: String, _ cases: [Case], file: StaticString = #filePath, line: UInt = #line) throws {
        if GoldenFixtures.isWriting {
            try GoldenFixtures.write(GoldenFile(generator: "swift", cases: cases), to: name)
            return
        }
        let stored = try load(name, as: Case.self)
        XCTAssertEqual(stored.count, cases.count, "\(name): case count", file: file, line: line)
        for (index, (expected, actual)) in zip(stored, cases).enumerated() where expected != actual {
            XCTFail("\(name) case \(index):\n  stored    \(expected)\n  generated \(actual)", file: file, line: line)
            return
        }
    }

    static func load<Case: Codable>(_ name: String, as: Case.Type) throws -> [Case] {
        let stored = try GoldenFixtures.load(name, as: GoldenFile<Case>.self)
        XCTAssertEqual(stored.generator, "swift")
        XCTAssertEqual(stored.version, 1)
        return stored.cases
    }

    // MARK: Fixed values

    /// 2026-01-01T00:00:00Z.
    static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(iso string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// A stable UUID for a vector label, so files never depend on `UUID()`.
    static func uuid(_ label: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("noteit-vector|\(label)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func bytes(_ label: String, count: Int) -> Data {
        var out = Data()
        var counter = 0
        while out.count < count {
            out.append(contentsOf: SHA256.hash(data: Data("noteit-bytes|\(label)|\(counter)".utf8)))
            counter += 1
        }
        return out.prefix(count)
    }

    static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

/// AES-GCM in `AESGCMCipher`'s layout, with nonces derived from the key, context and plaintext instead of random
/// ones, so generated stores are byte-stable. `AESGCMCipher` opens its output. For vectors only: a real store must
/// never reuse nonces like this.
struct DeterministicAESCipher: SyncCipher {
    let key: SymmetricKey

    func seal(_ plain: Data, context: String) throws -> Data {
        try Self.seal(plain, key: key, nonce: nonce(plain, context), context: context)
    }

    func open(_ sealed: Data, context: String) throws -> Data {
        try AESGCMCipher(key: key).open(sealed, context: context)
    }

    func nonce(_ plain: Data, _ context: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(context.utf8) + Data([0]) + plain, using: key)).prefix(12)
    }

    static func seal(_ plain: Data, key: SymmetricKey, nonce: Data, context: String) throws -> Data {
        try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: Data(context.utf8)).combined!
    }
}

/// An in-memory backend whose etags are a hash of key and bytes, so a store written twice gets the same etags.
actor VectorBackend: StorageBackend {
    private var storage: [String: (data: Data, etag: String)] = [:]

    func seed(_ key: String, data: Data, etag: String) {
        storage[key] = (data, etag)
    }

    func objects() -> [(key: String, etag: String, data: Data)] {
        storage.keys.sorted().map { (key: $0, etag: storage[$0]!.etag, data: storage[$0]!.data) }
    }

    func list(prefix: String) async throws -> [RemoteObject] {
        storage.filter { $0.key.hasPrefix(prefix) }
            .map { RemoteObject(key: $0.key, etag: $0.value.etag, size: $0.value.data.count) }
            .sorted { $0.key < $1.key }
    }

    func get(_ key: String) async throws -> (data: Data, etag: String) {
        guard let object = storage[key] else { throw StorageError.notFound(key) }
        return (object.data, object.etag)
    }

    @discardableResult
    func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        let current = storage[key]?.etag
        if ifNoneMatch, current != nil { throw StorageError.preconditionFailed(key) }
        if let ifMatch, current != ifMatch { throw StorageError.preconditionFailed(key) }
        let etag = SyncEngine.sha256Hex(Data(key.utf8) + Data([0]) + data).prefix(32).description
        storage[key] = (data, etag)
        return etag
    }

    func delete(_ key: String) async throws {
        try await delete(key, ifMatch: nil)
    }

    func delete(_ key: String, ifMatch: String?) async throws {
        guard let current = storage[key]?.etag else { throw StorageError.notFound(key) }
        if let ifMatch, current != ifMatch { throw StorageError.preconditionFailed(key) }
        storage[key] = nil
    }

    func probe() async throws {}
}

/// A clock that only moves when told to.
final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); current += seconds; lock.unlock()
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

/// A `SyncLocalStore` holding raw payloads: it exports what it was given and records what the engine applies.
actor RecordingLocalStore: SyncLocalStore {
    private(set) var payloads: [UUID: RecordPayload] = [:]
    private var journal: [UUID: LocalDeletion] = [:]

    init(payloads: [RecordPayload] = [], deletions: [UUID: LocalDeletion] = [:]) {
        self.payloads = Dictionary(uniqueKeysWithValues: payloads.map { ($0.id, $0) })
        journal = deletions
    }

    func records() -> [LocalRecord] {
        payloads.values.map { LocalRecord(id: $0.id, kind: $0.kind, revision: $0.revision, modifiedAt: $0.modifiedAt) }
    }

    func deletions() -> [UUID: LocalDeletion] { journal }

    func export(_ id: UUID, kind: RecordKind) throws -> RecordPayload {
        guard let payload = payloads[id], payload.kind == kind else { throw StorageError.notFound("local \(id)") }
        return payload
    }

    func apply(_ payload: RecordPayload) { payloads[payload.id] = payload }

    func applyDeletion(_ id: UUID, kind: RecordKind) { payloads[id] = nil }

    func importConflictCopy(_ payload: RecordPayload, fromDevice name: String) {
        XCTFail("Unexpected conflict copy of \(payload.id) from \(name)")
    }

    func clearDeletion(_ id: UUID) { journal[id] = nil }
}
