import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & KeyCombo.supportedModifiers
    }

    init(keyCode: Int, modifiers: Int) {
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: KeyCombo.carbonModifiers(from: event.modifierFlags))
    }

    static let supportedModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    var isFunctionKey: Bool { KeyCombo.functionKeyNames[Int(keyCode)] != nil }

    /// Global hotkeys need ⌘, ⌃ or ⌥ (⇧ alone is too easy to trigger while typing) unless it is an F-key.
    var isValidGlobalHotkey: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 || isFunctionKey
    }

    /// Modifier glyphs in Apple's canonical order: ⌃⌥⇧⌘.
    var modifierSymbols: [String] {
        var result: [String] = []
        if modifiers & UInt32(controlKey) != 0 { result.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { result.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { result.append("⌘") }
        return result
    }

    var keyName: String { KeyCombo.name(forKeyCode: Int(keyCode)) }

    /// e.g. "⌃⌘E", "⌥Space", "F5".
    var displayString: String { modifierSymbols.joined() + keyName }

    /// One entry per keycap, used for chip rendering.
    var keycaps: [String] { modifierSymbols + [keyName] }

    // MARK: - Key names

    static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_Help: "Help", kVK_ANSI_KeypadClear: "⌧",
        kVK_ANSI_Keypad0: "Num0", kVK_ANSI_Keypad1: "Num1", kVK_ANSI_Keypad2: "Num2",
        kVK_ANSI_Keypad3: "Num3", kVK_ANSI_Keypad4: "Num4", kVK_ANSI_Keypad5: "Num5",
        kVK_ANSI_Keypad6: "Num6", kVK_ANSI_Keypad7: "Num7", kVK_ANSI_Keypad8: "Num8",
        kVK_ANSI_Keypad9: "Num9", kVK_ANSI_KeypadDecimal: "Num.", kVK_ANSI_KeypadMultiply: "Num*",
        kVK_ANSI_KeypadPlus: "Num+", kVK_ANSI_KeypadMinus: "Num-", kVK_ANSI_KeypadDivide: "Num/",
        kVK_ANSI_KeypadEquals: "Num=",
    ]

    /// US-ANSI fallback when the current keyboard layout can't be queried.
    static let ansiKeyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Grave: "`", kVK_ISO_Section: "§",
    ]

    static func name(forKeyCode code: Int) -> String {
        if let name = functionKeyNames[code] ?? specialKeyNames[code] { return name }
        if let char = layoutCharacter(forKeyCode: code), !char.isEmpty { return char.uppercased() }
        return ansiKeyNames[code] ?? "Key \(code)"
    }

    /// Character the key produces in the user's current keyboard layout (no modifiers).
    private static func layoutCharacter(forKeyCode code: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: chars, count: length)
        guard let scalar = string.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespaces.contains(scalar) else { return nil }
        return string
    }
}
