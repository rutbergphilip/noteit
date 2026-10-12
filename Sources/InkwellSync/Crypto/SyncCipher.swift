import CryptoKit
import Foundation

/// `context` is the object key relative to the remote root (e.g. `notes/<id>.meta`); ciphers that
/// authenticate bind the ciphertext to it so an object can't be replayed under another key.
public protocol SyncCipher: Sendable {
    func seal(_ plain: Data, context: String) throws -> Data
    func open(_ sealed: Data, context: String) throws -> Data
}

public struct PassthroughCipher: SyncCipher {
    public init() {}

    public func seal(_ plain: Data, context: String) throws -> Data { plain }
    public func open(_ sealed: Data, context: String) throws -> Data { sealed }
}

/// Output layout: nonce (12) | ciphertext | tag (16). The context is authenticated as AAD.
public struct AESGCMCipher: SyncCipher {
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    public func seal(_ plain: Data, context: String) throws -> Data {
        // combined is non-nil for the default 12-byte nonce.
        try AES.GCM.seal(plain, using: key, authenticating: Data(context.utf8)).combined!
    }

    public func open(_ sealed: Data, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data(context.utf8))
    }
}
