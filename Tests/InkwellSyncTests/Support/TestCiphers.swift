import CryptoKit
import Foundation
@testable import InkwellSync

/// Deterministic keystream XOR keyed by SHA-256(passphrase|salt). Not secure; it only makes bytes unreadable
/// and makes a wrong passphrase fail the manifest key check.
struct XORTestCipher: SyncCipher {
    let key: [UInt8]

    init(passphrase: String, salt: Data) {
        key = Array(SHA256.hash(data: Data(passphrase.utf8) + Data("|".utf8) + salt))
    }

    func seal(_ plain: Data) throws -> Data { transform(plain) }
    func open(_ sealed: Data) throws -> Data { transform(sealed) }

    private func transform(_ data: Data) -> Data {
        var out = [UInt8](data)
        for i in out.indices { out[i] ^= key[i % key.count] &+ UInt8(truncatingIfNeeded: i / key.count) }
        return Data(out)
    }

    static let factory: SyncEngine.CipherFactory = { passphrase, salt, _ in XORTestCipher(passphrase: passphrase, salt: salt) }
}

struct TestPassthroughCipher: SyncCipher {
    func seal(_ plain: Data) throws -> Data { plain }
    func open(_ sealed: Data) throws -> Data { sealed }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    func advance(_ seconds: TimeInterval) {
        lock.lock(); offset += seconds; lock.unlock()
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return Date().addingTimeInterval(offset)
    }
}
