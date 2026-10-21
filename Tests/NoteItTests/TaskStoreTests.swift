import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class TaskStoreTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar
    }()
    /// Wednesday 2026-10-21 12:00 in Stockholm.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))! }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-tasks-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    private func body(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 14)])
    }

    private func add(_ store: NoteStore, _ text: String) -> UUID {
        store.createNote(in: nil, initial: body(text)).id
    }

    private func texts(_ items: [TaskItem]?) -> [String] {
        (items ?? []).map { TaskParser.displayText($0.line.text) }
    }

    func testGroupsByDueDate() {
        let store = makeStore()
        _ = add(store, """
        Week
        ☐\tlate @due(2026-10-20)
        ☐\tthis morning @due(2026-10-21 08:00)
        ☐\ttoday @due(2026-10-21)
        ☐\tsoon @due(2026-10-28)
        ☐\tfar @due(2026-10-29)
        ☐\twhenever
        ☑\tfinished @due(2026-10-01)
        """)
        let groups = store.tasks(query: "", includeCompleted: false, now: now, calendar: calendar)
        XCTAssertEqual(texts(groups[.overdue]), ["late", "this morning"])
        XCTAssertEqual(texts(groups[.today]), ["today"])
        XCTAssertEqual(texts(groups[.upcoming]), ["soon"])
        XCTAssertEqual(texts(groups[.later]), ["far"])
        XCTAssertEqual(texts(groups[.noDate]), ["whenever"])
        XCTAssertNil(groups[.completed])
        XCTAssertEqual(texts(store.tasks(query: "", includeCompleted: true, now: now, calendar: calendar)[.completed]), ["finished"])
    }

    func testQueryMatchesTaskTextAndLineOrNoteTags() {
        let store = makeStore()
        _ = add(store, "Errands #home\n☐\tbuy milk\n☐\tcall bank #work")
        _ = add(store, "Other\n☐\tbuy bread")
        let all = { (query: String) in
            store.tasks(query: query, includeCompleted: false, now: self.now, calendar: self.calendar).values.flatMap { $0 }
                .map { TaskParser.displayText($0.line.text) }.sorted()
        }
        XCTAssertEqual(all("buy"), ["buy bread", "buy milk"])
        XCTAssertEqual(all("errands"), [], "words match the task, not the note title")
        XCTAssertEqual(all("tag:home"), ["buy milk", "call bank #work"])
        XCTAssertEqual(all("tag:work"), ["buy milk", "call bank #work"], "the note's tags count for each task")
        XCTAssertEqual(all("-tag:home"), ["buy bread"])
    }

    func testLockedNoteTasksAreExcludedAndCantChange() throws {
        let store = makeStore()
        let id = add(store, "Secret\n☐\thidden task")
        let ref = try XCTUnwrap(store.tasks(query: "", includeCompleted: false, now: now, calendar: calendar)[.noDate]?.first).ref
        store.notes[store.noteIndex(id)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        store.refreshDerivedIndexes(for: id)
        XCTAssertTrue(store.tasks(query: "", includeCompleted: true, now: now, calendar: calendar).isEmpty)
        XCTAssertThrowsError(try store.setTaskChecked(ref, true)) { XCTAssertEqual($0 as? BodyEditError, .locked) }
    }

    func testCheckingAClosedNoteMatchesTheEditor() throws {
        let store = makeStore()
        let id = add(store, "List\n☐\tbuy milk\nafter")
        let ref = try XCTUnwrap(store.tasks(query: "", includeCompleted: false, now: now, calendar: calendar)[.noDate]?.first).ref
        try store.setTaskChecked(ref, true)
        let checked = store.body(for: id)
        XCTAssertEqual(checked.string, "List\n☑\tbuy milk\nafter")
        let content = (checked.string as NSString).range(of: "buy milk")
        XCTAssertNotNil(checked.attribute(.strikethroughStyle, at: content.location, effectiveRange: nil))
        XCTAssertNil(checked.attribute(.strikethroughStyle, at: (checked.string as NSString).range(of: "after").location, effectiveRange: nil))
        XCTAssertTrue(store.versions(of: id).isEmpty, "a checkbox click records no version")

        let done = try XCTUnwrap(store.tasks(query: "", includeCompleted: true, now: now, calendar: calendar)[.completed]?.first).ref
        try store.setTaskChecked(done, false)
        let reopened = store.body(for: id)
        XCTAssertEqual(reopened.string, "List\n☐\tbuy milk\nafter")
        XCTAssertNil(reopened.attribute(.strikethroughStyle, at: content.location, effectiveRange: nil))
    }

    func testChangedTaskFailsAndMovedTaskIsFound() throws {
        let store = makeStore()
        let id = add(store, "List\n☐\tbuy milk")
        let ref = try XCTUnwrap(store.tasks(query: "", includeCompleted: false, now: now, calendar: calendar)[.noDate]?.first).ref

        store.updateBody(id, body("List\nintro\n☐\tbuy milk"))
        try store.setTaskChecked(ref, true)
        XCTAssertEqual(store.body(for: id).string, "List\nintro\n☑\tbuy milk")

        store.updateBody(id, body("List\nintro\n☐\tbuy oat milk"))
        XCTAssertThrowsError(try store.setTaskChecked(ref, true)) { XCTAssertEqual($0 as? BodyEditError, .taskChanged) }
    }

    func testSetDueInsertsReplacesAndRemoves() throws {
        let store = makeStore()
        let id = add(store, "List\n☐\tbuy milk\n☐\tpay rent @due(2026-10-01) #home")
        let items = store.tasks(query: "", includeCompleted: false, now: now, calendar: calendar).values.flatMap { $0 }
        let milk = try XCTUnwrap(items.first { $0.line.text == "buy milk" }).ref
        let rent = try XCTUnwrap(items.first { $0.line.text.hasPrefix("pay rent") }).ref

        try store.setDue(milk, LocalDateTime(year: 2026, month: 10, day: 23))
        try store.setDue(rent, LocalDateTime(year: 2026, month: 11, day: 2, hour: 14, minute: 0))
        XCTAssertEqual(store.body(for: id).string, "List\n☐\tbuy milk @due(2026-10-23)\n☐\tpay rent @due(2026-11-02 14:00) #home")

        let updated = store.tasks(query: "", includeCompleted: false, now: now, calendar: calendar).values.flatMap { $0 }
        try store.setDue(try XCTUnwrap(updated.first { $0.line.text.hasPrefix("pay rent") }).ref, nil)
        XCTAssertEqual(store.body(for: id).string, "List\n☐\tbuy milk @due(2026-10-23)\n☐\tpay rent #home")
    }

    func testTasksSelectionKeepsTheNoteOpenedFromIt() {
        let store = makeStore()
        let id = add(store, "Errands\n☐\tbuy milk")
        store.showTasks()
        store.selectedNoteID = id
        store.reconcileSelection()
        XCTAssertEqual(store.selectedNoteID, id)
        store.moveToRecentlyDeleted([id])
        store.reconcileSelection()
        XCTAssertNil(store.selectedNoteID)
    }

    func testFiveThousandNotesTasksUnderBudget() {
        let store = makeStore()
        for index in 0..<5000 {
            _ = add(store, "Note \(index)\n☐\ttask \(index) @due(2026-10-\(10 + index % 20))\n☑\tdone \(index)")
        }
        let start = Date()
        let groups = store.tasks(query: "tag:none OR task", includeCompleted: true, now: now, calendar: calendar)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(groups.values.map(\.count).reduce(0, +), 5000)
        XCTAssertLessThan(elapsed, 1.0)
    }
}
