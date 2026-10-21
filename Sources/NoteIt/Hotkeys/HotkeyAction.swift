import Foundation

/// Actions that can be bound to a global (system-wide) hotkey. All are unbound by default.
/// New cases go in this file in `HotkeyOrder` order and have no default binding.
enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case showMainWindow
    case newNote
    case quickCapture
    case openQuickly
    case commandPalette
    case captureSelection
    case openToday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .showMainWindow: "Show / Hide NoteIt"
        case .newNote: "New Note"
        case .quickCapture: "Quick Capture"
        case .openQuickly: "Open Quickly"
        case .commandPalette: "Command Palette"
        case .captureSelection: "Capture Selection"
        case .openToday: "Open Today's Note"
        }
    }

    var description: String {
        switch self {
        case .showMainWindow: "Bring NoteIt to the front, or hide it if it's already there."
        case .newNote: "Open NoteIt with a fresh note, ready to type."
        case .quickCapture: "Jot something down in a floating panel without leaving your app."
        case .openQuickly: "Find a note, notebook or command from any app."
        case .commandPalette: "Run a NoteIt command from any app."
        case .captureSelection: "Save the text selected in any app as a new note, with a link back to where it came from."
        case .openToday: "Open today's daily note from any app, creating it if needed."
        }
    }

    var symbol: String {
        switch self {
        case .showMainWindow: "macwindow"
        case .newNote: "square.and.pencil"
        case .quickCapture: "bolt.fill"
        case .openQuickly: "magnifyingglass"
        case .commandPalette: "command"
        case .captureSelection: "text.quote"
        case .openToday: "calendar"
        }
    }

    /// Stable Carbon hotkey identifier (non-zero): the case's position in `HotkeyOrder`.
    var hotkeyID: UInt32 { HotkeyOrder.hotkeyID(for: rawValue)! }

    /// nil for an ID whose `HotkeyOrder` entry has no case yet.
    init?(hotkeyID: UInt32) {
        guard let action = HotkeyOrder.rawValue(for: hotkeyID).flatMap(Self.init(rawValue:)) else { return nil }
        self = action
    }
}
