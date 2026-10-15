import AppKit
import Carbon.HIToolbox
import XCTest
@testable import NoteIt

@MainActor
final class PaletteKeyRouteTests: XCTestCase {
    private func route(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags,
                       base: String? = nil) -> PaletteKeyRoute {
        PaletteKeyRoute.route(keyCode: keyCode, characters: characters, charactersIgnoringModifiers: base ?? characters,
                              modifierFlags: flags)
    }

    func testPlainTypingAndControlBindingsPassThrough() {
        XCTAssertEqual(route(kVK_ANSI_P, "p", []), .pass)
        XCTAssertEqual(route(kVK_ANSI_P, "p", [.control]), .pass)
        XCTAssertEqual(route(kVK_ANSI_N, "n", [.control]), .pass)
        XCTAssertEqual(route(kVK_DownArrow, "\u{F701}", [.function, .numericPad]), .pass)
        XCTAssertEqual(route(kVK_Escape, "\u{1B}", []), .pass)
    }

    func testPaletteShortcutsToggle() {
        XCTAssertEqual(route(kVK_ANSI_O, "o", [.command]), .toggleEverything)
        XCTAssertEqual(route(kVK_ANSI_P, "P", [.command, .shift]), .toggleCommands)
    }

    func testCloseKeys() {
        XCTAssertEqual(route(kVK_ANSI_W, "w", [.command]), .close)
        XCTAssertEqual(route(kVK_ANSI_Period, ".", [.command]), .close)
    }

    func testTextEditingShortcutsStayInTheField() {
        for key in ["a", "c", "v", "x", "z"] {
            XCTAssertEqual(route(0, key, [.command]), .pass, key)
        }
        XCTAssertEqual(route(kVK_ANSI_Z, "Z", [.command, .shift]), .pass)
        XCTAssertEqual(route(kVK_LeftArrow, "\u{F702}", [.command, .function, .numericPad]), .pass)
        XCTAssertEqual(route(kVK_RightArrow, "\u{F703}", [.command, .shift, .function]), .pass)
        XCTAssertEqual(route(kVK_LeftArrow, "\u{F702}", [.command, .option]), .pass)
        XCTAssertEqual(route(kVK_Delete, "\u{7F}", [.command]), .pass)
        XCTAssertEqual(route(kVK_ForwardDelete, "\u{F728}", [.command]), .pass)
    }

    func testMenuShortcutsAreHandedToTheMainWindow() {
        XCTAssertEqual(route(kVK_ANSI_P, "p", [.command]), .handOff)
        XCTAssertEqual(route(kVK_ANSI_S, "S", [.command, .shift]), .handOff)
        XCTAssertEqual(route(kVK_ANSI_F, "f", [.command, .option]), .handOff)
        XCTAssertEqual(route(kVK_ANSI_F, "F", [.command, .shift]), .handOff)
        XCTAssertEqual(route(kVK_ANSI_C, "c", [.command, .option, .shift]), .handOff)
        XCTAssertEqual(route(kVK_ANSI_N, "n", [.command]), .handOff)
        XCTAssertEqual(route(kVK_ANSI_Comma, ",", [.command]), .handOff)
        XCTAssertEqual(route(kVK_ANSI_Z, "z", [.command, .option]), .handOff)
    }

    func testCyrillicLayoutUsesTheCommandLayer() {
        XCTAssertEqual(route(kVK_ANSI_V, "v", [.command], base: "м"), .pass)
        XCTAssertEqual(route(kVK_ANSI_C, "c", [.command], base: "с"), .pass)
        XCTAssertEqual(route(kVK_ANSI_A, "a", [.command], base: "ф"), .pass)
        XCTAssertEqual(route(kVK_ANSI_Z, "z", [.command], base: "я"), .pass)
        XCTAssertEqual(route(kVK_ANSI_Z, "Z", [.command, .shift], base: "Я"), .pass)
        XCTAssertEqual(route(kVK_ANSI_W, "w", [.command], base: "ц"), .close)
        XCTAssertEqual(route(kVK_ANSI_O, "o", [.command], base: "щ"), .toggleEverything)
        XCTAssertEqual(route(kVK_ANSI_P, "P", [.command, .shift], base: "З"), .toggleCommands)
        XCTAssertEqual(route(kVK_ANSI_P, "p", [.command], base: "з"), .handOff)
    }

    func testDvorakQwertyCommandUsesTheCommandLayer() {
        // The physical K key types "t" on Dvorak but "v" with ⌘ held.
        XCTAssertEqual(route(kVK_ANSI_K, "v", [.command], base: "t"), .pass)
        XCTAssertEqual(route(kVK_ANSI_S, "o", [.command], base: "o"), .toggleEverything)
    }

    func testOptionAndControlFallBackToTheBaseKey() {
        XCTAssertEqual(route(kVK_ANSI_F, "ƒ", [.command, .option], base: "f"), .handOff)
        XCTAssertEqual(route(kVK_ANSI_V, "\u{16}", [.command, .control], base: "v"), .handOff)
        XCTAssertEqual(route(kVK_ANSI_O, "", [.command], base: "o"), .toggleEverything)
    }

    func testEmojiAndSymbolsStaysInTheField() {
        XCTAssertEqual(route(kVK_Space, " ", [.command, .control]), .pass)
        XCTAssertEqual(route(kVK_Space, " ", [.command, .control, .function]), .pass)
    }

    func testRoutesFollowTheMenuTable() {
        let open = MenuShortcutCommand.openQuickly.defaultShortcut
        let palette = MenuShortcutCommand.commandPalette.defaultShortcut
        XCTAssertEqual(MenuShortcuts.openQuickly, open)
        XCTAssertEqual(MenuShortcuts.commandPalette, palette)
        XCTAssertEqual(route(0, String(open.key.character), open.modifierFlags), .toggleEverything)
        XCTAssertEqual(route(0, String(palette.key.character).uppercased(), palette.modifierFlags), .toggleCommands)
    }

    private func route(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags, base: String? = nil,
                       using store: MenuShortcutStore) -> PaletteKeyRoute {
        PaletteKeyRoute.route(keyCode: keyCode, characters: characters, charactersIgnoringModifiers: base ?? characters,
                              modifierFlags: flags, openQuickly: store.current(.openQuickly),
                              commandPalette: store.current(.commandPalette),
                              otherMenuShortcuts: MenuShortcutCommand.allCases.compactMap { store.current($0) })
    }

    func testRoutesFollowChangedShortcuts() throws {
        let suite = "noteit-route-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuShortcutStore(defaults: defaults)
        store.set(MenuShortcut("j", [.command, .control]), for: .openQuickly)
        store.set(MenuShortcut("k", .control), for: .commandPalette)

        XCTAssertEqual(route(kVK_ANSI_J, "\u{A}", [.command, .control], base: "j", using: store), .toggleEverything)
        XCTAssertEqual(route(kVK_ANSI_K, "\u{B}", [.control], base: "k", using: store), .toggleCommands)
        XCTAssertEqual(route(kVK_ANSI_O, "o", [.command], using: store), .handOff)
        XCTAssertEqual(route(kVK_ANSI_P, "P", [.command, .shift], using: store), .handOff)
        XCTAssertEqual(route(kVK_ANSI_J, "o", [.command, .control], base: "о", using: store), .handOff)

        store.set(MenuShortcut(MenuShortcut.functionKey(5)!, []), for: .openQuickly)
        XCTAssertEqual(route(kVK_F5, "\u{F708}", [.function], using: store), .toggleEverything)
    }

    func testClearedShortcutsToggleNothing() throws {
        let suite = "noteit-route-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuShortcutStore(defaults: defaults)
        store.clear(.openQuickly)
        store.clear(.commandPalette)

        XCTAssertEqual(route(kVK_ANSI_O, "o", [.command], using: store), .handOff)
        XCTAssertEqual(route(kVK_ANSI_P, "P", [.command, .shift], using: store), .handOff)
        XCTAssertEqual(route(kVK_ANSI_O, "o", [.command], base: "щ", using: store), .handOff)
    }

    func testMenuShortcutsWithoutCommandAreHandedOff() throws {
        let suite = "noteit-route-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuShortcutStore(defaults: defaults)
        store.set(MenuShortcut("p", .control), for: .print)
        store.set(MenuShortcut(MenuShortcut.functionKey(6)!, []), for: .newNote)

        XCTAssertEqual(route(kVK_ANSI_P, "\u{10}", [.control], base: "p", using: store), .handOff)
        XCTAssertEqual(route(kVK_F6, "\u{F709}", [.function], using: store), .handOff)
        XCTAssertEqual(route(kVK_ANSI_A, "\u{1}", [.control], base: "a", using: store), .pass)
        XCTAssertEqual(route(kVK_ANSI_P, "p", [], using: store), .pass)
    }
}
