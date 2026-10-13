import Foundation

public struct Manifest: Codable, Sendable, Equatable {
    public var formatVersion: Int
    /// nil means the store is plaintext.
    public var encryption: Encryption?
    public var createdAt: Date

    public struct Encryption: Codable, Sendable, Equatable {
        public var salt: Data
        public var iterations: Int
        /// `seal("inkwell-key-check", context: "manifest")` with the derived key; used to verify a passphrase.
        /// The plaintext keeps the legacy protocol name so existing manifests still verify.
        public var keyCheck: Data

        public init(salt: Data, iterations: Int, keyCheck: Data) {
            self.salt = salt
            self.iterations = iterations
            self.keyCheck = keyCheck
        }
    }

    public init(formatVersion: Int = 1, encryption: Encryption? = nil, createdAt: Date = Date()) {
        self.formatVersion = formatVersion
        self.encryption = encryption
        self.createdAt = createdAt
    }
}
