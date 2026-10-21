import SwiftUI

/// The menu commands program §9 plans that aren't `MenuShortcutCommand` cases yet, with their owners and default
/// shortcuts (nil for none), so a test can keep every default unique before the commands exist. Foundations Task 6.1.
/// An owner deletes its row in the task that adds the case and its `defaultShortcut`.
enum PlannedMenuShortcuts {
    struct Row {
        /// The camelCase `MenuShortcutCommand` case name the owner will add.
        let command: String
        let owner: String
        let shortcut: MenuShortcut?
    }

    static let rows: [Row] = [
        Row(command: "lockNote", owner: "sync-security", shortcut: nil),
        Row(command: "removeLock", owner: "sync-security", shortcut: nil),
        Row(command: "lockAllNotes", owner: "sync-security", shortcut: MenuShortcut("l", [.option, .control, .command])),
        Row(command: "togglePin", owner: "surfaces-polish", shortcut: MenuShortcut("p", [.option, .command])),
        Row(command: "openToday", owner: "linking", shortcut: MenuShortcut("t", [.control, .command])),
        Row(command: "dailyNoteForDate", owner: "linking", shortcut: nil),
        Row(command: "newNoteFromTemplate", owner: "linking", shortcut: MenuShortcut("n", [.option, .command])),
        Row(command: "toggleInspector", owner: "linking", shortcut: MenuShortcut("i", [.option, .command])),
        Row(command: "showTasks", owner: "organise", shortcut: MenuShortcut("t", [.shift, .command])),
        Row(command: "setDueDate", owner: "organise", shortcut: MenuShortcut("d", [.shift, .command])),
        Row(command: "addReminder", owner: "organise", shortcut: MenuShortcut("r", [.control, .command])),
        Row(command: "newSmartFolder", owner: "organise", shortcut: nil),
        Row(command: "saveSearchAsSmartFolder", owner: "organise", shortcut: nil),
        Row(command: "askNotes", owner: "private-ai", shortcut: MenuShortcut("a", [.option, .command])),
        Row(command: "createShareLink", owner: "sharing", shortcut: MenuShortcut("l", [.option, .command])),
        Row(command: "zoomIn", owner: "surfaces-polish", shortcut: MenuShortcut("=", [.control, .command])),
        Row(command: "zoomOut", owner: "surfaces-polish", shortcut: MenuShortcut("-", [.control, .command])),
        Row(command: "actualSize", owner: "surfaces-polish", shortcut: MenuShortcut("0", [.control, .command])),
    ]
}
