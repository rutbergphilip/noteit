import AppKit
import SwiftUI

/// A main-menu key equivalent. The menus and the command palette both read these, so the palette
/// always shows the shortcut the menu really uses.
struct MenuShortcut: Equatable {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// "⌥⇧⌘C", in the order the menus draw modifiers.
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .delete: return s + "⌫"
        case .return: return s + "↩"
        default: return s + String(key.character).uppercased()
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    /// Whether a key-down with these characters (ignoring modifiers) and flags types this shortcut.
    func matches(characters: String?, modifierFlags flags: NSEvent.ModifierFlags) -> Bool {
        guard let characters, flags.intersection([.control, .option, .shift, .command]) == modifierFlags else { return false }
        return characters.lowercased() == String(key.character).lowercased()
    }
}

enum MenuShortcuts {
    static let newNote = MenuShortcut("n", .command)
    static let newNotebook = MenuShortcut("n", [.command, .shift])
    static let openQuickly = MenuShortcut("o", .command)
    static let commandPalette = MenuShortcut("p", [.command, .shift])
    static let searchNotes = MenuShortcut("f", .command)
    static let find = MenuShortcut("f", [.command, .option])
    static let findAndReplace = MenuShortcut("f", [.command, .shift])
    static let exportNote = MenuShortcut("s", [.command, .shift])
    static let print = MenuShortcut("p", .command)
    static let copyAsMarkdown = MenuShortcut("c", [.command, .option, .shift])
    static let versionHistory = MenuShortcut("y", [.command, .option])
    static let deleteNote = MenuShortcut(.delete, .command)
    /// SwiftUI's own Settings… item; listed so the palette can show it.
    static let settings = MenuShortcut(",", .command)
}

extension View {
    func keyboardShortcut(_ shortcut: MenuShortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}
