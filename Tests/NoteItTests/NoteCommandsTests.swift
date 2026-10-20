@testable import NoteIt
import XCTest

final class NoteCommandsTests: XCTestCase {
    func testOrderMatchesProgram() {
        XCTAssertEqual(NoteCommands.order,
                       ["togglePin", "lockNote", "removeLock", "lockAllNotes", "versionHistory", "deleteNote"])
    }

    func testVersionHistoryBeforeDelete() throws {
        let history = try XCTUnwrap(NoteCommands.order.firstIndex(of: "versionHistory"))
        let delete = try XCTUnwrap(NoteCommands.order.firstIndex(of: "deleteNote"))
        XCTAssertLessThan(history, delete)
    }

    func testEveryIDIsACommandOrPlanned() {
        let known = Set(MenuShortcutCommand.allCases.map(\.rawValue)).union(PlannedMenuShortcuts.rows.map(\.command))
        for id in NoteCommands.order {
            XCTAssertTrue(known.contains(id), id)
        }
    }
}
