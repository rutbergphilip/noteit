import CryptoKit
import Foundation

/// A data key wrapped with a passphrase (program §4). Declared by foundations step 3; sync-security's passphrase
/// change and rekey write new ones.
public struct Keyring: Codable, Equatable, Sendable {
    /// `KeyIdentity.keyID(for:)` of the wrapped key; 16 hex chars.
    public var keyID: String
    public var kdf: String
    public var salt: Data
    public var iterations: Int
    /// AES-GCM combined (nonce | ciphertext | tag) of the data key, with aad `keyring/<keyID>`.
    public var wrappedKey: Data
    public var changedAt: Date
    public var changedBy: String

    public static let defaultIterations = 600_000
    public static let pbkdf2SHA256 = "pbkdf2-sha256"

    public init(keyID: String, kdf: String, salt: Data, iterations: Int, wrappedKey: Data, changedAt: Date, changedBy: String) {
        self.keyID = keyID
        self.kdf = kdf
        self.salt = salt
        self.iterations = iterations
        self.wrappedKey = wrappedKey
        self.changedAt = changedAt
        self.changedBy = changedBy
    }

    /// Wraps a 32-byte data key. The passphrase is NFC-normalised (program §4 rule 12); an empty one throws
    /// `passphraseRequired` before anything is derived.
    public static func make(dataKey: SymmetricKey, passphrase: String, deviceName: String, now: Date,
                            iterations: Int = defaultIterations) throws -> Keyring {
        try make(dataKey: dataKey, passphrase: passphrase, deviceName: deviceName, now: now, iterations: iterations,
                 salt: KeyDerivation.randomSalt(), nonce: AES.GCM.Nonce())
    }

    /// `make` with a fixed salt and nonce, for golden vectors.
    static func make(dataKey: SymmetricKey, passphrase: String, deviceName: String, now: Date, iterations: Int,
                     salt: Data, nonce: AES.GCM.Nonce) throws -> Keyring {
        let normalized = KeyDerivation.normalized(passphrase)
        guard !normalized.isEmpty else { throw SyncError.passphraseRequired }
        guard SyncEngine.iterationRange.contains(iterations) else {
            throw SyncError.invalidManifest("keyring iterations \(iterations) outside \(SyncEngine.iterationRange)")
        }
        guard dataKey.bitCount == 256 else { throw SyncError.invalidManifest("data key is not 32 bytes") }
        let keyID = KeyIdentity.keyID(for: dataKey)
        let kek = try KeyDerivation.checkedKey(passphrase: normalized, salt: salt, iterations: iterations)
        let keyBytes = dataKey.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(keyBytes, using: kek, nonce: nonce, authenticating: aad(keyID))
        return Keyring(keyID: keyID, kdf: pbkdf2SHA256, salt: salt, iterations: iterations, wrappedKey: sealed.combined!,
                       changedAt: now, changedBy: deviceName)
    }

    /// Throws `wrongPassphrase` when the passphrase doesn't open the wrapped key.
    public func unwrap(passphrase: String) throws -> SymmetricKey {
        let normalized = KeyDerivation.normalized(passphrase)
        guard !normalized.isEmpty else { throw SyncError.passphraseRequired }
        guard kdf == Self.pbkdf2SHA256 else { throw SyncError.invalidManifest("unknown keyring kdf \(kdf)") }
        guard SyncEngine.iterationRange.contains(iterations) else {
            throw SyncError.invalidManifest("keyring iterations \(iterations) outside \(SyncEngine.iterationRange)")
        }
        guard !salt.isEmpty else { throw SyncError.invalidManifest("keyring salt is empty") }
        let kek = try KeyDerivation.checkedKey(passphrase: normalized, salt: salt, iterations: iterations)
        let opened: Data
        do {
            opened = try AES.GCM.open(AES.GCM.SealedBox(combined: wrappedKey), using: kek, authenticating: Self.aad(keyID))
        } catch {
            throw SyncError.wrongPassphrase
        }
        let key = SymmetricKey(data: opened)
        guard opened.count == 32, KeyIdentity.keyID(for: key) == keyID else {
            throw SyncError.invalidManifest("keyring key doesn't match its keyID")
        }
        return key
    }

    /// The same data key under a new passphrase; `keyID` is unchanged.
    public func rewrapped(dataKey: SymmetricKey, newPassphrase: String, deviceName: String, now: Date) throws -> Keyring {
        guard !KeyDerivation.normalized(newPassphrase).isEmpty else { throw SyncError.passphraseRequired }
        guard KeyIdentity.keyID(for: dataKey) == keyID else { throw SyncError.invalidManifest("data key doesn't match keyring") }
        return try Self.make(dataKey: dataKey, passphrase: newPassphrase, deviceName: deviceName, now: now,
                             iterations: max(iterations, Self.defaultIterations))
    }

    static func aad(_ keyID: String) -> Data {
        Data("keyring/\(keyID)".utf8)
    }
}

/// The manifest field that is set exactly while a rekey runs (program §4). Declared by foundations step 3; only
/// sync-security's rekey writes it.
public struct Rekey: Codable, Equatable, Sendable {
    /// nil: the store was unencrypted.
    public var fromKeyID: String?
    public var toKeyID: String
    public var startedAt: Date
    public var updatedAt: Date
    public var deviceID: String
    public var deviceName: String
    /// The keyring the rekey replaced, kept until it finishes.
    public var previousKeyring: Keyring?
    /// The v1 block the rekey replaced, kept until it finishes.
    public var previousEncryption: Manifest.Encryption?

    /// A rekey whose `updatedAt` is at least this old is stale (its runner stopped).
    public static let staleAfter: TimeInterval = 3600

    public init(fromKeyID: String?, toKeyID: String, startedAt: Date, updatedAt: Date, deviceID: String, deviceName: String,
                previousKeyring: Keyring? = nil, previousEncryption: Manifest.Encryption? = nil) {
        self.fromKeyID = fromKeyID
        self.toKeyID = toKeyID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.previousKeyring = previousKeyring
        self.previousEncryption = previousEncryption
    }

    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) >= Self.staleAfter
    }
}

/// Stable identifiers for store keys (foundations step 3).
public enum KeyIdentity {
    /// SHA256("noteit-key-id" || key), first 8 bytes as lowercase hex.
    public static func keyID(for key: SymmetricKey) -> String {
        hex8(Data("noteit-key-id".utf8) + key.withUnsafeBytes { Data($0) })
    }

    /// SHA256("noteit-legacy-key" || salt || iterations as 4-byte big-endian || keyCheck), first 8 bytes as hex.
    public static func legacyKeyID(_ encryption: Manifest.Encryption) -> String {
        let iterations = UInt32(truncatingIfNeeded: encryption.iterations).bigEndian
        let iterationBytes = withUnsafeBytes(of: iterations) { Data($0) }
        return hex8(Data("noteit-legacy-key".utf8) + encryption.salt + iterationBytes + encryption.keyCheck)
    }

    private static func hex8(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// What opens a store (foundations step 3).
public enum StoreCredential: Sendable {
    case passphrase(String)
    case dataKey(SymmetricKey)
}
