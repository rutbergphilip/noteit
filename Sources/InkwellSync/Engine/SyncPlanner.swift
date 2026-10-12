import Foundation

public struct RemoteInfo: Sendable, Equatable {
    /// nil means there is no remote meta object.
    public var metaETag: String?
    public var tombstone: Tombstone?

    public init(metaETag: String? = nil, tombstone: Tombstone? = nil) {
        self.metaETag = metaETag
        self.tombstone = tombstone
    }
}

public enum SyncAction: Equatable, Sendable {
    case none, push, pull, pushDeletion, applyRemoteDeletion, conflict, resurrectPush, forgetBase
}

/// Implements the decision table in docs/plans/2026-10-12-sync.md, with these deviations:
/// - A live local record makes any journaled deletion for the same id stale, so `localDeletedAt` is ignored.
/// - Row 12: a local edit after the base always resurrects, whatever the timestamps; the deleter never saw that edit.
/// - Row 11 without a base: resurrect if `local.modifiedAt > tombstone.deletedAt`, otherwise apply the deletion.
/// - No local record, no journal entry, remote meta and a base (missing from the table): pull, so nothing is lost.
public enum SyncPlanner {
    public static func decide(local: LocalRecord?, localDeletedAt: Date?, remote: RemoteInfo, base: SyncState.Base?) -> SyncAction {
        let hasRemote = remote.metaETag != nil

        if let local {
            if hasRemote {
                guard let base else { return .conflict }                       // 7
                let localChanged = local.revision != base.revision
                let remoteChanged = remote.metaETag != base.remoteMetaETag
                switch (localChanged, remoteChanged) {
                case (false, false): return .none                              // 3
                case (true, false): return .push                               // 4
                case (false, true): return .pull                               // 5
                case (true, true): return .conflict                            // 6
                }
            }
            if let tombstone = remote.tombstone {
                if let base {
                    return local.revision != base.revision ? .resurrectPush : .applyRemoteDeletion   // 12, 11
                }
                return local.modifiedAt > tombstone.deletedAt ? .resurrectPush : .applyRemoteDeletion // 11
            }
            guard let base else { return .push }                               // 1
            return local.revision != base.revision ? .push : .applyRemoteDeletion  // 13
        }

        if localDeletedAt != nil {
            if hasRemote, let base {
                return remote.metaETag == base.remoteMetaETag ? .pushDeletion : .pull  // 8, 9
            }
            if remote.tombstone != nil { return .forgetBase }                  // 15
            if !hasRemote { return .pushDeletion }                             // 10
            return .pull                                                       // 17
        }

        if hasRemote, base == nil { return .pull }                             // 2
        if remote.tombstone != nil { return .forgetBase }                      // 14
        if hasRemote { return .pull }                                          // deviation: base, no journal entry
        if base != nil { return .forgetBase }                                  // 16
        return .none
    }
}
