import AppKit
import SwiftUI

/// A main-menu key equivalent. The menus and the command palette both read these, so the palette
/// always shows the shortcut the menu really uses.
struct MenuShortcut: Equatable {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    static let supportedModifiers: EventModifiers = [.control, .option, .shift, .command]

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
        let lowered = String(key.character).lowercased()
        if lowered.count == 1, let letter = lowered.first, letter.isLetter {
            self.key = KeyEquivalent(letter)
        } else {
            self.key = key
        }
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
    }

    /// "⌥⇧⌘C", in the order the menus draw modifiers.
    var display: String { modifierSymbols.joined() + keyName }

    /// One entry per keycap, for the shortcut recorder.
    var keycaps: [String] { modifierSymbols + [keyName] }

    var modifierSymbols: [String] {
        var result: [String] = []
        if modifiers.contains(.control) { result.append("⌃") }
        if modifiers.contains(.option) { result.append("⌥") }
        if modifiers.contains(.shift) { result.append("⇧") }
        if modifiers.contains(.command) { result.append("⌘") }
        return result
    }

    var keyName: String {
        if let number = functionKeyNumber { return "F\(number)" }
        switch key {
        case .delete: return "⌫"
        case .deleteForward: return "⌦"
        case .return: return "↩"
        case .tab: return "⇥"
        case .space: return "Space"
        case .escape: return "⎋"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        case .clear: return "⌧"
        default: return String(key.character).uppercased()
        }
    }

    /// 1–20 for F1–F20, which AppKit encodes as NSF1FunctionKey and up.
    var functionKeyNumber: Int? {
        guard let scalar = key.character.unicodeScalars.first,
              scalar.value >= 0xF704, scalar.value <= 0xF717 else { return nil }
        return Int(scalar.value - 0xF704) + 1
    }

    static func functionKey(_ number: Int) -> KeyEquivalent? {
        guard (1...20).contains(number), let scalar = Unicode.Scalar(UInt32(0xF704 + number - 1)) else { return nil }
        return KeyEquivalent(Character(scalar))
    }

    /// Menu shortcuts need ⌘ or ⌃ (⌥ and ⇧ type characters) unless they're on a function key. Esc is never allowed.
    var isValid: Bool {
        guard key != .escape else { return false }
        return !modifiers.isDisjoint(with: [.command, .control]) || functionKeyNumber != nil
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
        return Self.comparable(characters) == Self.comparable(String(key.character))
    }

    /// NSEvent reports ⌫ as DEL, keypad Enter as ETX and ⇧Tab as a back tab.
    private static func comparable(_ characters: String) -> String {
        switch characters {
        case "\u{7F}": return "\u{8}"
        case "\u{3}": return "\r"
        case "\u{19}": return "\t"
        default: return characters.lowercased()
        }
    }
}

/// The menu commands whose shortcuts can be changed in Settings › Shortcuts.
enum MenuShortcutCommand: String, CaseIterable, Identifiable {
    case newNote
    case newNotebook
    case openQuickly
    case commandPalette
    case searchNotes
    case find
    case findAndReplace
    case exportNote
    case print
    case copyAsMarkdown
    case copyNoteLink
    case versionHistory
    case deleteNote
    case goBack
    case goForward
    case linkToNote
    case newNoteFromTemplate
    case toggleInspector

    var id: String { rawValue }

    /// The menu item's title.
    var title: String {
        switch self {
        case .newNote: "New Note"
        case .newNotebook: "New Notebook…"
        case .openQuickly: "Open Quickly…"
        case .commandPalette: "Command Palette…"
        case .searchNotes: "Search Notes"
        case .find: "Find…"
        case .findAndReplace: "Find and Replace…"
        case .exportNote: "Export Note As…"
        case .print: "Print…"
        case .copyAsMarkdown: "Copy as Markdown"
        case .copyNoteLink: "Copy Note Link"
        case .versionHistory: "Version History…"
        case .deleteNote: "Delete Note"
        case .goBack: "Go Back"
        case .goForward: "Go Forward"
        case .linkToNote: "Link to Note…"
        case .newNoteFromTemplate: "New Note from Template…"
        case .toggleInspector: "Show Links and Outline"
        }
    }

    var defaultShortcut: MenuShortcut {
        switch self {
        case .newNote: MenuShortcut("n", .command)
        case .newNotebook: MenuShortcut("n", [.command, .shift])
        case .openQuickly: MenuShortcut("o", .command)
        case .commandPalette: MenuShortcut("p", [.command, .shift])
        case .searchNotes: MenuShortcut("f", .command)
        case .find: MenuShortcut("f", [.command, .option])
        case .findAndReplace: MenuShortcut("f", [.command, .shift])
        case .exportNote: MenuShortcut("s", [.command, .shift])
        case .print: MenuShortcut("p", .command)
        case .copyAsMarkdown: MenuShortcut("c", [.command, .option, .shift])
        case .copyNoteLink: MenuShortcut("l", [.command, .control])
        case .versionHistory: MenuShortcut("y", [.command, .option])
        case .deleteNote: MenuShortcut(.delete, .command)
        case .goBack: MenuShortcut(.leftArrow, [.control, .command])
        case .goForward: MenuShortcut(.rightArrow, [.control, .command])
        case .linkToNote: MenuShortcut("k", [.shift, .command])
        case .newNoteFromTemplate: MenuShortcut("n", [.option, .command])
        case .toggleInspector: MenuShortcut("i", [.option, .command])
        }
    }
}

/// The shortcuts in effect right now. Readable from any thread, so the palette's key monitor can use it.
enum MenuShortcuts {
    static var newNote: MenuShortcut? { current(.newNote) }
    static var newNotebook: MenuShortcut? { current(.newNotebook) }
    static var openQuickly: MenuShortcut? { current(.openQuickly) }
    static var commandPalette: MenuShortcut? { current(.commandPalette) }
    static var searchNotes: MenuShortcut? { current(.searchNotes) }
    static var find: MenuShortcut? { current(.find) }
    static var findAndReplace: MenuShortcut? { current(.findAndReplace) }
    static var exportNote: MenuShortcut? { current(.exportNote) }
    static var print: MenuShortcut? { current(.print) }
    static var copyAsMarkdown: MenuShortcut? { current(.copyAsMarkdown) }
    static var copyNoteLink: MenuShortcut? { current(.copyNoteLink) }
    static var versionHistory: MenuShortcut? { current(.versionHistory) }
    static var deleteNote: MenuShortcut? { current(.deleteNote) }
    static var goBack: MenuShortcut? { current(.goBack) }
    static var goForward: MenuShortcut? { current(.goForward) }
    static var linkToNote: MenuShortcut? { current(.linkToNote) }
    static var newNoteFromTemplate: MenuShortcut? { current(.newNoteFromTemplate) }
    static var toggleInspector: MenuShortcut? { current(.toggleInspector) }
    /// SwiftUI's own Settings… item; listed so the palette can show it. It can't be changed.
    static let settings = MenuShortcut(",", .command)

    static func current(_ command: MenuShortcutCommand) -> MenuShortcut? {
        MenuShortcutTable.live.shortcut(for: command)
    }
}

/// Thread-safe copy of the shared store's overrides.
final class MenuShortcutTable: @unchecked Sendable {
    static let live = MenuShortcutTable(overrides: MenuShortcutStore.loadOverrides(from: .standard))

    private let lock = NSLock()
    private var overrides: [MenuShortcutCommand: MenuShortcutOverride]

    init(overrides: [MenuShortcutCommand: MenuShortcutOverride]) {
        self.overrides = overrides
    }

    func shortcut(for command: MenuShortcutCommand) -> MenuShortcut? {
        lock.lock()
        defer { lock.unlock() }
        return MenuShortcutOverride.resolve(overrides[command], for: command)
    }

    func update(_ overrides: [MenuShortcutCommand: MenuShortcutOverride]) {
        lock.lock()
        self.overrides = overrides
        lock.unlock()
    }
}

extension View {
    /// Applies the command's current shortcut, or none, and follows changes made in Settings.
    func menuShortcut(_ command: MenuShortcutCommand) -> some View {
        modifier(MenuShortcutModifier(command: command))
    }
}

@MainActor
private struct MenuShortcutModifier: ViewModifier {
    let command: MenuShortcutCommand
    @ObservedObject private var store = MenuShortcutStore.shared

    func body(content: Content) -> some View {
        let shortcut = store.current(command)
        content.keyboardShortcut(shortcut.map { KeyboardShortcut($0.key, modifiers: $0.modifiers) })
    }
}
