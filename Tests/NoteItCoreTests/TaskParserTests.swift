import NoteItCore
import XCTest

final class TaskParserTests: XCTestCase {
    func testTaskLinesAndHashes() {
        let text = "Title\n☐\tSend invoice #work @due(2026-10-21) @due(2026-11-01)\nplain\n☑\tDone thing"
        let (tasks, reminders) = TaskParser.parse(masked: text)
        XCTAssertTrue(reminders.isEmpty)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].paragraph, 1)
        XCTAssertEqual(tasks[0].text, "Send invoice #work @due(2026-10-21) @due(2026-11-01)")
        XCTAssertFalse(tasks[0].checked)
        XCTAssertEqual(tasks[0].due, LocalDateTime(token: "2026-10-21"))
        XCTAssertEqual(tasks[0].textHash, TaskParser.textHash("☐\tSend invoice #work @due(2026-10-21) @due(2026-11-01)"))
        XCTAssertEqual(tasks[0].textHash.count, 64)
        XCTAssertEqual(tasks[1].paragraph, 3)
        XCTAssertTrue(tasks[1].checked)
        XCTAssertNil(tasks[1].due)
    }

    func testReminderOnPlainLine() {
        let (tasks, reminders) = TaskParser.parse(masked: "x\ncall the supplier @remind(2026-10-20 09:00)\n☑\tpay @remind(2026-10-21 10:00 done)")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(reminders.count, 2)
        XCTAssertEqual(reminders[0].text, "call the supplier")
        XCTAssertEqual(reminders[0].paragraph, 1)
        XCTAssertFalse(reminders[0].isTask)
        XCTAssertFalse(reminders[0].done)
        XCTAssertTrue(reminders[1].isTask)
        XCTAssertTrue(reminders[1].checked)
        XCTAssertTrue(reminders[1].done)
        XCTAssertEqual(tasks[0].remind, LocalDateTime(token: "2026-10-21 10:00"))
        XCTAssertTrue(tasks[0].remindDone)
    }

    func testMarkerNeedsTab() {
        XCTAssertTrue(TaskParser.parse(masked: "☐ no tab\n☐").tasks.isEmpty)
    }

    func testDisplayText() {
        XCTAssertEqual(TaskParser.displayText("☐\tBuy  milk @due(2026-10-21) #home"), "Buy milk #home")
    }
}
