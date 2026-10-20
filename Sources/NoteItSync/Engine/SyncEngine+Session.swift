import CryptoKit
import Foundation

extension SyncEngine {
    /// Opens (or, with `createIfMissing`, creates) a store and returns its session (foundations step 3).
    /// deviceName: written as `Keyring.changedBy` when this call creates a keyring store; unused otherwise.
    /// initialFeatures: written into the first manifest only when this call creates the store.
    /// supported: the features this session accepts, kept as `StoreSession.supported`.
    /// cipher: when non-nil, the session uses it instead of building a cipher (sharing passes its space cipher).
    public static func connectSession(backend: StorageBackend, kind: StoreSessionKind, credential: StoreCredential?,
                                      deviceName: String, createIfMissing: Bool, encrypted: Bool,
                                      initialFeatures: Set<StoreFeature> = [],
                                      supported: Set<StoreFeature> = StoreFeature.supported,
                                      cipher: (any SyncCipher)? = nil) async throws -> (session: StoreSession, created: Bool) {
        try await connectSession(backend: backend, kind: kind, credential: credential, deviceName: deviceName,
                                 createIfMissing: createIfMissing, encrypted: encrypted, initialFeatures: initialFeatures,
                                 supported: supported, cipher: cipher, makeCipher: defaultCipherFactory, now: Date())
    }

    static func connectSession(backend: StorageBackend, kind: StoreSessionKind, credential: StoreCredential?,
                               deviceName: String, createIfMissing: Bool, encrypted: Bool,
                               initialFeatures: Set<StoreFeature> = [], supported: Set<StoreFeature> = StoreFeature.supported,
                               cipher: (any SyncCipher)? = nil, makeCipher: CipherFactory, now: Date) async throws
        -> (session: StoreSession, created: Bool) {
        if cipher != nil, !encrypted { throw SyncError.invalidManifest("a passed cipher needs an encrypted store") }
        func open(_ manifest: Manifest, _ etag: String) throws -> StoreSession {
            try openSession(manifest, etag: etag, kind: kind, credential: credential, encrypted: encrypted,
                            supported: supported, passedCipher: cipher, makeCipher: makeCipher)
        }
        if let (manifest, etag) = try await readManifestAndETag(backend) {
            return (try open(manifest, etag), false)
        }
        guard createIfMissing else { throw StorageError.notFound(RemoteLayout.manifest()) }

        let created = try newStore(kind: kind, credential: credential, deviceName: deviceName, encrypted: encrypted,
                                   initialFeatures: initialFeatures, supported: supported, passedCipher: cipher,
                                   makeCipher: makeCipher, now: now)
        do {
            let etag = try await backend.put(RemoteLayout.manifest(), data: try encode(created.manifest), ifMatch: nil, ifNoneMatch: true)
            return (created.replacing(manifest: created.manifest, etag: unquoted(etag)), true)
        } catch StorageError.preconditionFailed {
            // Another device created the store first; join theirs.
            guard let (manifest, etag) = try await readManifestAndETag(backend) else {
                throw StorageError.notFound(RemoteLayout.manifest())
            }
            return (try open(manifest, etag), false)
        }
    }

    /// Re-reads the manifest for a running session. Same key ID and no rekey by another device: the new session,
    /// keeping `supported`, a passed cipher and `dataKey`. `credential` is for sync-security's key changes.
    public static func refreshedSession(backend: StorageBackend, current: StoreSession,
                                        credential: StoreCredential?) async throws -> StoreSession {
        _ = credential
        let (data, etag) = try await backend.get(RemoteLayout.manifest())
        return try refreshedSession(current: current, manifestData: data, etag: unquoted(etag), currentDeviceID: nil, now: Date())
    }

    /// `currentDeviceID`: a `rekey` started by this device isn't foreign.
    static func refreshedSession(current: StoreSession, manifestData: Data, etag: String, currentDeviceID: String?,
                                 now: Date) throws -> StoreSession {
        guard let manifest = try? decode(Manifest.self, from: manifestData) else {
            throw StorageError.invalidResponse("Unreadable manifest")
        }
        try checkOpenable(manifest, supported: current.supported)
        try checkNoForeignRekey(manifest, currentDeviceID: currentDeviceID, now: now)
        guard try keyID(of: manifest) == current.keyID else {
            throw SyncError.keyChanged(byDevice: manifest.keyring?.changedBy ?? "")
        }
        return current.replacing(manifest: manifest, etag: etag)
    }

    /// A `rekey` started by another device stops the caller: `rekeyInProgress` while it is fresh, else
    /// `rekeyIncomplete` (sync-security fills in the real counts). One started by `currentDeviceID` doesn't.
    static func checkNoForeignRekey(_ manifest: Manifest, currentDeviceID: String?, now: Date) throws {
        guard let rekey = manifest.rekey, rekey.deviceID != currentDeviceID else { return }
        if rekey.isStale(at: now) { throw SyncError.rekeyIncomplete(done: 0, total: 0) }
        throw SyncError.rekeyInProgress(deviceName: rekey.deviceName)
    }

    /// The key a manifest's records are sealed with: the keyring's, else the legacy block's, else nil (plain).
    static func keyID(of manifest: Manifest) throws -> String? {
        if let keyring = manifest.keyring { return keyring.keyID }
        if let encryption = manifest.encryption { return KeyIdentity.legacyKeyID(encryption) }
        if manifest.features?.contains(StoreFeature.keyring.rawValue) == true {
            throw SyncError.invalidManifest("keyring feature without a keyring or an encryption block")
        }
        return nil
    }

    static func unquoted(_ etag: String) -> String {
        etag.count >= 2 && etag.hasPrefix("\"") && etag.hasSuffix("\"") ? String(etag.dropFirst().dropLast()) : etag
    }

    static func readManifestAndETag(_ backend: StorageBackend) async throws -> (Manifest, String)? {
        let fetched: (data: Data, etag: String)
        do {
            fetched = try await backend.get(RemoteLayout.manifest())
        } catch StorageError.notFound {
            return nil
        }
        guard let manifest = try? decode(Manifest.self, from: fetched.data) else {
            throw StorageError.invalidResponse("Unreadable manifest")
        }
        return (manifest, unquoted(fetched.etag))
    }

    // MARK: - Opening

    private static func openSession(_ manifest: Manifest, etag: String, kind: StoreSessionKind, credential: StoreCredential?,
                                    encrypted: Bool, supported: Set<StoreFeature>, passedCipher: (any SyncCipher)?,
                                    makeCipher: CipherFactory) throws -> StoreSession {
        try checkOpenable(manifest, supported: supported)
        let features = StoreSession.features(of: manifest)
        func session(_ cipher: SyncCipher, keyID: String?, dataKey: SymmetricKey? = nil) -> StoreSession {
            StoreSession(kind: kind, manifest: manifest, manifestETag: etag, cipher: cipher, keyID: keyID, features: features,
                         supported: supported, dataKey: dataKey, passedCipher: passedCipher != nil)
        }

        if let passedCipher {
            guard let encryption = manifest.encryption else {
                if manifest.keyring != nil { throw SyncError.wrongPassphrase }
                throw SyncError.encryptionMismatch
            }
            guard (try? passedCipher.open(encryption.keyCheck, context: keyCheckContext)) == keyCheckPlaintext else {
                throw SyncError.wrongPassphrase
            }
            return session(passedCipher, keyID: KeyIdentity.legacyKeyID(encryption))
        }

        if let keyring = manifest.keyring {
            // Without the feature, an older app would read this store as unencrypted.
            guard features.contains(.keyring) else { throw SyncError.invalidManifest("keyring without the keyring feature") }
            let key: SymmetricKey
            switch credential {
            case .passphrase(let passphrase):
                key = try keyring.unwrap(passphrase: passphrase)
            case .dataKey(let candidate):
                guard KeyIdentity.keyID(for: candidate) == keyring.keyID else { throw SyncError.wrongPassphrase }
                key = candidate
            case nil:
                throw SyncError.passphraseRequired
            }
            return session(AESGCMCipher(key: key), keyID: keyring.keyID, dataKey: key)
        }

        if features.contains(.keyring), manifest.encryption == nil {
            throw SyncError.invalidManifest("keyring feature without a keyring or an encryption block")
        }
        guard let encryption = manifest.encryption else {
            // Never silently downgrade a user who asked for encryption to a plaintext store.
            if encrypted { throw SyncError.encryptionMismatch }
            return session(plaintextCipher(), keyID: nil)
        }
        // v1, or keyring pending (the feature is set but the keyring isn't written yet): the legacy key.
        guard iterationRange.contains(encryption.iterations) else {
            throw SyncError.invalidManifest("iterations \(encryption.iterations) outside \(iterationRange)")
        }
        guard encryption.salt.count == 16 else { throw SyncError.invalidManifest("salt is \(encryption.salt.count) bytes, expected 16") }
        guard !encryption.keyCheck.isEmpty else { throw SyncError.invalidManifest("missing key check") }
        let passphrase: String
        switch credential {
        case .passphrase(let value) where !value.isEmpty:
            passphrase = value
        case .dataKey:
            throw SyncError.wrongPassphrase
        default:
            throw SyncError.passphraseRequired
        }
        // v1 keys derive from the passphrase's raw bytes (program §4 rule 12), never normalised.
        let cipher = try makeCipher(passphrase, encryption.salt, encryption.iterations)
        guard (try? cipher.open(encryption.keyCheck, context: keyCheckContext)) == keyCheckPlaintext else { throw SyncError.wrongPassphrase }
        return session(cipher, keyID: KeyIdentity.legacyKeyID(encryption))
    }

    // MARK: - Creating

    /// The session for a store about to be created; its ETag is filled in after the write.
    private static func newStore(kind: StoreSessionKind, credential: StoreCredential?, deviceName: String, encrypted: Bool,
                                 initialFeatures: Set<StoreFeature>, supported: Set<StoreFeature>,
                                 passedCipher: (any SyncCipher)?, makeCipher: CipherFactory, now: Date) throws -> StoreSession {
        for feature in initialFeatures {
            guard supported.contains(feature) else { throw SyncError.invalidManifest("\(feature.rawValue) isn't supported") }
            for required in feature.requires where !initialFeatures.contains(required) {
                throw SyncError.invalidManifest("\(feature.rawValue) without \(required.rawValue)")
            }
        }
        let names = initialFeatures.isEmpty ? nil : initialFeatures.map(\.rawValue).sorted()
        let formatVersion = initialFeatures.isEmpty ? 1 : 2
        func session(_ manifest: Manifest, _ cipher: SyncCipher, keyID: String?, dataKey: SymmetricKey? = nil) -> StoreSession {
            StoreSession(kind: kind, manifest: manifest, manifestETag: "", cipher: cipher, keyID: keyID, features: initialFeatures,
                         supported: supported, dataKey: dataKey, passedCipher: passedCipher != nil)
        }

        if initialFeatures.contains(.keyring) {
            guard encrypted else { throw SyncError.invalidManifest("a keyring store must be encrypted") }
            guard passedCipher == nil else { throw SyncError.invalidManifest("a keyring store can't use a passed cipher") }
            guard let credential else { throw SyncError.passphraseRequired }
            guard case .passphrase(let passphrase) = credential else {
                throw SyncError.invalidManifest("a new keyring store needs a passphrase")
            }
            guard !KeyDerivation.normalized(passphrase).isEmpty else { throw SyncError.passphraseRequired }
            guard !deviceName.isEmpty else { throw SyncError.invalidManifest("a new keyring needs a device name") }
            let dataKey = SymmetricKey(size: .bits256)
            let keyring = try Keyring.make(dataKey: dataKey, passphrase: passphrase, deviceName: deviceName, now: now)
            let manifest = Manifest(formatVersion: formatVersion, createdAt: now, features: names, keyring: keyring)
            return session(manifest, AESGCMCipher(key: dataKey), keyID: keyring.keyID, dataKey: dataKey)
        }

        guard encrypted else {
            return session(Manifest(formatVersion: formatVersion, createdAt: now, features: names), plaintextCipher(), keyID: nil)
        }
        let salt = makeSalt()
        let cipher: SyncCipher
        if let passedCipher {
            cipher = passedCipher
        } else {
            switch credential {
            case .passphrase(let passphrase) where !passphrase.isEmpty:
                cipher = try makeCipher(passphrase, salt, defaultIterations)
            case .dataKey:
                throw SyncError.invalidManifest("a new v1 store needs a passphrase")
            default:
                throw SyncError.passphraseRequired
            }
        }
        let encryption = Manifest.Encryption(salt: salt, iterations: defaultIterations,
                                             keyCheck: try cipher.seal(keyCheckPlaintext, context: keyCheckContext))
        let manifest = Manifest(formatVersion: formatVersion, encryption: encryption, createdAt: now, features: names)
        return session(manifest, cipher, keyID: KeyIdentity.legacyKeyID(encryption))
    }
}
