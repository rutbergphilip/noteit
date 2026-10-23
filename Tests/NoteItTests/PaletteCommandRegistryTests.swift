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
        "showBacklinks", "showOutline", "showNoteInfo",
    ]

    private var shortcutSuite = ""
    private var menuShortcuts: MenuShortcutStore!
    private var prefsSuite = ""
    private var prefs: UserDefaults!

    override func setUpWithError() throws {
        shortcutSuite = "noteit-palette-shortcuts-\(UUID().uuidString)"
        menuShortcuts = MenuShortcutStore(defaults: UserDefaults(suiteName: shortcutSuite)!)
        prefsSuite = "noteit-palette-prefs-\(UUID().uuidString)"
        prefs = UserDefaults(suiteName: prefsSuite)
        base = fm.temporaryDirectory.appendingPathComponent("noteit-palette-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: shortcutSuite)?.removePersistentDomain(forName: shortcutSuite)
        prefs.removePersistentDomain(forName: prefsSuite)
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
        Set(PaletteCommandRegistry.availableCommands(for: store, defaults: prefs).map(\.info.id))
    }

    private func command(_ id: String, in store: NoteStore) -> PaletteCommand? {
        PaletteCommandRegistry.commands(for: store, defaults: prefs).first { $0.info.id == id }
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

    func testInspectorCommandsOpenTheirTab() {
        let store = makeStore()
        store.selectedNoteID = addNote(store, "Alpha")
        XCTAssertTrue(availableIDs(store).isSuperset(of: ["showBacklinks", "showOutline"]))

        PaletteCommandRegistry.showInspector(.outline, defaults: prefs, showWindow: false)
        XCTAssertTrue(prefs.bool(forKey: PrefKey.inspectorVisible))
        XCTAssertEqual(prefs.string(forKey: PrefKey.inspectorTab), "outline")
        PaletteCommandRegistry.showInspector(.links, defaults: prefs, showWindow: false)
        XCTAssertEqual(prefs.string(forKey: PrefKey.inspectorTab), "links")
    }

    func testNoDuplicateCopyLinkCommand() {
        let store = makeStore()
        store.selectedNoteID = addNote(store, "Alpha")
        let ids = PaletteCommandRegistry.commands(for: store, defaults: prefs).map(\.info.id)
        XCTAssertEqual(ids.filter { $0.localizedCaseInsensitiveContains("copy") && $0.localizedCaseInsensitiveContains("link") }, ["copyNoteLink"])
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
            "newNote", "newNoteFromTemplate", "newTemplate", "openToday", "dailyNoteForDate", "newNotebook", "newSmartFolder", "showTasks", "showCompletedTasks", "searchNotes", "find", "findReplace", "export",
            "print", "copyMarkdown", "deleteNote", "showRecentlyDeleted", "import", "settings", "integrationsSettings", "localAPIOn", "showWelcome",
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
            "newNoteFromTemplate": MenuShortcutCommand.newNoteFromTemplate.defaultShortcut,
            "newTemplate": nil,
            "openToday": MenuShortcutCommand.openToday.defaultShortcut,
            "dailyNoteForDate": nil,
            "versionHistory": MenuShortcutCommand.versionHistory.defaultShortcut,
            "deleteNote": MenuShortcutCommand.deleteNote.defaultShortcut,
            "settings": MenuShortcuts.settings,
            "togglePin": nil,
            "showRecentlyDeleted": nil,
            "import": nil,
            "newSmartFolder": nil,
            "saveSearchAsSmartFolder": nil,
            "showTasks": MenuShortcutCommand.showTasks.defaultShortcut,
            "setDueDate": MenuShortcutCommand.setDueDate.defaultShortcut,
            "addReminder": MenuShortcutCommand.addReminder.defaultShortcut,
            "showNoteInfo": MenuShortcutCommand.showNoteInfo.defaultShortcut,
            "showCompletedTasks": nil,
        ]
        for (id, shortcut) in expected {
            let display: String? = shortcut?.display
            XCTAssertEqual(shortcuts[id], .some(display), id)
        }
    }

    func testShortcutDisplayUsesMenuGlyphOrder() {
        XCTAssertEqual(MenuShortcutCommand.copyAsMarkdown.defaultShortcut?.display, "⌥⇧⌘C")
        XCTAssertEqual(MenuShortcutCommand.newNotebook.defaultShortcut?.display, "⇧⌘N")
        XCTAssertEqual(MenuShortcutCommand.versionHistory.defaultShortcut?.display, "⌥⌘Y")
        XCTAssertEqual(MenuShortcutCommand.deleteNote.defaultShortcut?.display, "⌘⌫")
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
            .newNoteFromTemplate: "newNoteFromTemplate", .setDueDate: "setDueDate", .addReminder: "addReminder", .showNoteInfo: "showNoteInfo",
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

    func testLocalAPIToggleCommandFollowsSetting() throws {
        let store = makeStore()
        XCTAssertTrue(availableIDs(store).contains("localAPIOn"))
        XCTAssertFalse(availableIDs(store).contains("localAPIOff"))

        try XCTUnwrap(command("localAPIOn", in: store)).perform()
        XCTAssertTrue(prefs.bool(forKey: PrefKey.localAPIEnabled))
        XCTAssertFalse(availableIDs(store).contains("localAPIOn"))
        let off = try XCTUnwrap(command("localAPIOff", in: store))
        XCTAssertTrue(off.isAvailable)
        XCTAssertEqual(off.info.title, "Turn Local API Off")

        off.perform()
        XCTAssertFalse(prefs.bool(forKey: PrefKey.localAPIEnabled))
        XCTAssertEqual(try XCTUnwrap(command("localAPIOn", in: store)).info.title, "Turn Local API On")
    }

    func testSaveSearchAsSmartFolderNeedsASearch() {
        let store = makeStore()
        XCTAssertFalse(availableIDs(store).contains("saveSearchAsSmartFolder"))
        store.searchText = "tag:work"
        XCTAssertTrue(availableIDs(store).contains("saveSearchAsSmartFolder"))
    }

    func testShowCompletedTasksTitleFollowsThePreference() throws {
        let store = makeStore()
        XCTAssertEqual(try XCTUnwrap(command("showCompletedTasks", in: store)).info.title, "Show Completed Tasks")
        prefs.set(true, forKey: PrefKey.tasksShowCompleted)
        XCTAssertEqual(try XCTUnwrap(command("showCompletedTasks", in: store)).info.title, "Hide Completed Tasks")
    }
}
