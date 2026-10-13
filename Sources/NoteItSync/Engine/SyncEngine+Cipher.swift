import Foundation

extension SyncEngine {
    typealias CipherFactory = @Sendable (_ passphrase: String, _ salt: Data, _ iterations: Int) throws -> SyncCipher

    static let defaultCipherFactory: CipherFactory = { passphrase, salt, iterations in
        AESGCMCipher(key: try KeyDerivation.checkedKey(passphrase: passphrase, salt: salt, iterations: iterations))
    }

    static func plaintextCipher() -> SyncCipher {
        PassthroughCipher()
    }

    static func makeSalt() -> Data {
        KeyDerivation.randomSalt()
    }
}
