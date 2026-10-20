import AppKit
import XCTest
@testable import NoteIt
import NoteItSync

@MainActor
final class PaletteCommandRegistryTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    private let noteCommandIDs: Set<String> = [
        "find", "findReplace", "export", "print", "copyMarkdown", "versionHistory", "togglePin", "deleteNote",
    ]

    private var shortcutSuite = ""
    private var menuShortcuts: MenuShortcutStore!

    override func setUpWithError() throws {
        shortcutSuite = "noteit-palette-shortcuts-\(UUID().uuidString)"
        menuShortcuts = MenuShortcutStore(defaults: UserDefaults(suiteName: shortcutSuite)!)
        base = fm.temporaryDirectory.appendingPathComponent("noteit-palette-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: shortcutSuite)?.removePersistentDomain(forName: shortcutSuite)
        menuShortcuts = nil
        try? fm.removeItem(at: base)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: base.appendingPathComponent("lib", isDirectory: true), seedsFreshLibrary: false))
    }

    private func shortcutsByID(_ commands: [PaletteCommand]) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: commands.map { ($0.info.id, $0.info.shortcut) })
    }

    private func addNote(_ store: NoteStore, _ text: String, in notebook: UUID? = nil) -> UUID {
        store.createNote(in: notebook, initial: NSAttributedString(string: text)).id
    }

    private func availableIDs(_ store: NoteStore) -> Set<String> {
        Set(PaletteCommandRegistry.availableCommands(for: store).map(\.info.id))
    }

    private func command(_ id: String, in store: NoteStore) -> PaletteCommand? {
        PaletteCommandRegistry.commands(for: store).first { $0.info.id == id }
    }

    func testNoteCommandsNeedASelectedNote() {
        let store = makeStore()
        _ = addNote(store, "Alpha")
        store.selectedNoteID = nil

        let available = availableIDs(store)
        XCTAssertTrue(available.isDisjoint(with: noteCommandIDs), "\(available.intersection(noteCommandIDs))")
        XCTAssertFalse(available.contains { $0.hasPrefix("move.") })
        for id in ["newNote", "newNotebook", "searchNotes", "import", "settings"] {
            XCTAssertTrue(available.contains(id), id)
        }
        let all = Set(PaletteCommandRegistry.commands(for: store).map(\.info.id))
        XCTAssertTrue(noteCommandIDs.isSubset(of: all))
    }

    func testPaletteHasCopyNoteLinkOnlyWithNote() throws {
        let store = makeStore()
        let id = addNote(store, "Alpha")
        store.selectedNoteID = nil
        XCTAssertFalse(availableIDs(store).contains("copyNoteLink"))
        XCTAssertTrue(availableIDs(store).contains("integrationsSettings"))

        store.selectedNoteID = id
        XCTAssertTrue(availableIDs(store).contains("copyNoteLink"))
        XCTAssertEqual(try XCTUnwrap(command("copyNoteLink", in: store)).info.shortcut, "⌃⌘L")

        store.moveToRecentlyDeleted([id])
        store.selection = .recentlyDeleted
        store.selectedNoteID = id
        XCTAssertFalse(availableIDs(store).contains("copyNoteLink"))
    }

    func testNoteCommandsAreAvailableWithASelectedNote() {
        let store = makeStore()
        store.selectedNoteID = addNote(store, "Alpha")

        XCTAssertTrue(noteCommandIDs.isSubset(of: availableIDs(store)))
    }

    func testMoveCommandsExcludeTheNotesNotebook() {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        let home = store.createNotebook(name: "Home", symbol: "house", colorHex: Tokens.Hex.notebookBlue)
        _ = store.createNotebook(name: "Ideas", symbol: "lightbulb", colorHex: Tokens.Hex.notebookBlue)
        let id = addNote(store, "Plan", in: work.id)
        store.selectedNoteID = id

        let moves = PaletteCommandRegistry.availableCommands(for: store).filter { $0.info.id.hasPrefix("move.") }
        XCTAssertEqual(moves.map(\.info.title), ["Move to Home", "Move to Ideas"])
        XCTAssertEqual(moves.map(\.info.symbol), ["house", "lightbulb"])

        moves[0].perform()
        XCTAssertEqual(store.note(with: id)?.notebookID, home.id)
        let after = PaletteCommandRegistry.availableCommands(for: store).filter { $0.info.id.hasPrefix("move.") }
        XCTAssertEqual(after.map(\.info.title), ["Move to Work", "Move to Ideas"])
    }

    func testPinTitleFollowsStateAndTogglesPin() throws {
        let store = makeStore()
        let id = addNote(store, "Alpha")
        store.selectedNoteID = id

        let pin = try XCTUnwrap(command("togglePin", in: store))
        XCTAssertEqual(pin.info.title, "Pin Note")
        pin.perform()
        XCTAssertEqual(store.note(with: id)?.isPinned, true)

        let unpin = try XCTUnwrap(command("togglePin", in: store))
        XCTAssertEqual(unpin.info.title, "Unpin Note")
        XCTAssertEqual(unpin.info.symbol, "pin.slash")
        unpin.perform()
        XCTAssertEqual(store.note(with: id)?.isPinned, false)
    }

    func testDeletedNoteOffersWhatTheMenusOffer() throws {
        let store = makeStore()
        let nb = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        _ = store.createNotebook(name: "Home", symbol: "house", colorHex: Tokens.Hex.notebookBlue)
        let id = addNote(store, "Gone", in: nb.id)
        XCTAssertFalse(availableIDs(store).contains("showRecentlyDeleted"))

        store.moveToRecentlyDeleted([id])
        store.selection = .recentlyDeleted
        store.selectedNoteID = id

        let expected: Set<String> = [
            "newNote", "newNotebook", "searchNotes", "find", "findReplace", "export", "print", "copyMarkdown",
            "deleteNote", "showRecentlyDeleted", "import", "settings", "integrationsSettings",
        ]
        XCTAssertEqual(availableIDs(store), expected)
        XCTAssertEqual(try XCTUnwrap(command("deleteNote", in: store)).info.title, "Delete Now…")
    }

    func testShortcutsComeFromTheMenuTable() {
        let store = makeStore()
        store.selectedNoteID = addNote(store, "Alpha")
        let shortcuts = shortcutsByID(PaletteCommandRegistry.commands(for: store, shortcuts: menuShortcuts))

        let expected: [String: MenuShortcut?] = [
            "newNote": MenuShortcutCommand.newNote.defaultShortcut,
            "newNotebook": MenuShortcutCommand.newNotebook.defaultShortcut,
            "searchNotes": MenuShortcutCommand.searchNotes.defaultShortcut,
            "find": MenuShortcutCommand.find.defaultShortcut,
            "findReplace": MenuShortcutCommand.findAndReplace.defaultShortcut,
            "export": MenuShortcutCommand.exportNote.defaultShortcut,
            "print": MenuShortcutCommand.print.defaultShortcut,
            "copyMarkdown": MenuShortcutCommand.copyAsMarkdown.defaultShortcut,
            "copyNoteLink": MenuShortcutCommand.copyNoteLink.defaultShortcut,
            "versionHistory": MenuShortcutCommand.versionHistory.defaultShortcut,
            "deleteNote": MenuShortcutCommand.deleteNote.defaultShortcut,
            "settings": MenuShortcuts.settings,
            "togglePin": nil,
            "showRecentlyDeleted": nil,
            "import": nil,
        ]
        for (id, shortcut) in expected {
            let display: String? = shortcut?.display
            XCTAssertEqual(shortcuts[id], .some(display), id)
        }
    }

    func testShortcutDisplayUsesMenuGlyphOrder() {
        XCTAssertEqual(MenuShortcutCommand.copyAsMarkdown.defaultShortcut.display, "⌥⇧⌘C")
        XCTAssertEqual(MenuShortcutCommand.newNotebook.defaultShortcut.display, "⇧⌘N")
        XCTAssertEqual(MenuShortcutCommand.versionHistory.defaultShortcut.display, "⌥⌘Y")
        XCTAssertEqual(MenuShortcutCommand.deleteNote.defaultShortcut.display, "⌘⌫")
        XCTAssertEqual(MenuShortcuts.settings.display, "⌘,")
        XCTAssertEqual(MenuShortcut("k", [.command, .control]).display, "⌃⌘K")
    }

    func testShortcutsFollowChangesMadeInSettings() {
        let store = makeStore()
        store.selectedNoteID = addNote(store, "Alpha")
        menuShortcuts.set(MenuShortcut("p", [.command, .control]), for: .print)
        menuShortcuts.clear(.find)

        let shortcuts = shortcutsByID(PaletteCommandRegistry.commands(for: store, shortcuts: menuShortcuts))
        XCTAssertEqual(shortcuts["print"], .some("⌃⌘P"))
        XCTAssertEqual(shortcuts["find"], .some(nil))
        XCTAssertEqual(shortcuts["export"], .some("⇧⌘S"))

        menuShortcuts.resetAll()
        let restored = shortcutsByID(PaletteCommandRegistry.commands(for: store, shortcuts: menuShortcuts))
        XCTAssertEqual(restored["print"], .some("⌘P"))
        XCTAssertEqual(restored["find"], .some("⌥⌘F"))
    }

    func testMenuTitlesMatchTheSettingsList() {
        let store = makeStore()
        store.selectedNoteID = addNote(store, "Alpha")
        let titles = Dictionary(uniqueKeysWithValues: PaletteCommandRegistry.commands(for: store).map { ($0.info.id, $0.info.title) })
        let paletteIDs: [MenuShortcutCommand: String] = [
            .newNote: "newNote", .newNotebook: "newNotebook", .searchNotes: "searchNotes", .find: "find",
            .findAndReplace: "findReplace", .exportNote: "export", .print: "print", .copyAsMarkdown: "copyMarkdown",
            .copyNoteLink: "copyNoteLink", .versionHistory: "versionHistory", .deleteNote: "deleteNote",
        ]
        for (command, id) in paletteIDs {
            XCTAssertEqual(titles[id], command.title, id)
        }
    }

    func testExportCommandUsesTheMenuTitle() throws {
        let store = makeStore()
        store.selectedNoteID = addNote(store, "Alpha")
        XCTAssertEqual(try XCTUnwrap(command("export", in: store)).info.title, "Export Note As…")
    }

    func testCommandIDsAreUnique() {
        let store = makeStore()
        _ = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        store.selectedNoteID = addNote(store, "Alpha")
        let ids = PaletteCommandRegistry.commands(for: store).map(\.info.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
