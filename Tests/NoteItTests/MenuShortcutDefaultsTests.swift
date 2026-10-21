@testable import NoteIt
import SwiftUI
import XCTest

final class MenuShortcutDefaultsTests: XCTestCase {
    func testExistingDefaultsUnchanged() {
        let expected: [(MenuShortcutCommand, MenuShortcut?)] = [
            (.newNote, MenuShortcut("n", .command)),
            (.newNotebook, MenuShortcut("n", [.shift, .command])),
            (.openQuickly, MenuShortcut("o", .command)),
            (.commandPalette, MenuShortcut("p", [.shift, .command])),
            (.searchNotes, MenuShortcut("f", .command)),
            (.find, MenuShortcut("f", [.option, .command])),
            (.findAndReplace, MenuShortcut("f", [.shift, .command])),
            (.exportNote, MenuShortcut("s", [.shift, .command])),
            (.print, MenuShortcut("p", .command)),
            (.copyAsMarkdown, MenuShortcut("c", [.option, .shift, .command])),
            (.copyNoteLink, MenuShortcut("l", [.control, .command])),
            (.versionHistory, MenuShortcut("y", [.option, .command])),
            (.deleteNote, MenuShortcut(.delete, .command)),
            (.goBack, MenuShortcut(.leftArrow, [.control, .command])),
            (.goForward, MenuShortcut(.rightArrow, [.control, .command])),
            (.linkToNote, MenuShortcut("k", [.shift, .command])),
            (.newNoteFromTemplate, MenuShortcut("n", [.option, .command])),
            (.toggleInspector, MenuShortcut("i", [.option, .command])),
            (.openToday, MenuShortcut("t", [.control, .command])),
            (.dailyNoteForDate, nil),
            (.newSmartFolder, nil),
            (.saveSearchAsSmartFolder, nil),
            (.showTasks, MenuShortcut("t", [.shift, .command])),
            (.setDueDate, MenuShortcut("d", [.shift, .command])),
            (.addReminder, MenuShortcut("r", [.control, .command])),
        ]
        XCTAssertEqual(MenuShortcutCommand.allCases, expected.map(\.0))
        for (command, shortcut) in expected {
            XCTAssertEqual(command.defaultShortcut, shortcut, command.rawValue)
        }
    }

    func testDefaultsAreUnique() {
        var all: [(String, MenuShortcut)] = MenuShortcutCommand.allCases.compactMap { command in command.defaultShortcut.map { (command.rawValue, $0) } }
        all += PlannedMenuShortcuts.rows.compactMap { row in row.shortcut.map { (row.command, $0) } }
        for (index, entry) in all.enumerated() {
            for other in all[(index + 1)...] where other.1 == entry.1 {
                XCTFail("\(entry.0) and \(other.0) both default to \(entry.1.display)")
            }
        }
    }

    func testDefaultsAvoidReservedShortcuts() {
        for row in PlannedMenuShortcuts.rows {
            guard let shortcut = row.shortcut else { continue }
            XCTAssertNil(MenuShortcutRules.reservedName(for: shortcut), "\(row.command): \(shortcut.display)")
            XCTAssertTrue(shortcut.isValid, row.command)
        }
    }

    func testPlannedRowsNotYetCases() {
        for row in PlannedMenuShortcuts.rows {
            XCTAssertNil(MenuShortcutCommand(rawValue: row.command), "\(row.command) is a case now; delete its row")
        }
    }

    func testPlannedCommandsUnique() {
        let commands = PlannedMenuShortcuts.rows.map(\.command)
        XCTAssertEqual(Set(commands).count, commands.count)
        XCTAssertEqual(commands.count, 9)
    }
}
