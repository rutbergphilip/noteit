import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import NoteIt

@MainActor
final class MenuShortcutStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "noteit-menu-shortcuts-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> MenuShortcutStore { MenuShortcutStore(defaults: defaults) }

    private func storeJSON(_ json: String) {
        defaults.set(Data(json.utf8), forKey: MenuShortcutStore.defaultsKey)
    }

    private func evaluate(_ shortcut: MenuShortcut, for command: MenuShortcutCommand, in store: MenuShortcutStore,
                          keyCombo: KeyCombo? = nil,
                          globalBindings: [HotkeyAction: KeyCombo] = [:]) -> MenuShortcutRules.Verdict {
        MenuShortcutRules.evaluate(shortcut, for: command, store: store, keyCombo: keyCombo, globalBindings: globalBindings)
    }

    // MARK: - Store

    func testNewCommandDefaultTakenByUserShortcutStartsEmpty() throws {
        storeJSON(#"{"find":{"key":"k","modifiers":["shift","command"]}}"#)
        let store = makeStore()
        XCTAssertNil(store.current(.linkToNote))
        XCTAssertEqual(store.current(.find), MenuShortcut("k", [.shift, .command]))
        XCTAssertEqual(store.commands(using: MenuShortcut("k", [.shift, .command])), [.find])
        let saved = MenuShortcutCoding.decode(try XCTUnwrap(defaults.data(forKey: MenuShortcutStore.defaultsKey)))
        XCTAssertEqual(saved[.linkToNote], MenuShortcutOverride.noShortcut)
        XCTAssertNil(makeStore().current(.linkToNote))
    }

    func testConflictNamesEveryCommandUsingTheShortcut() {
        storeJSON(#"{"find":{"key":"j","modifiers":["command"]},"print":{"key":"j","modifiers":["command"]}}"#)
        let store = makeStore()
        XCTAssertEqual(evaluate(MenuShortcut("j", .command), for: .newNote, in: store),
                       .reject("⌘J is already used for “\(MenuShortcutCommand.find.title)” and “\(MenuShortcutCommand.print.title)”."))
    }

    func testStartsWithTheDefaults() {
        let store = makeStore()
        for command in MenuShortcutCommand.allCases {
            XCTAssertEqual(store.current(command), command.defaultShortcut, command.rawValue)
            XCTAssertFalse(store.isCustomized(command), command.rawValue)
        }
        XCTAssertFalse(store.hasCustomizations)
        XCTAssertEqual(store.current(.openQuickly)?.display, "⌘O")
        XCTAssertEqual(store.current(.deleteNote)?.display, "⌘⌫")
    }

    func testOverridesSurviveARelaunch() {
        let store = makeStore()
        store.set(MenuShortcut("j", [.command, .control]), for: .find)
        store.set(MenuShortcut(MenuShortcut.functionKey(5)!, []), for: .newNote)
        store.clear(.print)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.current(.find), MenuShortcut("j", [.command, .control]))
        XCTAssertEqual(reloaded.current(.newNote)?.display, "F5")
        XCTAssertNil(reloaded.current(.print))
        XCTAssertTrue(reloaded.isCustomized(.print))
        XCTAssertEqual(reloaded.current(.exportNote), MenuShortcutCommand.exportNote.defaultShortcut)
        XCTAssertEqual(reloaded.overrides, store.overrides)
    }

    func testSettingTheDefaultIsNotACustomization() {
        let store = makeStore()
        store.set(MenuShortcut("j", .command), for: .find)
        store.set(MenuShortcutCommand.find.defaultShortcut!, for: .find)
        XCTAssertFalse(store.isCustomized(.find))
        XCTAssertNil(defaults.data(forKey: MenuShortcutStore.defaultsKey))
    }

    func testNoShortcutIsDifferentFromReset() {
        let store = makeStore()
        store.clear(.copyAsMarkdown)
        XCTAssertNil(store.current(.copyAsMarkdown))
        XCTAssertTrue(store.isCustomized(.copyAsMarkdown))

        store.reset(.copyAsMarkdown)
        XCTAssertEqual(store.current(.copyAsMarkdown), MenuShortcutCommand.copyAsMarkdown.defaultShortcut)
        XCTAssertFalse(store.isCustomized(.copyAsMarkdown))

        store.clear(.find)
        store.set(MenuShortcut("j", .command), for: .print)
        XCTAssertTrue(store.hasCustomizations)
        store.resetAll()
        XCTAssertFalse(store.hasCustomizations)
        XCTAssertEqual(store.current(.find), MenuShortcutCommand.find.defaultShortcut)
        XCTAssertNil(defaults.data(forKey: MenuShortcutStore.defaultsKey))
    }

    func testInvalidStoredEntriesAreIgnored() {
        storeJSON("""
        {
          "find": {"key": "j", "modifiers": ["command", "control"]},
          "print": {"none": true},
          "bogus": {"key": "k", "modifiers": ["command"]},
          "newNote": {"key": "k", "modifiers": ["hyper"]},
          "newNotebook": {"key": "k", "modifiers": ["option"]},
          "searchNotes": {"key": "ab", "modifiers": ["command"]},
          "exportNote": {"key": 7, "modifiers": ["command"]},
          "versionHistory": "⌘Y",
          "deleteNote": {"key": "\\u001b", "modifiers": ["command"]},
          "openQuickly": {}
        }
        """)
        let store = makeStore()
        XCTAssertEqual(store.overrides, [.find: .shortcut(MenuShortcut("j", [.command, .control])), .print: .noShortcut])
        XCTAssertEqual(store.current(.newNote), MenuShortcutCommand.newNote.defaultShortcut)
        XCTAssertEqual(store.current(.openQuickly), MenuShortcutCommand.openQuickly.defaultShortcut)
    }

    func testUnreadableStoredDataIsIgnored() {
        for json in ["not json", "[1, 2]", "\"⌘J\"", "null"] {
            storeJSON(json)
            XCTAssertTrue(makeStore().overrides.isEmpty, json)
        }
        defaults.set("a string", forKey: MenuShortcutStore.defaultsKey)
        XCTAssertTrue(makeStore().overrides.isEmpty)
    }

    func testTheLiveTableFollowsUpdates() {
        let table = MenuShortcutTable(overrides: [:])
        XCTAssertEqual(table.shortcut(for: .print), MenuShortcutCommand.print.defaultShortcut)
        table.update([.print: .noShortcut, .find: .shortcut(MenuShortcut("j", .command))])
        XCTAssertNil(table.shortcut(for: .print))
        XCTAssertEqual(table.shortcut(for: .find), MenuShortcut("j", .command))
    }

    // MARK: - Checking

    func testAnotherMenuCommandsShortcutIsRejected() {
        let store = makeStore()
        XCTAssertEqual(evaluate(MenuShortcut("o", .command), for: .find, in: store),
                       .reject("⌘O is already used for “Open Quickly…”."))

        store.set(MenuShortcut("j", [.command, .control]), for: .print)
        XCTAssertEqual(evaluate(MenuShortcut("j", [.command, .control]), for: .find, in: store),
                       .reject("⌃⌘J is already used for “Print…”."))
        XCTAssertEqual(evaluate(MenuShortcut("p", .command), for: .find, in: store), .accept(warning: nil))

        store.clear(.openQuickly)
        XCTAssertEqual(evaluate(MenuShortcut("o", .command), for: .find, in: store), .accept(warning: nil))
    }

    func testCopyNoteLinkDefaultShortcutHasNoConflict() {
        let store = makeStore()
        let shortcut = MenuShortcutCommand.copyNoteLink.defaultShortcut!
        XCTAssertEqual(shortcut.display, "⌃⌘L")
        XCTAssertNil(MenuShortcutRules.reservedName(for: shortcut))
        XCTAssertEqual(evaluate(shortcut, for: .copyNoteLink, in: store), .accept(warning: nil))
        XCTAssertEqual(evaluate(shortcut, for: .print, in: store), .reject("⌃⌘L is already used for “Copy Note Link”."))
    }

    func testACommandCanKeepItsOwnShortcut() {
        XCTAssertEqual(evaluate(MenuShortcut("f", [.command, .option]), for: .find, in: makeStore()), .accept(warning: nil))
    }

    func testFixedAppShortcutsAreRejected() {
        let store = makeStore()
        XCTAssertEqual(evaluate(MenuShortcut("b", .command), for: .find, in: store), .reject("⌘B is already used for “Bold”."))
        XCTAssertEqual(evaluate(MenuShortcut("1", [.command, .option]), for: .find, in: store),
                       .reject("⌥⌘1 is already used for “Title”."))
        XCTAssertEqual(evaluate(MenuShortcut("g", .command), for: .find, in: store),
                       .reject("⌘G is already used for “Find Next”."))
        XCTAssertEqual(evaluate(MenuShortcut("0", .command), for: .find, in: store),
                       .reject("⌘0 is already used for “NoteIt Notes”."))
        XCTAssertEqual(evaluate(MenuShortcut(",", .command), for: .find, in: store),
                       .reject("⌘, is already used for “Settings…”."))
    }

    func testSystemShortcutsAreRejected() {
        let store = makeStore()
        XCTAssertEqual(evaluate(MenuShortcut("q", .command), for: .print, in: store),
                       .reject("⌘Q is already used for “Quit NoteIt”."))
        XCTAssertEqual(evaluate(MenuShortcut("z", [.command, .shift]), for: .print, in: store),
                       .reject("⇧⌘Z is already used for “Redo”."))
        XCTAssertEqual(evaluate(MenuShortcut("/", [.command, .shift]), for: .print, in: store),
                       .reject("⇧⌘/ is already used for “Help”."))
    }

    func testShortcutsNeedCommandOrControlOrAFunctionKey() {
        let store = makeStore()
        let message = "Include ⌘ or ⌃ — or use a function key."
        XCTAssertEqual(evaluate(MenuShortcut("j", .option), for: .find, in: store), .reject(message))
        XCTAssertEqual(evaluate(MenuShortcut("j", .shift), for: .find, in: store), .reject(message))
        XCTAssertEqual(evaluate(MenuShortcut("j", [.option, .shift]), for: .find, in: store), .reject(message))
        XCTAssertEqual(evaluate(MenuShortcut("j", []), for: .find, in: store), .reject(message))
        XCTAssertEqual(evaluate(MenuShortcut("j", .control), for: .find, in: store), .accept(warning: nil))
        XCTAssertEqual(evaluate(MenuShortcut(MenuShortcut.functionKey(6)!, []), for: .find, in: store), .accept(warning: nil))
        XCTAssertEqual(evaluate(MenuShortcut(.escape, .command), for: .find, in: store), .reject("Esc can't be used in a shortcut."))
    }

    func testTextEditingKeysAreKeptForTheEditor() {
        let store = makeStore()
        let message = "Arrow, delete and page keys are kept for moving around and editing text."
        XCTAssertEqual(evaluate(MenuShortcut(.rightArrow, .command), for: .print, in: store), .reject(message))
        XCTAssertEqual(evaluate(MenuShortcut(.delete, [.command, .option]), for: .deleteNote, in: store), .reject(message))
        XCTAssertEqual(evaluate(MenuShortcut(.pageDown, .control), for: .find, in: store), .reject(message))
        store.clear(.deleteNote)
        XCTAssertEqual(evaluate(MenuShortcut(.delete, .command), for: .print, in: store), .reject(message))
        XCTAssertEqual(evaluate(MenuShortcut(.delete, .command), for: .deleteNote, in: store), .accept(warning: nil))
        XCTAssertEqual(evaluate(MenuShortcut(.return, [.command, .control]), for: .print, in: store), .accept(warning: nil))
    }

    func testRestoringADefaultThatIsNowTakenDoesNothing() {
        let store = makeStore()
        let open = MenuShortcutCommand.openQuickly.defaultShortcut!
        store.clear(.openQuickly)
        store.set(open, for: .find)
        XCTAssertEqual(store.resetBlocker(for: .openQuickly), .find)

        store.reset(.openQuickly)
        XCTAssertNil(store.current(.openQuickly))
        XCTAssertEqual(store.current(.find), open)

        store.reset(.find)
        XCTAssertNil(store.resetBlocker(for: .openQuickly))
        store.reset(.openQuickly)
        XCTAssertEqual(store.current(.openQuickly), open)
        XCTAssertFalse(store.hasCustomizations)
    }

    func testAGlobalHotkeyOnTheSameKeysOnlyWarns() {
        let combo = KeyCombo(keyCode: kVK_ANSI_J, modifiers: cmdKey | controlKey)
        let verdict = evaluate(MenuShortcut("j", [.command, .control]), for: .find, in: makeStore(), keyCombo: combo,
                               globalBindings: [.quickCapture: combo])
        XCTAssertEqual(verdict, .accept(warning: "⌃⌘J is also the global hotkey for “Quick Capture”. The global hotkey takes priority."))

        let other = KeyCombo(keyCode: kVK_ANSI_K, modifiers: cmdKey | controlKey)
        XCTAssertEqual(evaluate(MenuShortcut("j", [.command, .control]), for: .find, in: makeStore(), keyCombo: combo,
                                globalBindings: [.quickCapture: other]), .accept(warning: nil))
    }

    // MARK: - Recording

    private func recorded(_ keyCode: Int, _ characters: String?, _ flags: NSEvent.ModifierFlags,
                          base: String? = nil) -> MenuShortcut? {
        MenuShortcutRules.shortcut(keyCode: keyCode, characters: characters, charactersIgnoringModifiers: base ?? characters,
                                   modifierFlags: flags)
    }

    func testRecordingUsesTheCommandLayerCharacter() {
        XCTAssertEqual(recorded(kVK_ANSI_V, "v", [.command], base: "м"), MenuShortcut("v", .command))
        XCTAssertEqual(recorded(kVK_ANSI_V, "v", [.command, .shift], base: "М"), MenuShortcut("v", [.command, .shift]))
        XCTAssertEqual(recorded(kVK_ANSI_K, "v", [.command], base: "t"), MenuShortcut("v", .command))
        XCTAssertEqual(recorded(kVK_ANSI_V, nil, [.command, .control], base: "v"), MenuShortcut("v", [.command, .control]))
        XCTAssertEqual(recorded(kVK_ANSI_V, "\u{16}", [.command, .control], base: "v"), MenuShortcut("v", [.command, .control]))
        XCTAssertEqual(recorded(kVK_ANSI_V, "V", [.command, .shift])?.display, "⇧⌘V")
    }

    func testRecordingMapsSpecialKeys() {
        XCTAssertEqual(recorded(kVK_Delete, "\u{7F}", [.command]), MenuShortcut(.delete, .command))
        XCTAssertEqual(recorded(kVK_ForwardDelete, "\u{F728}", [.command])?.display, "⌘⌦")
        XCTAssertEqual(recorded(kVK_Return, "\r", [.command])?.display, "⌘↩")
        XCTAssertEqual(recorded(kVK_UpArrow, "\u{F700}", [.command, .option, .function, .numericPad]),
                       MenuShortcut(.upArrow, [.command, .option]))
        XCTAssertEqual(recorded(kVK_Tab, "\t", [.control])?.display, "⌃⇥")
        XCTAssertEqual(recorded(kVK_Space, " ", [.control, .option])?.display, "⌃⌥Space")
        XCTAssertEqual(recorded(kVK_Escape, "\u{1B}", [.command])?.key, .escape)
        let f5 = recorded(kVK_F5, "\u{F708}", [.function])
        XCTAssertEqual(f5?.display, "F5")
        XCTAssertEqual(f5?.isValid, true)
        XCTAssertEqual(f5?.key, MenuShortcut.functionKey(5))
    }

    func testRecordedShortcutsMatchTheirOwnKeyPresses() {
        let deleteNote = MenuShortcut(.delete, .command)
        XCTAssertTrue(deleteNote.matches(characters: "\u{7F}", modifierFlags: [.command]))
        let f5 = MenuShortcut(MenuShortcut.functionKey(5)!, [])
        XCTAssertTrue(f5.matches(characters: "\u{F708}", modifierFlags: [.function]))
        XCTAssertTrue(MenuShortcut("j", [.command, .shift]).matches(characters: "J", modifierFlags: [.command, .shift]))
    }
}
