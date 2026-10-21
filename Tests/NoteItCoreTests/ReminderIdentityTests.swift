import NoteItCore
import XCTest

final class ReminderIdentityTests: XCTestCase {
    func testReminderIDStableAndV8() throws {
        let note = try XCTUnwrap(UUID(uuidString: "6B1E2F9A-3C4D-4E5F-8A9B-0C1D2E3F4A5B"))
        let at = try XCTUnwrap(LocalDateTime(token: "2026-10-20 09:00"))
        let id = ReminderIdentity.id(noteID: note, at: at, lineText: "call the supplier @remind(2026-10-20 09:00)")
        XCTAssertEqual(id, ReminderIdentity.id(noteID: note, at: at, lineText: "call the supplier"))
        XCTAssertEqual(id.uuidString, "C3E8118C-1DED-8134-B864-29B7C62E2B45")
        let chars = Array(id.uuidString)
        XCTAssertEqual(chars[14], "8")
        XCTAssertTrue("89AB".contains(chars[19]))
        XCTAssertNotEqual(id, ReminderIdentity.id(noteID: note, at: at.withTime(hour: 10, minute: 0), lineText: "call the supplier"))
        XCTAssertNotEqual(id, ReminderIdentity.id(noteID: note, at: at, lineText: "call the client"))
    }
}
