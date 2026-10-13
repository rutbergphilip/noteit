import XCTest
@testable import NoteItSync

final class SyncPlannerTests: XCTestCase {
    private let id = UUID()
    private let rev = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func local(revision: UUID? = nil, modifiedAt: Date? = nil) -> LocalRecord {
        LocalRecord(id: id, kind: .note, revision: revision ?? rev, modifiedAt: modifiedAt ?? t0)
    }
    private func base(revision: UUID? = nil, etag: String = "e1") -> SyncState.Base {
        .init(revision: revision ?? rev, remoteMetaETag: etag)
    }
    private func tomb(_ deletedAt: Date? = nil) -> Tombstone {
        Tombstone(id: id, kind: .note, deletedAt: deletedAt ?? t0, deviceID: "other")
    }
    private func decide(_ l: LocalRecord?, deleted: Bool = false, meta: String? = nil, tombstone: Tombstone? = nil, base b: SyncState.Base? = nil) -> SyncAction {
        SyncPlanner.decide(local: l, localDeletedAt: deleted ? t0 : nil, remote: RemoteInfo(metaETag: meta, tombstone: tombstone), base: b)
    }

    func testRow01_localOnly_push() { XCTAssertEqual(decide(local()), .push) }
    func testRow02_remoteOnly_pull() { XCTAssertEqual(decide(nil, meta: "e1"), .pull) }
    func testRow03_unchanged_none() { XCTAssertEqual(decide(local(), meta: "e1", base: base()), .none) }
    func testRow04_localChanged_push() { XCTAssertEqual(decide(local(revision: UUID()), meta: "e1", base: base()), .push) }
    func testRow05_remoteChanged_pull() { XCTAssertEqual(decide(local(), meta: "e2", base: base()), .pull) }
    func testRow06_bothChanged_conflict() { XCTAssertEqual(decide(local(revision: UUID()), meta: "e2", base: base()), .conflict) }
    func testRow07_independentCreation_conflict() { XCTAssertEqual(decide(local(), meta: "e1"), .conflict) }
    func testRow08_localDeletedRemoteUnchanged_pushDeletion() { XCTAssertEqual(decide(nil, deleted: true, meta: "e1", base: base()), .pushDeletion) }
    func testRow09_localDeletedRemoteChanged_pull() { XCTAssertEqual(decide(nil, deleted: true, meta: "e2", base: base()), .pull) }
    func testRow10_localDeletedRemoteGone_pushDeletion() {
        XCTAssertEqual(decide(nil, deleted: true), .pushDeletion)
        XCTAssertEqual(decide(nil, deleted: true, base: base()), .pushDeletion)
    }
    func testRow11_remoteTombstoneLocalUnchanged_applyRemoteDeletion() {
        XCTAssertEqual(decide(local(), tombstone: tomb(), base: base()), .applyRemoteDeletion)
        // No base: the deletion wins unless the local record was modified after it (deviation, see SyncPlanner).
        XCTAssertEqual(decide(local(modifiedAt: t0 - 10), tombstone: tomb()), .applyRemoteDeletion)
        XCTAssertEqual(decide(local(modifiedAt: t0 + 10), tombstone: tomb()), .resurrectPush)
    }
    func testRow12_remoteTombstoneLocalEdited_resurrectPush() {
        XCTAssertEqual(decide(local(revision: UUID(), modifiedAt: t0 + 10), tombstone: tomb(), base: base()), .resurrectPush)
        // Deviation: an edit after the base resurrects even when its timestamp predates the deletion.
        XCTAssertEqual(decide(local(revision: UUID(), modifiedAt: t0 - 10), tombstone: tomb(), base: base()), .resurrectPush)
    }
    func testRow13_remoteMetaVanished_pushIfEditedElseDelete() {
        XCTAssertEqual(decide(local(revision: UUID()), base: base()), .push)
        XCTAssertEqual(decide(local(), base: base()), .applyRemoteDeletion)
    }
    func testRow14_remoteTombstoneNothingLocal_forgetBase() {
        XCTAssertEqual(decide(nil, tombstone: tomb(), base: base()), .forgetBase)
        XCTAssertEqual(decide(nil, tombstone: tomb()), .forgetBase)
    }
    func testRow15_bothDeleted_forgetBase() {
        XCTAssertEqual(decide(nil, deleted: true, tombstone: tomb(), base: base()), .forgetBase)
        XCTAssertEqual(decide(nil, deleted: true, tombstone: tomb()), .forgetBase)
    }
    func testRow16_onlyBaseLeft_forgetBase() { XCTAssertEqual(decide(nil, base: base()), .forgetBase) }
    func testRow17_localDeletedRemoteUnknown_pull() { XCTAssertEqual(decide(nil, deleted: true, meta: "e1"), .pull) }

    func testLiveLocalRecordIgnoresStaleJournalEntry() {
        XCTAssertEqual(decide(local(), deleted: true, base: base()), .applyRemoteDeletion)
        XCTAssertEqual(decide(local(), deleted: true, meta: "e1", base: base()), .none)
    }

    func testMissingLocalWithoutJournalButRemoteAndBase_pull() {
        XCTAssertEqual(decide(nil, meta: "e1", base: base()), .pull)
    }

    func testNothingAnywhere_none() { XCTAssertEqual(decide(nil), .none) }

    func testTableOrderWhenMetaAndTombstoneBothReachThePlanner() {
        XCTAssertEqual(decide(local(), meta: "e1", tombstone: tomb(), base: base()), .none)       // rows 3-7 first
        XCTAssertEqual(decide(nil, meta: "e1", tombstone: tomb()), .pull)                        // row 2 before 14
        XCTAssertEqual(decide(nil, meta: "e1", tombstone: tomb(), base: base()), .forgetBase)    // row 14
        XCTAssertEqual(decide(nil, deleted: true, meta: "e1", tombstone: tomb(), base: base()), .pushDeletion) // row 8 before 15
        XCTAssertEqual(decide(nil, deleted: true, meta: "e1", tombstone: tomb()), .forgetBase)   // row 15 before 17
    }

    func testTombstoneDeleterNeverSawOurPush_resurrects() {
        let ours = SyncState.Base(revision: rev, remoteMetaETag: "e2", replacedMetaETag: "e1")
        let deleted = Tombstone(id: id, kind: .note, deletedAt: t0, deviceID: "other", deletedMetaETag: "e1")
        XCTAssertEqual(decide(local(), tombstone: deleted, base: ours), .resurrectPush)
    }

    func testTombstoneDeleterSawNewerVersionThanOurBase_applies() {
        let deleted = Tombstone(id: id, kind: .note, deletedAt: t0, deviceID: "other", deletedMetaETag: "e1")
        XCTAssertEqual(decide(local(), tombstone: deleted, base: base(etag: "e0")), .applyRemoteDeletion)
        let pushedEarlier = SyncState.Base(revision: rev, remoteMetaETag: "e0", replacedMetaETag: "e-1")
        XCTAssertEqual(decide(local(), tombstone: deleted, base: pushedEarlier), .applyRemoteDeletion)
        XCTAssertEqual(decide(local(), tombstone: deleted, base: base(etag: "e1")), .applyRemoteDeletion)
    }
}
