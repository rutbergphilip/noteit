import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

/// organise T5: ranked store search with highlights and snippets.
@MainActor
final class RankedSearchTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-ranked-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    private func add(_ store: NoteStore, _ string: String) -> UUID {
        store.createNote(in: nil, initial: NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 14)])).id
    }

    private func indexed(_ store: NoteStore) async {
        for _ in 0..<500 where !store.notes.allSatisfy({ store.searchIndexer.entries[$0.id]?.isComplete == true }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private struct FakeImageText: ImageTextProviding {
        var texts: [UUID: String]
        func imageText(for noteID: UUID) -> String? { texts[noteID] }
    }

    func testBestMatchPutsTitleAboveNewerBodyMatch() async {
        let store = makeStore()
        let titled = add(store, "Invoice\nfor March")
        let body = add(store, "Shopping\nremember the invoice")
        await indexed(store)
        XCTAssertEqual(store.searchResults(for: .allNotes, search: "invoice", order: .bestMatch).map(\.id), [titled, body])
        XCTAssertEqual(store.searchResults(for: .allNotes, search: "invoice", order: .dateEdited).map(\.id), [body, titled])
    }

    func testUntitledNotesDoNotMatchTheirPlaceholderTitle() async {
        let store = makeStore()
        let untitled = add(store, "")
        let named = add(store, "New plan\nfor the note")
        await indexed(store)
        XCTAssertEqual(store.notes.first { $0.id == untitled }?.title, "")
        XCTAssertEqual(store.searchResults(for: .allNotes, search: "note", order: .bestMatch).map(\.id), [named])
        XCTAssertEqual(store.searchResults(for: .allNotes, search: "title:new", order: .bestMatch).map(\.id), [named])
    }

    func testFilterOnlyQueryKeepsDateOrderWithoutScores() async {
        let store = makeStore()
        let first = add(store, "One #work")
        let second = add(store, "Two #work")
        await indexed(store)
        let results = store.searchResults(for: .allNotes, search: "tag:work", order: .bestMatch)
        XCTAssertEqual(results.map(\.id), [second, first])
        XCTAssertTrue(results.allSatisfy { $0.score == nil })
    }

    func testHighlightsAndSnippet() async throws {
        let store = makeStore()
        _ = add(store, "Café plans\nWe meet at the café on Friday")
        await indexed(store)
        let result = try XCTUnwrap(store.searchResults(for: .allNotes, search: "cafe", order: .bestMatch).first)
        XCTAssertEqual(result.titleHighlights, [NSRange(location: 0, length: 4)])
        let snippet = try XCTUnwrap(result.snippet)
        XCTAssertEqual(snippet.highlights.map { (snippet.text as NSString).substring(with: $0) }, ["café"])
        XCTAssertFalse(snippet.text.contains("plans"))
    }

    func testImageOnlyMatchFlaggedOnlyWithProvider() async {
        let store = makeStore()
        let scan = add(store, "Scan\nphoto attached")
        await indexed(store)
        XCTAssertTrue(store.searchResults(for: .allNotes, search: "receipt", order: .bestMatch).isEmpty)
        store.registerImageTextProvider(FakeImageText(texts: [scan: "Receipt total 42"]))
        let results = store.searchResults(for: .allNotes, search: "receipt", order: .bestMatch)
        XCTAssertEqual(results.map(\.id), [scan])
        XCTAssertEqual(results.first?.foundInImage, true)
        XCTAssertEqual(store.searchResults(for: .allNotes, search: "photo", order: .bestMatch).first?.foundInImage, false)
    }

    func testLockedNoteMatchesByTitleOnly() async {
        let store = makeStore()
        let locked = add(store, "Diary\nsecret plans")
        await indexed(store)
        store.notes[store.noteIndex(locked)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        XCTAssertTrue(store.searchResults(for: .allNotes, search: "secret", order: .bestMatch).isEmpty)
        XCTAssertEqual(store.searchResults(for: .allNotes, search: "diary", order: .bestMatch).map(\.id), [locked])
        XCTAssertNil(store.searchResults(for: .allNotes, search: "diary", order: .bestMatch).first?.snippet)
    }

    func testPlainWordsMatchLegacySearch() async {
        let store = makeStore()
        _ = add(store, "Alpha beta\ngamma")
        _ = add(store, "Beta only")
        _ = add(store, "Gamma alpha")
        await indexed(store)
        for search in ["alpha", "beta gamma", "ALPHA", "zeta", "al"] {
            let legacy = LibraryQuery.notes(store.notes, for: .allNotes, search: search,
                                            now: Date(), indexedText: { store.searchIndexer.text(for: $0) }).map(\.id)
            XCTAssertEqual(Set(store.notes(for: .allNotes, search: search).map(\.id)), Set(legacy), search)
        }
    }

    func testFiveThousandNotesWithinBudget() {
        let store = makeStore()
        let words = ["alpha", "budget", "invoice", "meeting", "travel", "garden", "recipe", "project"]
        var notes: [NoteMeta] = []
        for i in 0..<5000 {
            let id = UUID()
            let text = "Note \(i) \(words[i % 8]) \(words[(i / 8) % 8]) " + String(repeating: "filler text ", count: 40)
            let meta = NoteMeta(id: id, title: "Note \(i)", preview: "", isPinned: false, createdAt: Date(),
                                updatedAt: Date(), tags: [])
            notes.append(meta)
            store.searchIndexer.noteChanged(meta, body: NSAttributedString(string: text))
        }
        store.notes = notes
        let start = Date()
        let results = store.searchResults(for: .allNotes, search: "budget invoice", order: .bestMatch)
        XCTAssertFalse(results.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
