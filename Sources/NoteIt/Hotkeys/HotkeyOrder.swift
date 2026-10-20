import Foundation

/// Program §9's global hotkey order: every planned `HotkeyAction` raw value, including the ones whose owners haven't
/// added the case yet. A case's Carbon hotkey ID is its 1-based position here, so it doesn't depend on merge order.
/// Foundations Task 6.2.
enum HotkeyOrder {
    static let rawValues: [String] = [
        "showMainWindow", "newNote", "quickCapture", "openQuickly", "commandPalette", "captureSelection",
        "openToday", "showTasks", "screenshotToText", "recordVoiceNote", "appendToToday", "askNotes", "cheatSheet",
        "toggleFloatingNotes",
    ]

    /// The 1-based position, or nil when the raw value isn't in the table.
    static func hotkeyID(for rawValue: String) -> UInt32? {
        rawValues.firstIndex(of: rawValue).map { UInt32($0 + 1) }
    }

    /// The raw value at a 1-based position; nil for 0 and anything past the table.
    static func rawValue(for hotkeyID: UInt32) -> String? {
        let index = Int(hotkeyID) - 1
        return rawValues.indices.contains(index) ? rawValues[index] : nil
    }
}
