import Foundation

extension SyncEngine {
    typealias CipherFactory = @Sendable (_ passphrase: String, _ salt: Data, _ iterations: Int) -> SyncCipher

    static let defaultCipherFactory: CipherFactory = { passphrase, salt, iterations in
        AESGCMCipher(key: KeyDerivation.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations))
    }

    static func plaintextCipher() -> SyncCipher {
        PassthroughCipher()
    }

    static func makeSalt() -> Data {
        KeyDerivation.randomSalt()
    }
}
