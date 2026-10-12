import CryptoKit
import Foundation
@testable import InkwellSync

/// Deterministic keystream XOR keyed by SHA-256(passphrase|salt|context). Not secure; it only makes bytes unreadable,
/// makes a wrong passphrase fail the manifest key check and makes a wrong context produce garbage.
struct XORTestCipher: SyncCipher {
    let key: [UInt8]

    init(passphrase: String, salt: Data) {
        key = Array(SHA256.hash(data: Data(passphrase.utf8) + Data("|".utf8) + salt))
    }

    func seal(_ plain: Data, context: String) throws -> Data { transform(plain, context) }
    func open(_ sealed: Data, context: String) throws -> Data { transform(sealed, context) }

    private func transform(_ data: Data, _ context: String) -> Data {
        let key = Array(SHA256.hash(data: Data(self.key) + Data("|\(context)".utf8)))
        var out = [UInt8](data)
        for i in out.indices { out[i] ^= key[i % key.count] &+ UInt8(truncatingIfNeeded: i / key.count) }
        return Data(out)
    }

    static let factory: SyncEngine.CipherFactory = { passphrase, salt, _ in XORTestCipher(passphrase: passphrase, salt: salt) }
}

struct TestPassthroughCipher: SyncCipher {
    func seal(_ plain: Data, context: String) throws -> Data { plain }
    func open(_ sealed: Data, context: String) throws -> Data { sealed }
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
