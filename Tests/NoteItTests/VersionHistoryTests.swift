import AppKit
import XCTest
@testable import NoteIt
import NoteItSync

@MainActor
final class VersionHistoryTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-history-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func makeStore(_ name: String = "lib") -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: base.appendingPathComponent(name, isDirectory: true), seedsFreshLibrary: false))
        store.history.now = { [unowned self] in self.clock }
        return store
    }

    private func advance(minutes: Double) { clock.addTimeInterval(minutes * 60) }

    private func edit(_ store: NoteStore, _ id: UUID, _ text: String) {
        store.updateBody(id, NSAttributedString(string: text))
        store.flush()
    }

    private func texts(_ store: NoteStore, _ id: UUID) throws -> [String] {
        try store.versions(of: id).map { try store.history.load($0).string }
    }

    func testVersionsAreStoredUnderHistoryWithUTCTimestampNames() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "v1")).id
        store.flush()
        edit(store, id, "v2")

        let version = try XCTUnwrap(store.versions(of: id).first)
        XCTAssertEqual(version.url.deletingLastPathComponent().standardizedFileURL,
                       store.historyURL.appendingPathComponent(id.uuidString, isDirectory: true).standardizedFileURL)
        XCTAssertEqual(version.url.lastPathComponent, "20270115T080000Z.rtfd")
        XCTAssertEqual(version.date, clock)
        let leftovers = try fm.contentsOfDirectory(atPath: version.url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, [version.url.lastPathComponent], "no temp files are left behind")
    }

    func testSavedBodyIsKeptAtMostEveryTenMinutes() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "v1")).id
        store.flush()
        XCTAssertTrue(store.versions(of: id).isEmpty, "a new note has no saved body to keep")

        edit(store, id, "v2")
        XCTAssertEqual(try texts(store, id), ["v1"], "the first replacement is always kept")

        advance(minutes: 5)
        edit(store, id, "v3")
        advance(minutes: 5)
        edit(store, id, "v4")
        XCTAssertEqual(try texts(store, id), ["v1"], "nothing within 10 minutes of the newest version")

        advance(minutes: 0.5)
        edit(store, id, "v5")
        XCTAssertEqual(try texts(store, id), ["v4", "v1"])
    }

    func testRetentionKeeps50VersionsAndNoneOlderThan30Days() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "start")).id
        store.flush()
        for i in 0..<55 {
            advance(minutes: 11)
            edit(store, id, "v\(i)")
        }
        let versions = store.versions(of: id)
        XCTAssertEqual(versions.count, VersionHistory.maxVersions)
        XCTAssertEqual(try store.history.load(versions[0]).string, "v53", "the newest are kept")

        advance(minutes: 60 * 24 * 31)
        edit(store, id, "much later")
        XCTAssertEqual(try texts(store, id), ["v54"], "versions older than 30 days are dropped")

        advance(minutes: 60 * 24 * 31)
        store.history.pruneAll(keeping: [id])
        XCTAssertTrue(store.versions(of: id).isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: store.history.directory(for: id).path))
    }

    func testPruneAllRemovesHistoryOfMissingNotes() throws {
        let store = makeStore()
        let orphan = UUID()
        let source = store.bodyURL(for: store.createNote(in: nil, initial: NSAttributedString(string: "x")).id)
        store.flush()
        XCTAssertNotNil(store.history.recordSavedBody(at: source, of: orphan))
        store.purgeExpiredDeletedNotes()
        XCTAssertFalse(fm.fileExists(atPath: store.history.directory(for: orphan).path))
    }

    func testRestoreReplacesBodyAndKeepsCurrentBodyAsAVersion() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Original\nfirst draft")).id
        store.flush()
        edit(store, id, "Rewritten\nsecond draft")
        let revision = store.note(with: id)?.revision
        let original = try XCTUnwrap(store.versions(of: id).first)

        advance(minutes: 1)
        try store.restoreVersion(original)

        XCTAssertEqual(store.plainText(for: id), "Original\nfirst draft")
        XCTAssertEqual(store.note(with: id)?.title, "Original")
        XCTAssertNotEqual(store.note(with: id)?.revision, revision, "a restore syncs like an edit")
        XCTAssertEqual(store.externallyUpdatedNoteID, id)
        XCTAssertEqual(try NoteStore.readBody(at: store.bodyURL(for: id)).string, "Original\nfirst draft")
        XCTAssertEqual(try texts(store, id), ["Rewritten\nsecond draft", "Original\nfirst draft"],
                       "the body before the restore is kept, so the restore can be undone")
    }

    func testRestoreKeepsUnsavedEdits() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "one")).id
        store.flush()
        edit(store, id, "two")
        let first = try XCTUnwrap(store.versions(of: id).first)
        advance(minutes: 1)
        store.updateBody(id, NSAttributedString(string: "unsaved three"))
        try store.restoreVersion(first)
        XCTAssertEqual(try texts(store, id).first, "unsaved three")
    }

    func testRestoreIsRefusedForDeletedNotes() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "one")).id
        store.flush()
        edit(store, id, "two")
        let version = try XCTUnwrap(store.versions(of: id).first)
        store.moveToRecentlyDeleted([id])
        try store.restoreVersion(version)
        XCTAssertEqual(store.plainText(for: id), "two")
    }

    func testPermanentDeleteRemovesHistory() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "one")).id
        store.flush()
        edit(store, id, "two")
        XCTAssertTrue(fm.fileExists(atPath: store.history.directory(for: id).path))
        store.deleteNote(id)
        XCTAssertFalse(fm.fileExists(atPath: store.history.directory(for: id).path))
    }

    func testRemoteDeletionRemovesHistory() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "one")).id
        store.flush()
        edit(store, id, "two")
        store.applyRemoteDeletion(id, kind: .note)
        XCTAssertFalse(fm.fileExists(atPath: store.history.directory(for: id).path))
    }

    func testSyncKeepsAVersionBeforeReplacingTheBody() throws {
        let a = makeStore("a")
        let b = makeStore("b")
        let id = a.createNote(in: nil, initial: NSAttributedString(string: "Shared\nbefore")).id
        a.flush()
        try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))
        XCTAssertTrue(b.versions(of: id).isEmpty)

        a.togglePin(id)
        try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))
        XCTAssertTrue(b.versions(of: id).isEmpty, "a metadata-only change keeps no version")

        // Even within 10 minutes of the last version, a remote body replacement is kept.
        b.updateBody(id, NSAttributedString(string: "Shared\nlocal"))
        b.flush()
        XCTAssertEqual(try texts(b, id), ["Shared\nbefore"])

        a.updateBody(id, NSAttributedString(string: "Shared\nafter"))
        a.flush()
        try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))

        XCTAssertEqual(b.plainText(for: id), "Shared\nafter")
        XCTAssertEqual(try texts(b, id), ["Shared\nlocal", "Shared\nbefore"])
    }

    func testRemoteAppliesWithinTenMinutesKeepAtMostOneVersion() throws {
        let a = makeStore("a")
        let b = makeStore("b")
        let id = a.createNote(in: nil, initial: NSAttributedString(string: "Shared\n0")).id
        a.flush()
        try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))

        for i in 1...12 {
            advance(minutes: 0.5)
            a.updateBody(id, NSAttributedString(string: "Shared\n\(i)"))
            a.flush()
            try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))
        }

        XCTAssertEqual(b.plainText(for: id), "Shared\n12")
        XCTAssertEqual(try texts(b, id), ["Shared\n0"])

        advance(minutes: 11)
        a.updateBody(id, NSAttributedString(string: "Shared\nlater"))
        a.flush()
        try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))
        XCTAssertEqual(try texts(b, id), ["Shared\n12", "Shared\n0"])
    }

    func testSyncKeepsUnversionedBodyAfterRelaunch() throws {
        let a = makeStore("a")
        let id = a.createNote(in: nil, initial: NSAttributedString(string: "Shared\nbefore")).id
        a.flush()
        var b = makeStore("b")
        try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))
        b.updateBody(id, NSAttributedString(string: "Shared\nlocal"))
        b.flush()
        b = makeStore("b")

        a.updateBody(id, NSAttributedString(string: "Shared\nafter"))
        a.flush()
        try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))
        XCTAssertEqual(try texts(b, id), ["Shared\nlocal", "Shared\nbefore"])
    }

    func testVersionLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(VersionHistorySheet.label(for: now.addingTimeInterval(-60), now: now, calendar: calendar).hasPrefix("Today "))
        XCTAssertTrue(VersionHistorySheet.label(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar).hasPrefix("Yesterday "))
        XCTAssertFalse(VersionHistorySheet.label(for: now.addingTimeInterval(-5 * 86_400), now: now, calendar: calendar).hasPrefix("Yesterday"))
    }
}
