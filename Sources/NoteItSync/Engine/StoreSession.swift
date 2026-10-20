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
    /// `.lockedNotes`; sharing passes `supported ∪ [.noteItSpace]` for space sessions.
    public static let supported: Set<StoreFeature> = []

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
