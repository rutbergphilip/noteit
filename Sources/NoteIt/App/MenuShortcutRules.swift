import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Turns a recorded key press into a menu shortcut and decides whether it can be used.
enum MenuShortcutRules {
    enum Verdict: Equatable {
        case accept(warning: String?)
        case reject(String)
    }

    // MARK: - Recording

    private static let specialKeys: [Int: KeyEquivalent] = [
        kVK_LeftArrow: .leftArrow, kVK_RightArrow: .rightArrow, kVK_UpArrow: .upArrow, kVK_DownArrow: .downArrow,
        kVK_Return: .return, kVK_ANSI_KeypadEnter: .return, kVK_Delete: .delete, kVK_ForwardDelete: .deleteForward,
        kVK_Tab: .tab, kVK_Space: .space, kVK_Escape: .escape, kVK_Home: .home, kVK_End: .end,
        kVK_PageUp: .pageUp, kVK_PageDown: .pageDown, kVK_ANSI_KeypadClear: .clear,
    ]

    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
        kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18,
        kVK_F19: 19, kVK_F20: 20,
    ]

    /// `characters` is the key's ⌘-layer character with no other modifiers applied
    /// (`event.characters(byApplyingModifiers: .command)`), so a Russian layout records "v", not "м".
    /// `charactersIgnoringModifiers` is the fallback when that isn't available.
    static func shortcut(keyCode: Int, characters: String?, charactersIgnoringModifiers: String?,
                         modifierFlags: NSEvent.ModifierFlags) -> MenuShortcut? {
        let modifiers = eventModifiers(modifierFlags)
        if let special = specialKeys[keyCode] { return MenuShortcut(special, modifiers) }
        if let number = functionKeys[keyCode], let key = MenuShortcut.functionKey(number) {
            return MenuShortcut(key, modifiers)
        }
        guard let character = typedCharacter(characters) ?? typedCharacter(charactersIgnoringModifiers) else { return nil }
        return MenuShortcut(KeyEquivalent(character), modifiers)
    }

    private static func typedCharacter(_ string: String?) -> Character? {
        guard let string, string.count == 1, let character = string.first,
              !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return character
    }

    static func eventModifiers(_ flags: NSEvent.ModifierFlags) -> SwiftUI.EventModifiers {
        var modifiers: SwiftUI.EventModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    /// The character `keyCode` types with only ⌘ held in the current keyboard layout.
    static func commandLayerCharacter(keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), commandState,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    // MARK: - Checking

    /// Rejects shortcuts that can't be typed safely or are taken by another menu command, a fixed NoteIt
    /// shortcut or a standard macOS one. Warns when a global hotkey uses the same keys, because it wins.
    @MainActor
    static func evaluate(_ shortcut: MenuShortcut, for command: MenuShortcutCommand, store: MenuShortcutStore,
                         keyCombo: KeyCombo?, globalBindings: [HotkeyAction: KeyCombo]) -> Verdict {
        if shortcut.key == .escape { return .reject("Esc can't be used in a shortcut.") }
        guard shortcut.isValid else { return .reject("Include ⌘ or ⌃ — or use a function key.") }
        if editingKeys.contains(shortcut.key), shortcut != command.defaultShortcut {
            return .reject("Arrow, delete and page keys are kept for moving around and editing text.")
        }
        if let other = store.command(using: shortcut, excluding: command) {
            return .reject(alreadyUsed(shortcut, by: other.title))
        }
        if let name = reservedName(for: shortcut) {
            return .reject(alreadyUsed(shortcut, by: name))
        }
        if shortcut == PasteAndMatchStyleShortcut.shortcut, PasteAndMatchStyleShortcut.holdsShiftCommandV {
            return .reject(alreadyUsed(shortcut, by: "Paste and Match Style"))
        }
        if let keyCombo {
            for action in HotkeyAction.allCases where globalBindings[action] == keyCombo {
                return .accept(warning: "\(shortcut.display) is also the global hotkey for “\(action.title)”. The global hotkey takes priority.")
            }
        }
        return .accept(warning: nil)
    }

    /// Text views use these with every modifier, so a menu shortcut on them would take the key away from editing.
    private static let editingKeys: Set<KeyEquivalent> = [
        .leftArrow, .rightArrow, .upArrow, .downArrow, .delete, .deleteForward, .home, .end, .pageUp, .pageDown,
    ]

    private static func alreadyUsed(_ shortcut: MenuShortcut, by name: String) -> String {
        "\(shortcut.display) is already used for “\(name)”."
    }

    static func reservedName(for shortcut: MenuShortcut) -> String? {
        for (reserved, name) in fixedShortcuts where reserved == shortcut { return name }
        for (reserved, name) in systemShortcuts where reserved == shortcut { return name }
        return nil
    }

    /// NoteIt shortcuts that can't be changed: formatting, paragraph styles and the fixed menu items.
    static let fixedShortcuts: [(MenuShortcut, String)] = {
        var list: [(MenuShortcut, String)] = KeyShortcut.all.compactMap { entry -> (MenuShortcut, String)? in
            guard entry.key.count == 1, let character = entry.key.first else { return nil }
            return (MenuShortcut(KeyEquivalent(character), eventModifiers(entry.modifiers)), entry.command.title)
        }
        list.append((MenuShortcut("=", [.command, .shift]), FormatCommand.fontBigger.title))
        list.append((MenuShortcut("0", .command), "NoteIt Notes"))
        list.append((MenuShortcut("g", .command), "Find Next"))
        list.append((MenuShortcut("g", [.command, .shift]), "Find Previous"))
        list.append((MenuShortcut("e", .command), "Use Selection for Find"))
        list.append((MenuShortcut("1", [.command, .shift]), "Replace"))
        list.append((MenuShortcut(.return, [.command, .option]), "Replace All"))
        list.append((MenuShortcuts.settings, "Settings…"))
        return list
    }()

    /// Standard macOS shortcuts.
    static let systemShortcuts: [(MenuShortcut, String)] = [
        (MenuShortcut("q", .command), "Quit NoteIt"),
        (MenuShortcut("w", .command), "Close"),
        (MenuShortcut("h", .command), "Hide NoteIt"),
        (MenuShortcut("h", [.command, .option]), "Hide Others"),
        (MenuShortcut("m", .command), "Minimize"),
        (MenuShortcut("a", .command), "Select All"),
        (MenuShortcut("c", .command), "Copy"),
        (MenuShortcut("v", .command), "Paste"),
        (MenuShortcut("x", .command), "Cut"),
        (MenuShortcut("z", .command), "Undo"),
        (MenuShortcut("z", [.command, .shift]), "Redo"),
        (MenuShortcut("v", [.command, .option, .shift]), "Paste and Match Style"),
        (MenuShortcut("`", .command), "Cycle Through Windows"),
        (MenuShortcut("/", [.command, .shift]), "Help"),
        (MenuShortcut("?", .command), "Help"),
        (MenuShortcut("f", [.command, .control]), "Enter Full Screen"),
        (MenuShortcut("q", [.command, .control]), "Lock Screen"),
        (MenuShortcut(.space, .command), "Spotlight"),
        (MenuShortcut(.space, [.command, .control]), "Emoji & Symbols"),
        (MenuShortcut(.space, .control), "Select the previous input source"),
        (MenuShortcut(.tab, .command), "Switch Apps"),
        (MenuShortcut(.tab, [.command, .shift]), "Switch Apps"),
        (MenuShortcut("3", [.command, .shift]), "Screenshot"),
        (MenuShortcut("4", [.command, .shift]), "Screenshot"),
        (MenuShortcut("5", [.command, .shift]), "Screenshot"),
    ]
}
