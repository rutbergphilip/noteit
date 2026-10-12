import Foundation

// The only place `connect` learns how to turn a passphrase into a cipher.
// After T2 merges: make `defaultCipherFactory` return
// `AESGCMCipher(key: KeyDerivation.deriveKey(passphrase: $0, salt: $1, iterations: $2))`,
// make `plaintextCipher()` return `PassthroughCipher()`, delete `PlaintextCipher`,
// and optionally make `makeSalt()` return `KeyDerivation.randomSalt()`.
extension SyncEngine {
    typealias CipherFactory = @Sendable (_ passphrase: String, _ salt: Data, _ iterations: Int) -> SyncCipher

    static let defaultCipherFactory: CipherFactory = { _, _, _ in
        fatalError("SyncEngine.connect requires T2 (AESGCMCipher + KeyDerivation)")
    }

    static func plaintextCipher() -> SyncCipher {
        PlaintextCipher()
    }

    static func makeSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

struct PlaintextCipher: SyncCipher {
    func seal(_ plain: Data) throws -> Data { plain }
    func open(_ sealed: Data) throws -> Data { sealed }
}
