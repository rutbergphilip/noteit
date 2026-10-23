import Foundation
import XCTest
@testable import NoteItCore

private struct Doc: SearchDocument {
    var text = ""
    var image = ""
    var title = ""
    var foldedText: [UInt8] { Array(TextFold.fold(text).utf8) }
    var foldedImageText: [UInt8] { Array(TextFold.fold(image).utf8) }
    var foldedTitle: String { TextFold.fold(title) }
    var tags: [String] = []
    var notebookID: UUID?
    var isPinned = false
    var isConflict = false
    var createdAt = Date(timeIntervalSince1970: 0)
    var updatedAt = Date(timeIntervalSince1970: 0)
    var openTaskCount = 0
    var doneTaskCount = 0
    var openDueDates: [LocalDateTime] = []
    var hasLiveReminder = false
    var hasAttachment = false
}

final class QueryEvaluatorTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        c.firstWeekday = 2
        return c
    }()

    /// Monday 2026-10-19 10:00 in Stockholm.
    private var now: Date { LocalDateTime(token: "2026-10-19 10:00")!.date(in: calendar)! }

    private func context(_ tree: NotebookTree = NotebookTree([])) -> QueryContext {
        QueryContext(now: now, calendar: calendar, notebooks: tree)
    }

    private func matches(_ query: String, _ doc: Doc, _ tree: NotebookTree = NotebookTree([])) -> Bool {
        QueryEvaluator.matches(SearchQuery.parse(query), doc, context: context(tree))
    }

    private func at(_ token: String) -> Date { LocalDateTime(token: token)!.date(in: calendar)! }

    func testWordsPhrasesAndNegation() {
        let doc = Doc(text: "Call the Supplier about the budget", title: "Call")
        XCTAssertTrue(matches("supplier BUDGET", doc))
        XCTAssertTrue(matches("\"the supplier\"", doc))
        XCTAssertFalse(matches("\"supplier the\"", doc))
        XCTAssertFalse(matches("-budget", doc))
        XCTAssertTrue(matches("pie OR budget", doc))
        XCTAssertFalse(matches("-(pie OR budget)", doc))
        XCTAssertTrue(matches("upp", doc))
        XCTAssertTrue(matches("", doc))
    }

    func testAccentsAndImageText() {
        XCTAssertTrue(matches("cafe", Doc(text: "Café")))
        XCTAssertTrue(matches("receipt", Doc(text: "x", image: "Receipt total")))
    }

    func testTitleTagAndIsFilters() {
        let doc = Doc(text: "x", title: "Budget 2026", tags: ["work/acme"], isPinned: true, openTaskCount: 1)
        XCTAssertTrue(matches("title:budget", doc))
        XCTAssertFalse(matches("title:x", doc))
        XCTAssertTrue(matches("tag:work", doc))
        XCTAssertTrue(matches("tag:work/acme", doc))
        XCTAssertFalse(matches("tag:wor", doc))
        XCTAssertTrue(matches("is:pinned is:todo", doc))
        XCTAssertFalse(matches("is:done", doc))
        XCTAssertFalse(matches("is:untagged", doc))
        XCTAssertTrue(matches("is:done", Doc(doneTaskCount: 2)))
        XCTAssertTrue(matches("is:untagged is:conflict", Doc(isConflict: true)))
    }

    func testHasFilters() {
        XCTAssertTrue(matches("has:due", Doc(openDueDates: [LocalDateTime(token: "2026-10-21")!])))
        XCTAssertFalse(matches("has:due", Doc()))
        XCTAssertTrue(matches("has:reminder has:attachment", Doc(hasLiveReminder: true, hasAttachment: true)))
    }

    func testNotebookIncludesDescendants() {
        let work = UUID(), clients = UUID(), home = UUID()
        let tree = NotebookTree([NotebookNodeInput(id: work, parentID: nil, sortIndex: 0, name: "Work"),
                                 NotebookNodeInput(id: clients, parentID: work, sortIndex: 0, name: "Clients"),
                                 NotebookNodeInput(id: home, parentID: nil, sortIndex: 1, name: "Home")])
        XCTAssertTrue(matches("notebook:work", Doc(notebookID: clients), tree))
        XCTAssertTrue(matches("in:\"Work/Clients\"", Doc(notebookID: clients), tree))
        XCTAssertFalse(matches("notebook:Home", Doc(notebookID: clients), tree))
        XCTAssertFalse(matches("notebook:Unknown", Doc(notebookID: clients), tree))
        XCTAssertFalse(matches("notebook:Work", Doc(), tree))
    }

    func testEditedFilters() {
        let doc = Doc(createdAt: at("2026-09-01 08:00"), updatedAt: at("2026-10-19 08:00"))
        XCTAssertTrue(matches("edited:today", doc))
        XCTAssertTrue(matches("edited:<3h", doc))
        XCTAssertFalse(matches("edited:<1h", doc))
        XCTAssertTrue(matches("edited:2026-10-19 created:<2026-10-01", doc))
        XCTAssertTrue(matches("created:>30d", doc))
        XCTAssertTrue(matches("edited:>2026-10-18", doc))
        XCTAssertFalse(matches("edited:>2026-10-19", doc))
        XCTAssertTrue(matches("edited:this-week edited:this-month", doc))
        XCTAssertTrue(matches("edited:yesterday", Doc(updatedAt: at("2026-10-18 23:00"))))
        XCTAssertTrue(matches("edited:last-week", Doc(updatedAt: at("2026-10-18 23:00"))))
        XCTAssertFalse(matches("edited:this-week", Doc(updatedAt: at("2026-10-18 23:00"))))
    }

    func testThisWeekFollowsFirstWeekday() {
        calendar.firstWeekday = 1
        // With Sunday first, Sunday the 18th is in this week.
        XCTAssertTrue(matches("edited:this-week", Doc(updatedAt: at("2026-10-18 23:00"))))
    }

    func testDueFilters() {
        func due(_ tokens: String...) -> Doc { Doc(openDueDates: tokens.map { LocalDateTime(token: $0)! }) }
        XCTAssertTrue(matches("due:today", due("2026-10-19")))
        XCTAssertTrue(matches("due:overdue", due("2026-10-18")))
        XCTAssertFalse(matches("due:overdue", due("2026-10-19")))
        XCTAssertTrue(matches("due:overdue", due("2026-10-19 09:00")))
        XCTAssertTrue(matches("due:<7d", due("2026-10-26")))
        XCTAssertFalse(matches("due:<7d", due("2026-10-27")))
        XCTAssertFalse(matches("due:<7d", due("2026-10-18")))
        XCTAssertTrue(matches("due:>7d", due("2026-10-27")))
        XCTAssertTrue(matches("due:2026-10-21", due("2026-10-21 14:00")))
        XCTAssertFalse(matches("due:today", Doc()))
    }
}
