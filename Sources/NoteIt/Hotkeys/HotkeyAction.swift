import Foundation

/// Actions that can be bound to a global (system-wide) hotkey. All are unbound by default.
enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case showMainWindow
    case newNote
    case quickCapture
    case openQuickly
    case commandPalette
    case captureSelection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .showMainWindow: "Show / Hide NoteIt"
        case .newNote: "New Note"
        case .quickCapture: "Quick Capture"
        case .openQuickly: "Open Quickly"
        case .commandPalette: "Command Palette"
        case .captureSelection: "Capture Selection"
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
        }
    }

    /// Stable Carbon hotkey identifier (non-zero).
    var hotkeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }

    init?(hotkeyID: UInt32) {
        let index = Int(hotkeyID) - 1
        guard Self.allCases.indices.contains(index) else { return nil }
        self = Self.allCases[index]
    }
}
