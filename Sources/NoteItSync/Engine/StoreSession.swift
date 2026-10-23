import CryptoKit
import Foundation

/// A store feature (program §4). Owned by foundations step 3; each case's reader ships with its owner plan.
/// `rekey` is a manifest field (`Manifest.rekey`), never a feature.
public enum StoreFeature: String, Sendable, CaseIterable {
    case noteItDoc = "noteit-doc"                 // web-app
    case keyring = "keyring"                      // sync-security
    case lockedNotes = "locked-notes"             // sync-security; requires noteItDoc
    case noteItSpace = "noteit-space"             // sharing; space sessions only

    /// Every known raw value.
    public static let known: Set<String> = Set(allCases.map(\.rawValue))

    /// Features this build reads. `connectSession` refuses a store with a feature outside it (`unsupportedFeature`),
    /// and `DeviceInfo.supportedFeatures` is this set, sorted. web-app adds `.noteItDoc`, sync-security
    /// `.lockedNotes`; sharing passes `supported ∪ [.noteItSpace]` for space sessions. web-app Task 0.4 added
    /// `.noteItDoc` together with the body conversion (program §4 rule 2).
    public static let supported: Set<StoreFeature> = [.keyring, .noteItDoc]

    /// Features that must be present before this one.
    public var requires: [StoreFeature] {
        switch self {
        case .lockedNotes: return [.noteItDoc]
        case .noteItDoc, .keyring, .noteItSpace: return []
        }
    }
}

/// Which kind of store a session talks to (foundations step 3; sharing owns `.space`).
public enum StoreSessionKind: Sendable {
    case library, space
}

/// How note bodies are stored (foundations step 3; web-app owns `.noteItDocV1`).
public enum BodyEncoding: Sendable {
    case rtfd, noteItDocV1
}

/// An opened store: its manifest, the cipher for its records and the key that cipher uses (foundations step 3).
public struct StoreSession: Sendable {
    public let kind: StoreSessionKind
    public let manifest: Manifest
    public let manifestETag: String
    public let cipher: SyncCipher
    /// Nil for unencrypted stores.
    public let keyID: String?
    public var features: Set<StoreFeature>
    /// The `supported` set passed to `connectSession`. `refreshedSession`, `updateManifest` and `updateRekey`
    /// check against it and copy it into every session they return.
    public let supported: Set<StoreFeature>
    /// The unwrapped keyring data key: set for a keyring session (opened with `.passphrase` or `.dataKey`, or just
    /// created); nil for v1, keyring-pending, plain and passed-cipher sessions. SyncController saves it to the
    /// Keychain (`syncDataKey`) after a passphrase connect.
    public let dataKey: SymmetricKey?
    /// Set when the caller passed the cipher (sharing's space cipher); refreshes keep it.
    let passedCipher: Bool

    public var formatVersion: Int { manifest.formatVersion }
    /// Follows the `noteit-doc` feature, never `formatVersion`.
    public var bodyEncoding: BodyEncoding { features.contains(.noteItDoc) ? .noteItDocV1 : .rtfd }

    init(kind: StoreSessionKind, manifest: Manifest, manifestETag: String, cipher: SyncCipher, keyID: String?,
         features: Set<StoreFeature>, supported: Set<StoreFeature>, dataKey: SymmetricKey?, passedCipher: Bool = false) {
        self.kind = kind
        self.manifest = manifest
        self.manifestETag = manifestETag
        self.cipher = cipher
        self.keyID = keyID
        self.features = features
        self.supported = supported
        self.dataKey = dataKey
        self.passedCipher = passedCipher
    }

    /// A copy for a newer manifest of the same store, keeping the cipher, key and `supported` set.
    func replacing(manifest: Manifest, etag: String) -> StoreSession {
        StoreSession(kind: kind, manifest: manifest, manifestETag: etag, cipher: cipher, keyID: keyID,
                     features: Self.features(of: manifest), supported: supported, dataKey: dataKey, passedCipher: passedCipher)
    }

    /// The manifest's features this build knows; `checkOpenable` has already refused unknown ones.
    static func features(of manifest: Manifest) -> Set<StoreFeature> {
        Set((manifest.features ?? []).compactMap(StoreFeature.init(rawValue:)))
    }
}

/// The session a running engine uses. The engine swaps it only between passes (foundations step 3).
public final class StoreSessionRef: @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoreSession

    public init(_ session: StoreSession) {
        self.session = session
    }

    public var current: StoreSession {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func replace(_ session: StoreSession) {
        lock.lock()
        self.session = session
        lock.unlock()
    }
}
