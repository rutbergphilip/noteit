import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

/// organise T3: search index v2, kept by the "search" derived index.
@MainActor
final class SearchIndexV2Tests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-search-v2-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    private func body(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 14)])
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private struct V1File: Codable {
        struct Entry: Codable {
            var text: String
            var updatedAt: Date
        }
        var version: Int
        var entries: [String: Entry]
    }

    private let taskBody = "Plan\n☐\tSend invoice #work/acme @due(2026-10-21)\n☑\tDone thing\ncall the supplier @remind(2026-10-20 09:00)"

    func testV1IndexLoadsAndSchedulesRebuild() async throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: body("Héllo world")).id
        store.flush()
        let updatedAt = try XCTUnwrap(store.note(with: id)).updatedAt
        let v1 = V1File(version: 1, entries: [id.uuidString: .init(text: "from the old file", updatedAt: updatedAt)])
        try NoteStore.encoder.encode(v1).write(to: store.searchIndexURL)

        let reopened = makeStore()
        let loaded = try XCTUnwrap(reopened.searchIndexer.entries[id])
        XCTAssertEqual(loaded.text, "from the old file")
        XCTAssertFalse(loaded.isComplete)
        XCTAssertEqual(reopened.notes(for: .allNotes, search: "old file").map(\.id), [id])

        await waitUntil { reopened.searchIndexer.entries[id]?.isComplete == true }
        XCTAssertEqual(reopened.searchIndexer.entries[id]?.plain, "Héllo world")
        reopened.flush()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: reopened.searchIndexURL)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 2)
    }

    func testV2RoundTrip() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: body(taskBody)).id
        store.flush()
        var entry = try XCTUnwrap(store.searchIndexer.entries[id])
        let reopened = makeStore()
        let loaded = try XCTUnwrap(reopened.searchIndexer.entries[id])
        XCTAssertEqual(loaded.updatedAt.timeIntervalSince(entry.updatedAt), 0, accuracy: 1)
        entry.updatedAt = loaded.updatedAt
        XCTAssertEqual(loaded, entry)
        XCTAssertTrue(entry.isComplete)
    }

    func testEntryHasTasksAndReminders() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: body(taskBody)).id
        let entry = try XCTUnwrap(store.searchIndexer.entries[id])
        XCTAssertEqual(entry.tasks?.map(\.checked), [false, true])
        XCTAssertEqual(entry.tasks?.first?.due, LocalDateTime(token: "2026-10-21"))
        XCTAssertEqual(entry.tasks?.first?.paragraph, 1)
        XCTAssertEqual(entry.reminders?.map(\.text), ["call the supplier"])
        XCTAssertEqual(entry.reminders?.first?.at, LocalDateTime(token: "2026-10-20 09:00"))
        XCTAssertEqual(entry.plain, taskBody)
        XCTAssertEqual(entry.text, TextFold.fold(taskBody))
        XCTAssertEqual(entry.hasAttachment, false)
    }

    func testCodeAndLinksMasked() throws {
        let text = NSMutableAttributedString(attributedString: body("see "))
        text.append(NSAttributedString(string: "#code @remind(2026-10-20 09:00)",
                                       attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
        text.append(body("\n"))
        text.append(NSAttributedString(string: "#linked @remind(2026-10-21 09:00)",
                                       attributes: [.link: URL(string: "https://example.com")!]))
        text.append(body("\nreal #tag"))
        XCTAssertEqual(NoteStore.parseTags(text), ["tag"])
        let masked = NoteStore.maskedForTokens(text)
        XCTAssertEqual((masked as NSString).length, text.length)
        XCTAssertFalse(masked.contains("@remind"))

        let store = makeStore()
        let id = store.createNote(in: nil, initial: text).id
        XCTAssertEqual(store.searchIndexer.entries[id]?.reminders, [])
        XCTAssertTrue(store.searchIndexer.entries[id]?.text.contains("linked") == true)
    }

    func testEditBodyUpdatesIndexThroughRegistry() async throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: body("Groceries")).id
        store.flush()

        let reopened = makeStore()
        let before = reopened.searchIndexer.version
        try reopened.editBody(id, actionName: "Add") { $0.append(NSAttributedString(string: "\n☐\tbuy oat milk")) }
        let entry = try XCTUnwrap(reopened.searchIndexer.entries[id])
        XCTAssertTrue(entry.text.contains("oat milk"))
        XCTAssertEqual(entry.tasks?.map(\.text), ["buy oat milk"])
        XCTAssertGreaterThan(reopened.searchIndexer.version, before)
    }

    func testLockedNoteHasNoEntry() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: body(taskBody)).id
        XCTAssertNotNil(store.searchIndexer.entries[id])
        store.notes[store.noteIndex(id)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        store.refreshDerivedIndexes(for: id)
        XCTAssertNil(store.searchIndexer.entries[id])
        XCTAssertTrue(store.foldedSearchText(of: [id]).isEmpty)
        store.flush()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.searchIndexURL)) as? [String: Any]
        XCTAssertNil((json?["entries"] as? [String: Any])?[id.uuidString])
    }

    func testOlderDecoderIgnoresNewFields() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: body(taskBody)).id
        store.flush()
        let old = try NoteStore.decoder.decode(V1File.self, from: Data(contentsOf: store.searchIndexURL))
        XCTAssertEqual(old.entries[id.uuidString]?.text, TextFold.fold(taskBody))
    }

    func testMetadataChangeKeepsEntryAndBumpsVersion() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: body("Pin me")).id
        let entry = store.searchIndexer.entries[id]
        let before = store.searchIndexer.version
        store.togglePin(id)
        XCTAssertEqual(store.searchIndexer.entries[id], entry)
        XCTAssertGreaterThan(store.searchIndexer.version, before)
    }
}
