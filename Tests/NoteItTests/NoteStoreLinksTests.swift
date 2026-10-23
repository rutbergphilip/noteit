import AppKit
import XCTest
import NoteItDocTestSupport
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
        let deadline = Date().addingTimeInterval(TestTiming.scaled(5))
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
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

    private func headed(_ title: String, _ headings: [String]) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title + "\n", attributes: EditorStyle.attributes(for: .title))
        for heading in headings {
            text.append(NSAttributedString(string: heading + "\n", attributes: EditorStyle.attributes(for: .heading)))
            text.append(NSAttributedString(string: "Body text.\n", attributes: EditorStyle.bodyAttributes))
        }
        return text
    }

    func testHeadingResolvesByFoldedText() {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: headed("Atlas", ["Intro", "Café Plans"])).id
        let expected = (store.body(for: id).string as NSString).range(of: "Café Plans").location
        XCTAssertEqual(store.headingLocation("cafe plans", in: id), expected)
        RichTextEditor.pendingCaret[id] = nil
        LinkNavigationState.shared.missingHeading = nil
        store.navigate(to: id, heading: "CAFÉ PLANS")
        XCTAssertEqual(store.selectedNoteID, id)
        XCTAssertEqual(RichTextEditor.pendingCaret.removeValue(forKey: id), expected)
        XCTAssertNil(LinkNavigationState.shared.missingHeading)
    }

    func testMissingHeadingFallsBackToTop() {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: headed("Atlas", ["Intro"])).id
        XCTAssertNil(store.headingLocation("Outro", in: id))
        store.navigate(to: id, heading: "Outro")
        XCTAssertEqual(RichTextEditor.pendingCaret.removeValue(forKey: id), 0)
        XCTAssertEqual(LinkNavigationState.shared.missingHeading?.note, id)
        XCTAssertEqual(LinkNavigationState.shared.missingHeading?.heading, "Outro")
        LinkNavigationState.shared.missingHeading = nil
    }

    // MARK: Rename updates

    private func linkTexts(_ store: NoteStore, _ id: UUID) -> [String] {
        let text = store.body(for: id)
        var result: [String] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { result.append((text.string as NSString).substring(with: range)) }
        }
        return result
    }

    private func renameFixture(_ store: NoteStore) -> (target: UUID, source: UUID) {
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let link = NoteLink.note(id: target, heading: nil)
        let source = store.createNote(in: nil, initial: body("Source", linking: [("atlas", link), ("the map", link)])).id
        store.updateBody(target, body("Atlas 2"))
        return (target, source)
    }

    func testNotesCreatedBeforeFirstRebuildKeepTheirEntries() async throws {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let source = store.createNote(in: nil, initial: body("Source", linking: [("Atlas", .note(id: target, heading: nil))])).id
        await waitUntil { !store.backlinks(to: target).isEmpty }
        XCTAssertEqual(store.backlinks(to: target).map(\.source), [source])
    }

    func testRenamePromptOnlyForEditorCommits() async throws {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let source = store.createNote(in: nil, initial: body("Source", linking: [("Atlas", .note(id: target, heading: nil))])).id
        await waitUntil { store.linkIndex.hasEntry(for: source) }
        let saved = RenameTracker.idleDelay
        RenameTracker.idleDelay = .milliseconds(20)
        defer { RenameTracker.idleDelay = saved }
        let suite = "noteit-rename-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = RenameTracker()
        tracker.defaults = defaults
        tracker.store = store
        tracker.open(target, title: "Atlas")

        let harness = EditorHarness()
        defer { harness.close() }
        let editor = harness.open(store, target)
        let version = try XCTUnwrap(store.history.record(body("Globe"), extras: .empty, of: target))
        try store.restoreVersion(version)
        XCTAssertEqual(store.note(with: target)?.title, "Globe")
        tracker.titleObserved("Globe", of: target)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(tracker.prompt, "Restore Version in the open note")

        store.updateBody(target, body("Atlas"))
        tracker.titleObserved("Atlas", of: target)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(tracker.prompt, "a rename from sync")

        editor.coordinator.load()
        editor.view.setSelectedRange(NSRange(location: 5, length: 0))
        editor.view.insertText(" 2", replacementRange: NSRange(location: 5, length: 0))
        editor.coordinator.commit()
        XCTAssertEqual(store.note(with: target)?.title, "Atlas 2")
        tracker.titleObserved("Atlas 2", of: target)
        await waitUntil { tracker.prompt != nil }
        XCTAssertEqual(tracker.prompt?.oldTitle, "Atlas")
        XCTAssertEqual(tracker.prompt?.newTitle, "Atlas 2")
    }

    func testUndoAndRedoOfRestoreVersionOfferNoLinkUpdates() async throws {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let source = store.createNote(in: nil, initial: body("Source", linking: [("Atlas", .note(id: target, heading: nil)),
                                                                                 ("Globe", .note(id: target, heading: nil))])).id
        await waitUntil { store.linkIndex.hasEntry(for: source) }
        let saved = RenameTracker.idleDelay
        RenameTracker.idleDelay = .milliseconds(20)
        defer { RenameTracker.idleDelay = saved }
        let suite = "noteit-rename-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = RenameTracker()
        tracker.defaults = defaults
        tracker.store = store
        tracker.open(target, title: "Atlas")
        let harness = EditorHarness()
        defer { harness.close() }
        let editor = harness.open(store, target)
        let undo = try XCTUnwrap(editor.view.undoManager)

        let version = try XCTUnwrap(store.history.record(body("Globe"), extras: .empty, of: target))
        try store.restoreVersion(version)
        tracker.titleObserved("Globe", of: target)
        EditorHarness.settle(undo)
        for (step, title) in [("undo", "Atlas"), ("redo", "Globe")] {
            if step == "undo" { undo.undo() } else { undo.redo() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: RichTextEditor.Coordinator.commitDelay + TestTiming.scaled(0.2)))
            XCTAssertEqual(store.note(with: target)?.title, title, step)
            tracker.titleObserved(title, of: target)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNil(tracker.prompt, step)
            EditorHarness.settle(undo)
        }
    }

    func testRewriteOnlyMatchingText() async {
        let store = makeStore()
        let (target, source) = renameFixture(store)
        XCTAssertEqual(store.renameCandidates(for: target, oldTitle: "Atlas"), [source])
        let result = await store.rewriteLinkText(targeting: target, from: "Atlas", to: "Atlas 2")
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(linkTexts(store, source), ["Atlas 2", "the map"])
        XCTAssertEqual(store.outgoingLinks(from: source).compactMap(\.link), [.note(id: target, heading: nil), .note(id: target, heading: nil)])
    }

    func testAliasesUntouched() async {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let source = store.createNote(in: nil, initial: body("Source", linking: [("Atlas map", .note(id: target, heading: nil))])).id
        XCTAssertEqual(store.renameCandidates(for: target, oldTitle: "Atlas"), [])
        let result = await store.rewriteLinkText(targeting: target, from: "Atlas", to: "Globe")
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(linkTexts(store, source), ["Atlas map"])
    }

    func testCandidatesEmptyWhenNoLinks() {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        _ = store.createNote(in: nil, initial: body("Other mentions Atlas"))
        XCTAssertEqual(store.renameCandidates(for: target, oldTitle: "Atlas"), [])
    }

    func testSkipsDeletedAndLockedSources() async {
        let store = makeStore()
        let (target, source) = renameFixture(store)
        let link = NoteLink.note(id: target, heading: nil)
        let deleted = store.createNote(in: nil, initial: body("Deleted", linking: [("Atlas", link)])).id
        let locked = store.createNote(in: nil, initial: body("Locked", linking: [("Atlas", link)])).id
        _ = store.moveToRecentlyDeleted([deleted])
        lock(store, locked)
        XCTAssertEqual(store.renameCandidates(for: target, oldTitle: "Atlas"), [source])
        let result = await store.rewriteLinkText(targeting: target, from: "Atlas", to: "Atlas 2")
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(Set(result.notes.keys), [source])
        XCTAssertEqual(linkTexts(store, deleted), ["Atlas"])
    }

    func testRewriteBumpsRevision() async {
        let store = makeStore()
        let (target, source) = renameFixture(store)
        let before = store.note(with: source)?.revision
        let result = await store.rewriteLinkText(targeting: target, from: "Atlas", to: "Atlas 2")
        let after = store.note(with: source)?.revision
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(result.notes[source], after)
    }

    func testRewriteRecordsVersionPerNote() async {
        let store = makeStore()
        let (target, source) = renameFixture(store)
        let open = store.createNote(in: nil, initial: body("Open", linking: [("Atlas", .note(id: target, heading: nil))])).id
        let harness = EditorHarness()
        defer { harness.close() }
        let editor = harness.open(store, open)
        let before = (store.versions(of: source).count, store.versions(of: open).count)
        let result = await store.rewriteLinkText(targeting: target, from: "Atlas", to: "Atlas 2")
        XCTAssertEqual(result.updated, 2)
        XCTAssertEqual(store.versions(of: source).count, before.0 + 1)
        XCTAssertEqual(store.versions(of: open).count, before.1 + 1)
        XCTAssertTrue(editor.view.string.contains("Atlas 2"))
    }

    func testOpenNoteChangedThroughEditBody() async {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let open = store.createNote(in: nil, initial: body("Open", linking: [("Atlas", .note(id: target, heading: nil))])).id
        let harness = EditorHarness()
        defer { harness.close() }
        let editor = harness.open(store, open)
        _ = await store.rewriteLinkText(targeting: target, from: "Atlas", to: "Globe")
        XCTAssertEqual(linkTexts(store, open), ["Globe"])
        EditorHarness.settle(editor.view.undoManager)
        XCTAssertEqual(editor.view.undoManager?.undoActionName, "Update Links")
        editor.view.undoManager?.undo()
        XCTAssertTrue(editor.view.string.contains("see Atlas"))
    }

    func testUndoRestoresVersions() async {
        let store = makeStore()
        let (target, source) = renameFixture(store)
        let result = await store.rewriteLinkText(targeting: target, from: "Atlas", to: "Atlas 2")
        XCTAssertEqual(store.undoLinkRewrite(result), 0)
        XCTAssertEqual(linkTexts(store, source), ["atlas", "the map"])
    }

    func testUndoLeavesEditedNotesAlone() async {
        let store = makeStore()
        let (target, source) = renameFixture(store)
        let result = await store.rewriteLinkText(targeting: target, from: "Atlas", to: "Atlas 2")
        let edited = NSMutableAttributedString(attributedString: store.body(for: source))
        edited.append(NSAttributedString(string: "More."))
        store.updateBody(source, edited)
        XCTAssertEqual(store.undoLinkRewrite(result), 1)
        XCTAssertTrue(store.body(for: source).string.hasSuffix("More."))
        XCTAssertEqual(linkTexts(store, source), ["Atlas 2", "the map"])
    }

    // MARK: Unlinked mentions

    private func waitForSearchIndex(_ store: NoteStore, _ ids: [UUID]) async {
        await waitUntil { store.foldedSearchText(of: ids).count == ids.count }
    }

    func testMentionsExcludeLinkingNotesAndTemplates() async {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let plain = store.createNote(in: nil, initial: body("Plain\nI read the atlas today.")).id
        let linking = store.createNote(in: nil, initial: body("Linking\nAtlas again", linking: [("Atlas", .note(id: target, heading: nil))])).id
        let deleted = store.createNote(in: nil, initial: body("Deleted\nAtlas here")).id
        _ = store.moveToRecentlyDeleted([deleted])
        await waitForSearchIndex(store, [plain, linking])
        let results = await store.unlinkedMentions(of: target)
        XCTAssertEqual(results.map(\.source), [plain])
        XCTAssertEqual(results.first?.count, 1)
        XCTAssertEqual(results.first?.contexts, ["I read the atlas today."])
    }

    func testShortTitlesSkipped() async {
        let store = makeStore()
        let short = store.createNote(in: nil, initial: body("Go")).id
        let dated = store.createNote(in: nil, initial: body("2026-10-19")).id
        let other = store.createNote(in: nil, initial: body("Other\nGo to 2026-10-19 now")).id
        await waitForSearchIndex(store, [other])
        XCTAssertFalse(store.mentionsAreSearched(for: short))
        XCTAssertFalse(store.mentionsAreSearched(for: dated))
        let none = await store.unlinkedMentions(of: short)
        XCTAssertEqual(none.count, 0)
        let noneDated = await store.unlinkedMentions(of: dated)
        XCTAssertEqual(noneDated.count, 0)
    }

    func testLinkAllRecordsVersionsAndUndoes() async {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let a = store.createNote(in: nil, initial: body("A\nAtlas and atlas")).id
        let b = store.createNote(in: nil, initial: body("B\nthe Atlas")).id
        let before = (store.versions(of: a).count, store.versions(of: b).count)
        let (linked, result) = await store.linkMentions(of: target, in: [a, b], versioning: .recordCurrent)
        XCTAssertEqual(linked, 3)
        XCTAssertEqual(Set(result.notes.keys), [a, b])
        XCTAssertEqual(store.versions(of: a).count, before.0 + 1)
        XCTAssertEqual(store.versions(of: b).count, before.1 + 1)
        XCTAssertEqual(Set(store.backlinks(to: target).map(\.source)), [a, b])
        XCTAssertEqual(linkTexts(store, a), ["Atlas", "atlas"])
        XCTAssertEqual(store.undoLinkRewrite(result), 0)
        XCTAssertEqual(linkTexts(store, a), [])
        XCTAssertEqual(store.backlinks(to: target).count, 0)
    }
}

