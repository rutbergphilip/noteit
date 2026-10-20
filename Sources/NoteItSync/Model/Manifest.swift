import Foundation

/// The store's `manifest.json`. foundations step 3 adds `features`, `keyring` and `rekey` (program §4); every new
/// field is optional, so v1 manifests decode and re-encode unchanged.
public struct Manifest: Codable, Sendable, Equatable {
    /// 1, or 2 whenever `features` is non-empty.
    public var formatVersion: Int
    /// nil means the store is plaintext, or a keyring store (then `keyring` is set).
    public var encryption: Encryption?
    /// `StoreFeature` raw values; encoded sorted.
    public var features: [String]?
    public var keyring: Keyring?
    /// A field, not a feature: set exactly while a rekey runs.
    public var rekey: Rekey?
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

    public init(formatVersion: Int = 1, encryption: Encryption? = nil, createdAt: Date = Date(),
                features: [String]? = nil, keyring: Keyring? = nil, rekey: Rekey? = nil) {
        self.formatVersion = formatVersion
        self.encryption = encryption
        self.features = features
        self.keyring = keyring
        self.rekey = rekey
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion, encryption, features, keyring, rekey, createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encodeIfPresent(encryption, forKey: .encryption)
        try c.encodeIfPresent(features?.sorted(), forKey: .features)
        try c.encodeIfPresent(keyring, forKey: .keyring)
        try c.encodeIfPresent(rekey, forKey: .rekey)
        try c.encode(createdAt, forKey: .createdAt)
    }
}
