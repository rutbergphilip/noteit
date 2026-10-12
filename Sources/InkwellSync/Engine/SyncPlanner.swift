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

public enum SyncPlanner {
    // T1 stub; the decision table is implemented in T5.
    public static func decide(local: LocalRecord?, localDeletedAt: Date?, remote: RemoteInfo, base: SyncState.Base?) -> SyncAction {
        .none
    }
}
