import CryptoKit
import Foundation

public protocol SyncCipher: Sendable {
    func seal(_ plain: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
}

public struct PassthroughCipher: SyncCipher {
    public init() {}

    public func seal(_ plain: Data) throws -> Data { plain }
    public func open(_ sealed: Data) throws -> Data { sealed }
}

/// Output layout: nonce (12) | ciphertext | tag (16).
public struct AESGCMCipher: SyncCipher {
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    public func seal(_ plain: Data) throws -> Data {
        // combined is non-nil for the default 12-byte nonce.
        try AES.GCM.seal(plain, using: key).combined!
    }

    public func open(_ sealed: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }
}
