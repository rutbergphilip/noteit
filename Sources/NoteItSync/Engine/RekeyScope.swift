import Foundation

/// Why a rekey can't start (`SyncError.rekeyBlocked`). Declared in foundations step 3; sync-security's
/// `RekeyRunner` produces it.
public enum RekeyBlocker: Sendable, Equatable {
    case notIdle
    case pendingBodyVersions(Int)
    case storageCheckFailed(String)
    case unknownPrefix(String)
    /// Non-removed devices without `rekeyAck`.
    case devicesNotSynced([String])
}

/// The rekey scope rule (program §4 rule 7), written down so every RemoteLayout row is checked against it.
/// RekeyRunner (sync-security) lists every key under the store root. A key whose prefix has the sealing
/// being rekeyed is re-sealed (.storeKey for a rekey of the session's key, .spaceKey when a space key changes
/// for objects in a personal store); manifestKey, canary keys, .unsealed rows and rows with the other sealing
/// are skipped; a key with no registered prefix blocks the rekey (RekeyBlocker.unknownPrefix).
/// `rekeying` is never .unsealed. Declared in foundations Task 3.5; RekeyRunner stays in sync-security.
public enum RekeyScope {
    public enum Action: Equatable, Sendable { case reseal, skip, block }

    public static func action(for key: String, rekeying: RecordSealing = .storeKey,
                              prefixes: [RemotePrefix] = RemoteLayout.prefixes) -> Action {
        if rekeying == .unsealed { preconditionFailure("unsealed objects are never rekeyed") }
        if key == RemoteLayout.manifestKey || RemoteLayout.isCanaryKey(key) { return .skip }
        // A key outside the grammar isn't one the registry describes, so it blocks like an unknown prefix.
        guard RemoteLayout.isValidKey(key, prefixes: prefixes),
              let row = RemoteLayout.prefix(for: key, prefixes: prefixes) else { return .block }
        switch row.sealing {
        case .unsealed: return .skip
        case rekeying: return .reseal
        default: return .skip
        }
    }
}
