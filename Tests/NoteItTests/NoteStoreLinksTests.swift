import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

@MainActor
final class NoteStoreLinksTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-links-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        store.installLinkIndex()
        return store
    }

    private func body(_ title: String, linking links: [(String, NoteLink)] = []) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title + "\n")
        for (shown, link) in links {
            text.append(NSAttributedString(string: "see "))
            text.append(NSAttributedString(string: shown, attributes: [.link: link.url]))
            text.append(NSAttributedString(string: ". "))
        }
        return text
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func lock(_ store: NoteStore, _ id: UUID) {
        store.notes[store.noteIndex(id)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        store.refreshDerivedIndexes(for: id)
    }

    func testUpdateBodyIndexesLinks() {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let source = store.createNote(in: nil, initial: body("Source")).id
        XCTAssertEqual(store.outgoingLinks(from: source), [])
        store.updateBody(source, body("Source", linking: [("Atlas", .note(id: target, heading: nil))]))
        XCTAssertEqual(store.outgoingLinks(from: source).map(\.text), ["Atlas"])
        XCTAssertEqual(store.backlinks(to: target).map(\.source), [source])
    }

    func testBacklinksExcludeDeletedSources() {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let a = store.createNote(in: nil, initial: body("A", linking: [("Atlas", .note(id: target, heading: nil))])).id
        let b = store.createNote(in: nil, initial: body("B", linking: [("atlas", .unresolved(title: "ATLAS", heading: nil))])).id
        XCTAssertEqual(Set(store.backlinks(to: target).map(\.source)), [a, b])
        _ = store.moveToRecentlyDeleted([a])
        XCTAssertEqual(store.backlinks(to: target).map(\.source), [b])
    }

    func testIndexSurvivesRelaunch() async throws {
        let first = makeStore()
        let target = first.createNote(in: nil, initial: body("Atlas")).id
        let source = first.createNote(in: nil, initial: body("Source", linking: [("Atlas", .note(id: target, heading: nil))])).id
        first.flush()
        first.linkIndex.writeNow()
        // Without bodies on disk, the entry can only come from link-index.json.
        for url in try fm.contentsOfDirectory(at: root.appendingPathComponent("notes"), includingPropertiesForKeys: nil) {
            try fm.removeItem(at: url)
        }
        let second = makeStore()
        await second.linkIndex.loadTask?.value
        XCTAssertEqual(second.backlinks(to: target).map(\.source), [source])
    }

    func testIndexFileInRootURL() throws {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        _ = store.createNote(in: nil, initial: body("Source", linking: [("Atlas", .note(id: target, heading: nil))]))
        store.flush()
        store.linkIndex.writeNow()
        let url = root.appendingPathComponent(LinkIndex.fileName)
        XCTAssertEqual(store.linkIndex.fileURL, url)
        XCTAssertNotNil(LinkIndex.readFile(at: url))
    }

    func testRebuildFillsMissingEntries() async {
        let first = makeStore()
        let target = first.createNote(in: nil, initial: body("Atlas")).id
        let source = first.createNote(in: nil, initial: body("Source", linking: [("Atlas", .note(id: target, heading: nil))])).id
        first.flush()
        try? fm.removeItem(at: root.appendingPathComponent(LinkIndex.fileName))
        let second = makeStore()
        await waitUntil { second.linkIndex.hasEntry(for: source) }
        XCTAssertEqual(second.backlinks(to: target).map(\.source), [source])
    }

    func testLockedNoteHasNoEntry() async {
        let first = makeStore()
        let target = first.createNote(in: nil, initial: body("Atlas")).id
        let source = first.createNote(in: nil, initial: body("Source", linking: [("Atlas", .note(id: target, heading: nil))])).id
        let other = first.createNote(in: nil, initial: body("Other", linking: [("Atlas", .note(id: target, heading: nil))])).id
        lock(first, source)
        first.flush()
        first.linkIndex.writeNow()
        let file = LinkIndex.readFile(at: root.appendingPathComponent(LinkIndex.fileName))
        XCTAssertNil(file?.entries[source.uuidString])
        try? fm.removeItem(at: root.appendingPathComponent(LinkIndex.fileName))

        let second = makeStore()
        await waitUntil { second.linkIndex.hasEntry(for: other) }
        XCTAssertFalse(second.linkIndex.hasEntry(for: source))
        XCTAssertEqual(second.outgoingLinks(from: source), [])
    }

    func testLockingRemovesEntry() {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let source = store.createNote(in: nil, initial: body("Source", linking: [("Atlas", .note(id: target, heading: nil))])).id
        XCTAssertTrue(store.linkIndex.hasEntry(for: source))
        lock(store, source)
        XCTAssertFalse(store.linkIndex.hasEntry(for: source))
        XCTAssertEqual(store.backlinks(to: target).map(\.source), [])
    }

    func testMoveToRecentlyDeletedKeepsEntries() {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let source = store.createNote(in: nil, initial: body("Source", linking: [("Atlas", .note(id: target, heading: nil))])).id
        _ = store.moveToRecentlyDeleted([source])
        XCTAssertTrue(store.linkIndex.hasEntry(for: source))
        XCTAssertEqual(store.backlinks(to: target).map(\.source), [])
        _ = store.recover([source])
        XCTAssertEqual(store.backlinks(to: target).map(\.source), [source])
    }

    func testResolveDeletedAndMissing() {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        XCTAssertEqual(store.resolve(.note(id: target, heading: "Budget"), from: nil), .note(target, heading: "Budget"))
        XCTAssertEqual(store.resolve(.unresolved(title: "atlas", heading: nil), from: nil), .note(target, heading: nil))
        XCTAssertEqual(store.resolve(.unresolved(title: "Nope", heading: nil), from: nil), .unresolved(title: "Nope"))
        _ = store.moveToRecentlyDeleted([target])
        XCTAssertEqual(store.resolve(.note(id: target, heading: nil), from: nil), .deleted(target))
        let gone = UUID()
        XCTAssertEqual(store.resolve(.note(id: gone, heading: nil), from: nil), .missing(gone))
    }

    func testDuplicateTitlePrefersSameNotebook() {
        let store = makeStore()
        let book = store.createNotebook(name: "Work", symbol: "tray", colorHex: "#0A84FF")
        let inBook = store.createNote(in: book.id, initial: body("Plan")).id
        let newer = store.createNote(in: nil, initial: body("Plan")).id
        let source = store.createNote(in: book.id, initial: body("Source")).id
        XCTAssertEqual(store.noteID(forTitle: "plan", preferring: book.id), inBook)
        XCTAssertEqual(store.noteID(forTitle: "plan", preferring: nil), newer)
        XCTAssertEqual(store.resolve(.unresolved(title: "Plan", heading: nil), from: source), .note(inBook, heading: nil))
    }

    func testFollowUnresolvedCreatesNoteInSourceNotebookAndRewritesLink() throws {
        let store = makeStore()
        let notebook = store.createNotebook(name: "Work", symbol: "folder", colorHex: "#3478F6").id
        let source = store.createNote(in: notebook, initial: body("Source", linking: [("Plan", .unresolved(title: "Plan", heading: nil))])).id
        store.followLink(.unresolved(title: "Plan", heading: nil), from: source)
        let created = try XCTUnwrap(store.notes.first { $0.title == "Plan" })
        XCTAssertEqual(created.notebookID, notebook)
        XCTAssertEqual(store.selectedNoteID, created.id)
        XCTAssertEqual(store.outgoingLinks(from: source).map(\.link), [.note(id: created.id, heading: nil)])
    }

    func testFollowMissingRemovesLinkWhenConfirmed() {
        let store = makeStore()
        let gone = UUID()
        let source = store.createNote(in: nil, initial: body("Source", linking: [("Gone", .note(id: gone, heading: nil))])).id
        let state = LinkNavigationState.shared
        let original = state.confirm
        defer { state.confirm = original }
        var asked: [LinkAlert] = []
        state.confirm = { asked.append($0); return true }
        store.followLink(.note(id: gone, heading: nil), from: source)
        XCTAssertEqual(asked, [.missing])
        XCTAssertEqual(store.outgoingLinks(from: source), [])
        XCTAssertTrue(store.body(for: source).string.contains("Gone"))
    }
}
