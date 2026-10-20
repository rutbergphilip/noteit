import XCTest
import NoteItAPI
@testable import NoteIt

final class AutomationErrorTests: XCTestCase {
    private let all: [AutomationError] = [
        .notFound, .noteTitleNotFound, .noteDeleted, .noteUnreadable, .noteLocked, .notReady, .notebookNotFound,
        .notebookNameNotFound, .invalidInput("Bad title."),
        .revisionMismatch(current: UUID()), .formatUnavailable("rtf"), .tooLarge, .dailyNotesUnavailable, .cancelled,
        .versionNotSaved,
    ]

    func testEveryErrorHasCodeAndMessage() {
        for error in all {
            XCTAssertFalse(error.message.isEmpty, "\(error)")
            XCTAssertFalse(error.callbackCode.isEmpty, "\(error)")
        }
        XCTAssertEqual(AutomationError.notFound.message, "No note with that id.")
        XCTAssertEqual(AutomationError.notebookNotFound.apiCode, .notFound)
        XCTAssertEqual(AutomationError.invalidInput("Bad title.").message, "Bad title.")
        XCTAssertEqual(AutomationError.invalidInput("x").apiCode, .badRequest)
        XCTAssertEqual(AutomationError.revisionMismatch(current: nil).apiCode.httpStatus, 412)
        XCTAssertEqual(AutomationError.noteUnreadable.callbackCode, "note_unreadable")
        XCTAssertEqual(AutomationError.cancelled.callbackCode, "cancelled")
        XCTAssertEqual(AutomationError.versionNotSaved.apiCode.httpStatus, 500)
        XCTAssertEqual(AutomationError.versionNotSaved.message, "Couldn't save a version of the note, so it wasn't changed.")
    }

    func testNotFoundMessagesSayWhatWasLookedUp() {
        XCTAssertEqual(AutomationError.noteTitleNotFound.message, "No note with that title.")
        XCTAssertEqual(AutomationError.notebookNotFound.message, "No notebook with that id.")
        XCTAssertEqual(AutomationError.notebookNameNotFound.message, "No notebook with that name.")
        for error in [AutomationError.noteTitleNotFound, .notebookNameNotFound] {
            XCTAssertEqual(error.apiCode, .notFound)
            XCTAssertEqual(error.callbackCode, "not_found")
        }
    }

    func testLockedAndNotReadyStatuses() {
        XCTAssertEqual(AutomationError.noteLocked.apiCode, .noteLocked)
        XCTAssertEqual(AutomationError.noteLocked.apiCode.httpStatus, 423)
        XCTAssertEqual(AutomationError.notReady.apiCode, .notReady)
        XCTAssertEqual(AutomationError.notReady.apiCode.httpStatus, 503)
        XCTAssertEqual(AutomationError.notReady.message, "NoteIt is still opening your notes. Try again in a moment.")
    }

    func testUnavailableFeaturesAreNotImplemented() {
        XCTAssertEqual(AutomationError.dailyNotesUnavailable.apiCode, .notImplemented)
        XCTAssertEqual(AutomationError.formatUnavailable("rtf").apiCode, .notImplemented)
        XCTAssertEqual(AutomationError.dailyNotesUnavailable.apiCode.httpStatus, 501)
        XCTAssertEqual(AutomationError.dailyNotesUnavailable.message, "Daily notes aren't available in this version.")
        XCTAssertEqual(AutomationError.dailyNotesUnavailable.callbackCode, "not_implemented")
    }
}
