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
