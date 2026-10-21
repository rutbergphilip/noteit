import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class TaskViewTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    /// Wednesday 2026-10-21 12:00 in Stockholm.
    private var now: Date { LocalDateTime(year: 2026, month: 10, day: 21, hour: 12, minute: 0)!.date(in: calendar)! }

    private func rewrite(_ text: String, minutes: Int = 540) -> String? {
        guard let result = DateTokenAutoFormat.rewrite(text, now: now, calendar: calendar, reminderMinutes: minutes) else {
            return nil
        }
        return (text as NSString).replacingCharacters(in: result.range, with: result.replacement)
    }

    func testClosingParenthesisWritesTheFullDate() {
        XCTAssertEqual(rewrite("☐\tpay rent @due(fri)"), "☐\tpay rent @due(2026-10-23)")
        XCTAssertEqual(rewrite("x @due(tomorrow)"), "x @due(2026-10-22)")
        XCTAssertEqual(rewrite("x @remind(3pm tomorrow)"), "x @remind(2026-10-22 15:00)")
        XCTAssertEqual(rewrite("x @due(10:00 fri)"), "x @due(2026-10-23 10:00)")
        XCTAssertEqual(rewrite("x @due(+3d)"), "x @due(2026-10-24)")
        XCTAssertEqual(rewrite("x @due(next tuesday 14:30)"), "x @due(2026-10-27 14:30)")
    }

    func testMidnightKeepsTheDueDayButEndsItForReminders() {
        XCTAssertEqual(rewrite("x @due(fri at midnight)"), "x @due(2026-10-23)")
        XCTAssertEqual(rewrite("x @due(tomorrow midnight)"), "x @due(2026-10-22)")
        XCTAssertEqual(rewrite("x @due(in 3 days at midnight)"), "x @due(2026-10-24)")
        XCTAssertEqual(rewrite("x @due(midnight tonight)"), "x @due(2026-10-21)")
        XCTAssertEqual(rewrite("x @due(October 23 at midnight)"), "x @due(2026-10-23)")
        XCTAssertEqual(rewrite("x @due(fri 00:00)"), "x @due(2026-10-23 00:00)")
        XCTAssertEqual(rewrite("x @remind(fri at midnight)"), "x @remind(2026-10-24 00:00)")
        XCTAssertEqual(rewrite("x @remind(midnight tonight)"), "x @remind(2026-10-22 00:00)")
    }

    func testReminderWithoutTimeGetsTheDefaultTime() {
        XCTAssertEqual(rewrite("call @remind(tomorrow)", minutes: 570), "call @remind(2026-10-22 09:30)")
        XCTAssertEqual(rewrite("call @remind(tomorrow 9am)"), "call @remind(2026-10-22 09:00)")
        XCTAssertEqual(rewrite("call @remind(tomorrow done)"), "call @remind(2026-10-22 09:00 done)")
    }

    func testFullDatesAndOtherTextAreLeftAlone() {
        XCTAssertNil(rewrite("x @due(2026-10-23)"))
        XCTAssertNil(rewrite("x @due(2026-10-23 09:00)"))
        XCTAssertNil(rewrite("x @due(someday)"))
        XCTAssertNil(rewrite("x @due(fri with Anna)"))
        XCTAssertNil(rewrite("x @due()"))
        XCTAssertNil(rewrite("x (fri)"))
        XCTAssertNil(rewrite("x @due(fri) later"), "only a token just closed by the caret")
    }

    func testParagraphRangeCountsLines() {
        let text = "Title\n☐\tone\n\n☐\ttwo"
        XCTAssertEqual(EditorNavigator.paragraphRange(0, in: text), NSRange(location: 0, length: 5))
        XCTAssertEqual(EditorNavigator.paragraphRange(1, in: text), NSRange(location: 6, length: 5))
        XCTAssertEqual(EditorNavigator.paragraphRange(2, in: text), NSRange(location: 12, length: 0))
        XCTAssertEqual(EditorNavigator.paragraphRange(3, in: text), NSRange(location: 13, length: 5))
        XCTAssertNil(EditorNavigator.paragraphRange(4, in: text))
    }

    private func item(_ paragraph: Int, checked: Bool = false, note: UUID) -> TaskItem {
        let line = TaskLine(paragraph: paragraph, text: "task \(paragraph)", checked: checked, due: nil, remind: nil,
                            remindDone: false, textHash: "h\(paragraph)\(checked)")
        return TaskItem(ref: TaskRef(noteID: note, paragraph: paragraph, textHash: line.textHash), line: line,
                        noteTitle: "Note", notebookID: nil, noteUpdatedAt: now)
    }

    func testCheckedRowStaysInPlaceWhileSettling() {
        let note = UUID()
        let a = item(1, note: note), b = item(2, note: note), c = item(3, note: note)
        var checkedB = item(2, checked: true, note: note)
        checkedB.line.checked = true
        let live: [TaskGroup: [TaskItem]] = [.noDate: [a, c], .completed: [checkedB]]

        let settling = [TaskKey(b.ref): TaskListView.Settling(item: checkedB, group: .noDate, index: 1)]
        let shown = TaskListView.display(live: live, settling: settling)
        XCTAssertEqual(shown.map(\.group), [.noDate])
        XCTAssertEqual(shown[0].items.map(\.ref.paragraph), [1, 2, 3])
        XCTAssertTrue(shown[0].items[1].line.checked)

        let settled = TaskListView.display(live: live, settling: [:])
        XCTAssertEqual(settled.map(\.group), [.noDate, .completed])
    }

    func testEditRefNeverAdoptsAnotherTaskOnTheSameLine() {
        let note = UUID()
        let row = item(2, note: note)
        let inserted = TaskItem(ref: TaskRef(noteID: note, paragraph: 2, textHash: "other"), line: row.line,
                                noteTitle: "Note", notebookID: nil, noteUpdatedAt: now)
        XCTAssertEqual(TaskListView.editRef(for: row, live: [.noDate: [inserted]]), row.ref)

        var moved = row
        moved.ref.paragraph = 4
        XCTAssertEqual(TaskListView.editRef(for: row, live: [.noDate: [inserted, moved]]), moved.ref)
        XCTAssertEqual(TaskListView.editRef(for: row, live: [.noDate: [row, moved]]), row.ref)
    }

    func testDueLabels() {
        let date = { (day: Int, hour: Int?) in LocalDateTime(year: 2026, month: 10, day: day, hour: hour, minute: hour.map { _ in 5 })! }
        XCTAssertEqual(TaskListView.dueLabel(date(21, nil), now: now, calendar: calendar), "Today")
        XCTAssertEqual(TaskListView.dueLabel(date(22, 9), now: now, calendar: calendar), "Tomorrow 09:05")
        XCTAssertEqual(TaskListView.dueLabel(date(20, nil), now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(TaskListView.dueLabel(date(23, nil), now: now, calendar: calendar), "Fri 23 Oct")
    }

    func testTaskChangedMessage() {
        XCTAssertEqual(TaskListView.message(for: BodyEditError.taskChanged), "This task changed. Open the note to edit it.")
    }
}
