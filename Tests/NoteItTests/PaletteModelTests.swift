import AppKit
import XCTest
@testable import NoteIt
import NoteItSync

@MainActor
final class PaletteModelTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private var calls: [String] = []
    private var deferred: [@MainActor () -> Void] = []
    private var stores: [NoteStore] = []

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-palette-model-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        calls = []
        deferred = []
    }

    override func tearDownWithError() throws {
        stores.forEach { $0.flush() }
        stores = []
        deferred = []
        try? fm.removeItem(at: base)
    }

    private func makeStore() -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: base.appendingPathComponent("lib", isDirectory: true), seedsFreshLibrary: false))
        stores.append(store)
        return store
    }

    private func makeModel(_ store: NoteStore) -> PaletteModel {
        let host = PaletteHost(
            dismiss: { [unowned self] in self.calls.append("dismiss") },
            showMainWindow: { [unowned self] in self.calls.append("showMainWindow") },
            focusEditor: { [unowned self] in self.calls.append("focusEditor") },
            later: { [unowned self] work in
                self.calls.append("later")
                self.deferred.append(work)
            }
        )
        return PaletteModel(store: store, host: host)
    }

    private func addNote(_ store: NoteStore, _ text: String, in notebook: UUID? = nil) -> UUID {
        store.createNote(in: notebook, initial: NSAttributedString(string: text)).id
    }

    private func item(_ kind: PaletteItemKind) -> PaletteItem {
        PaletteItem(id: "test", kind: kind, title: "Test", subtitle: nil, symbol: "doc", shortcut: nil, matchedIndices: [])
    }

    // MARK: - Opening notes and notebooks

    func testActivatingANoteOutsideTheSelectionShowsItsNotebook() {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        let home = store.createNotebook(name: "Home", symbol: "house", colorHex: Tokens.Hex.notebookBlue)
        _ = addNote(store, "Budget", in: work.id)
        let target = addNote(store, "Groceries", in: home.id)
        store.selection = .notebook(work.id)
        store.searchText = "budget"

        makeModel(store).activate(item(.note(target)))

        XCTAssertEqual(store.selection, .notebook(home.id))
        XCTAssertEqual(store.selectedNoteID, target)
        XCTAssertEqual(store.searchText, "")
        XCTAssertEqual(calls, ["dismiss", "showMainWindow", "focusEditor"])
    }

    func testActivatingAVisibleNoteKeepsTheSelection() {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        _ = addNote(store, "Budget", in: work.id)
        let target = addNote(store, "Roadmap", in: work.id)
        store.selection = .allNotes

        makeModel(store).activate(item(.note(target)))

        XCTAssertEqual(store.selection, .allNotes)
        XCTAssertEqual(store.selectedNoteID, target)
    }

    func testActivatingANoteHiddenOnlyBySearchClearsTheSearch() {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        _ = addNote(store, "Budget", in: work.id)
        let target = addNote(store, "Roadmap", in: work.id)
        store.selection = .notebook(work.id)
        store.searchText = "budget"

        makeModel(store).activate(item(.note(target)))

        XCTAssertEqual(store.selection, .notebook(work.id))
        XCTAssertEqual(store.searchText, "")
        XCTAssertEqual(store.selectedNoteID, target)
    }

    func testActivatingANoteWithoutANotebookFromANotebookShowsAllNotes() {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        let loose = addNote(store, "Loose")
        store.selection = .notebook(work.id)

        makeModel(store).activate(item(.note(loose)))

        XCTAssertEqual(store.selection, .allNotes)
        XCTAssertEqual(store.selectedNoteID, loose)
    }

    func testActivatingANotebookSelectsIt() {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)

        makeModel(store).activate(item(.notebook(work.id)))

        XCTAssertEqual(store.selection, .notebook(work.id))
        XCTAssertEqual(calls, ["dismiss", "showMainWindow"])
    }

    // MARK: - Creating notes

    func testActivatingCreateNoteMakesATitledNoteInTheCurrentNotebook() throws {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        store.selection = .notebook(work.id)
        let before = store.notes.count

        makeModel(store).activate(item(.createNote("Weekly review")))

        XCTAssertEqual(store.notes.count, before + 1)
        let note = try XCTUnwrap(store.note(with: store.selectedNoteID))
        XCTAssertEqual(note.title, "Weekly review")
        XCTAssertEqual(note.notebookID, work.id)
        XCTAssertEqual(store.plainText(for: note.id), "Weekly review\n")
        XCTAssertEqual(calls, ["dismiss", "showMainWindow", "focusEditor"])
        let caret = RichTextEditor.pendingCaret.removeValue(forKey: note.id)
        XCTAssertEqual(caret, store.body(for: note.id).length)
    }

    func testOpeningAnExistingNoteLeavesNoCaretHint() {
        let store = makeStore()
        let id = addNote(store, "Alpha")

        makeModel(store).activate(item(.note(id)))

        XCTAssertNil(RichTextEditor.pendingCaret[id])
    }

    func testTypingANewTitleOffersCreateNote() throws {
        let store = makeStore()
        _ = addNote(store, "Alpha")
        let model = makeModel(store)
        model.reset(query: "")
        model.query = "Zebra crossing"

        let last = try XCTUnwrap(model.items.last)
        XCTAssertEqual(last.kind, .createNote("Zebra crossing"))
        model.activate(last)
        XCTAssertEqual(store.note(with: store.selectedNoteID)?.title, "Zebra crossing")
        if let id = store.selectedNoteID { RichTextEditor.pendingCaret[id] = nil }
    }

    // MARK: - Commands

    func testCommandRunsOnALaterTurnAfterDismissing() throws {
        let store = makeStore()
        let id = addNote(store, "Alpha")
        store.selectedNoteID = id
        let model = makeModel(store)
        model.reset(query: ">")

        XCTAssertTrue(model.items.allSatisfy { if case .command = $0.kind { return true } else { return false } })
        let pin = try XCTUnwrap(model.items.first { $0.kind == .command("togglePin") })
        model.activate(pin)

        XCTAssertEqual(calls, ["dismiss", "later"])
        XCTAssertEqual(store.note(with: id)?.isPinned, false)
        deferred.forEach { $0() }
        XCTAssertEqual(store.note(with: id)?.isPinned, true)
    }

    func testCommandsGoThroughRunCommandWhenTheHostHasOne() throws {
        let store = makeStore()
        let id = addNote(store, "Alpha")
        store.selectedNoteID = id
        let model = makeModel(store)
        var queued: [@MainActor () -> Void] = []
        model.host.runCommand = { [unowned self] work in
            self.calls.append("runCommand")
            queued.append(work)
        }
        model.reset(query: ">")

        let pin = try XCTUnwrap(model.items.first { $0.kind == .command("togglePin") })
        model.activate(pin)

        XCTAssertEqual(calls, ["dismiss", "runCommand"])
        queued.forEach { $0() }
        XCTAssertEqual(store.note(with: id)?.isPinned, true)
        XCTAssertEqual(calls.last, "later")
    }

    func testUnavailableCommandsAreNotListed() {
        let store = makeStore()
        _ = addNote(store, "Alpha")
        store.selectedNoteID = nil
        let model = makeModel(store)
        model.reset(query: ">")

        let ids = model.items.compactMap { item -> String? in
            if case .command(let id) = item.kind { return id }
            return nil
        }
        XCTAssertTrue(ids.contains("newNote"))
        XCTAssertFalse(ids.contains("print"))
        XCTAssertFalse(ids.contains("togglePin"))
    }

    // MARK: - Selection

    func testSelectionIsClampedAndResetByTyping() {
        let store = makeStore()
        for i in 0..<4 { _ = addNote(store, "Note \(i)") }
        let model = makeModel(store)
        model.reset(query: "")
        XCTAssertEqual(model.items.count, 4)

        model.moveSelection(-1)
        XCTAssertEqual(model.selectedIndex, 0)
        model.moveSelection(2)
        XCTAssertEqual(model.selectedIndex, 2)
        model.moveSelection(10)
        XCTAssertEqual(model.selectedIndex, 3)
        model.select(-5)
        XCTAssertEqual(model.selectedIndex, 0)

        model.moveSelection(3)
        model.query = "Note"
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testSelectionStaysInRangeWhenResultsShrink() {
        let store = makeStore()
        for i in 0..<3 { _ = addNote(store, "Note \(i)") }
        let model = makeModel(store)
        model.reset(query: "")
        model.moveSelection(2)

        store.deleteNotes(store.notes.map(\.id))
        model.recompute()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertNil(model.selectedItem)
    }

    func testReopeningStartsWithTheModesQuery() {
        let store = makeStore()
        let model = makeModel(store)
        model.reset(query: ">")
        XCTAssertEqual(model.mode, .commands)
        model.query = ">pin"

        model.reset(query: "")
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.mode, .everything)
    }

    func testBodyOnlyMatchesAreListed() {
        let store = makeStore()
        let id = addNote(store, "Shopping\nremember the xylophone")
        let model = makeModel(store)
        model.reset(query: "")

        model.query = "xylophone"

        XCTAssertTrue(model.items.contains { $0.kind == .note(id) })
    }

    // MARK: - Live updates

    func testStoreChangesRefreshResultsAndKeepTheSelectedRow() throws {
        let store = makeStore()
        for name in ["Alpha", "Beta", "Gamma"] { _ = addNote(store, name) }
        let model = makeModel(store)
        model.reset(query: "")
        model.moveSelection(1)
        let selected = try XCTUnwrap(model.selectedItem)

        let added = addNote(store, "Delta")
        store.togglePin(added)
        XCTAssertEqual(calls.filter { $0 == "later" }.count, 1)
        XCTAssertFalse(model.items.contains { $0.kind == .note(added) })

        deferred.forEach { $0() }

        XCTAssertTrue(model.items.contains { $0.kind == .note(added) })
        XCTAssertEqual(model.selectedItem?.id, selected.id)
    }

    func testStoreChangesRefreshCommands() {
        let store = makeStore()
        let id = addNote(store, "Alpha")
        store.selectedNoteID = nil
        let model = makeModel(store)
        model.reset(query: ">")
        XCTAssertFalse(model.items.contains { $0.kind == .command("print") })

        store.selectedNoteID = id
        deferred.forEach { $0() }

        XCTAssertTrue(model.items.contains { $0.kind == .command("print") })
    }

    func testClosedPaletteIgnoresStoreChanges() {
        let store = makeStore()
        let model = makeModel(store)
        model.reset(query: "")
        model.stopObserving()

        _ = addNote(store, "Alpha")

        XCTAssertFalse(calls.contains("later"))
        XCTAssertTrue(model.items.isEmpty)
    }

    func testActivatingANoteThatIsGoneRefreshesInstead() {
        let store = makeStore()
        let keep = addNote(store, "Keep")
        let gone = addNote(store, "Gone")
        store.selectedNoteID = keep
        let model = makeModel(store)
        model.reset(query: "")
        let stale = model.items.first { $0.kind == .note(gone) }
        XCTAssertNotNil(stale)

        store.moveToRecentlyDeleted([gone])
        model.activate(stale ?? item(.note(gone)))

        XCTAssertFalse(calls.contains("dismiss"))
        XCTAssertEqual(store.selectedNoteID, keep)
        XCTAssertFalse(model.items.contains { $0.kind == .note(gone) })
    }

    func testActivatingANotebookThatIsGoneRefreshesInstead() {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        store.selection = .allNotes
        let model = makeModel(store)
        model.reset(query: "Work")
        XCTAssertTrue(model.items.contains { $0.kind == .notebook(work.id) })

        store.deleteNotebook(work.id)
        model.activate(item(.notebook(work.id)))

        XCTAssertFalse(calls.contains("dismiss"))
        XCTAssertEqual(store.selection, .allNotes)
        XCTAssertFalse(model.items.contains { $0.kind == .notebook(work.id) })
    }

    func testNotebookColourComesFromTheStore() {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        let model = makeModel(store)

        XCTAssertEqual(model.notebookColorHex(work.id), Tokens.Hex.notebookBlue)
        XCTAssertNil(model.notebookColorHex(UUID()))
    }

    // MARK: - Highlighting

    func testHighlightMarksMatchedCharacters() {
        let title = PaletteHighlight.title("Café notes", matched: [0, 3, 5])
        XCTAssertEqual(String(title.characters), "Café notes")

        var marked: [String] = []
        for run in title.runs where run.inlinePresentationIntent == .stronglyEmphasized {
            marked.append(String(title[run.range].characters))
        }
        XCTAssertEqual(marked, ["C", "é", "n"])
    }
}
