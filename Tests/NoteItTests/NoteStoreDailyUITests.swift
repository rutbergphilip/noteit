import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

@MainActor
final class NoteStoreDailyUITests: XCTestCase {
    private var root: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-dailyui-\(UUID().uuidString)", isDirectory: true)
        suiteName = "noteit-dailyui-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        RichTextEditor.pendingCaret.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        store.preferences = defaults
        store.installLinkIndex()
        return store
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DayKey(year: year, month: month, day: day).date(calendar: DayKey.dailyCalendar(), hour: 12)!
    }

    private func dailyNotes(_ store: NoteStore) -> [NoteMeta] {
        let notebookID = store.dailyNotesNotebookID(createIfMissing: false)
        return store.notes.filter { $0.notebookID == notebookID && $0.deletedAt == nil }
    }

    func testOpenCreatesNotebookAndNoteOnce() {
        let store = makeStore()
        store.openDailyNote(for: date(2026, 10, 19))
        let first = store.selectedNoteID
        XCTAssertNotNil(first)
        store.openDailyNote(for: date(2026, 10, 19))
        XCTAssertEqual(store.selectedNoteID, first)
        XCTAssertEqual(dailyNotes(store).count, 1)
        XCTAssertEqual(store.sortedNotebooks.filter { $0.name == NoteStore.dailyNotesNotebookName }.count, 1)
        XCTAssertEqual(store.selection, .notebook(store.dailyNotesNotebookID(createIfMissing: false)!))
        XCTAssertEqual(store.note(with: first!)?.title, "2026-10-19")
        XCTAssertEqual(store.dailyDay(of: first), DayKey(year: 2026, month: 10, day: 19))
    }

    func testDailyTemplateApplied() throws {
        let store = makeStore()
        let template = store.createTemplate()
        store.updateBody(template.id, NSAttributedString(string: "{{title}}\nPlan: {{cursor}}\n", attributes: EditorStyle.bodyAttributes))
        defaults.set(template.id.uuidString, forKey: PrefKey.dailyNoteTemplateID)
        let meta = try XCTUnwrap(store.dailyNote(for: date(2026, 10, 19), createIfMissing: true))
        XCTAssertEqual(store.body(for: meta.id).string, "2026-10-19\nPlan: \n")
        XCTAssertEqual(RichTextEditor.pendingCaret[meta.id], "2026-10-19\nPlan: ".utf16.count)
        XCTAssertEqual(try store.dailyNote(for: date(2026, 10, 19), createIfMissing: true)?.id, meta.id)
    }

    func testTemplateWithoutTitleLineKeepsDate() throws {
        let store = makeStore()
        let template = store.createTemplate()
        store.updateBody(template.id, NSAttributedString(string: "Journal\n{{cursor}}", attributes: EditorStyle.bodyAttributes))
        defaults.set(template.id.uuidString, forKey: PrefKey.dailyNoteTemplateID)
        let meta = try XCTUnwrap(store.dailyNote(for: date(2026, 10, 19), createIfMissing: true))
        XCTAssertTrue(store.body(for: meta.id).string.hasPrefix("2026-10-19\n"))
        XCTAssertEqual(try store.dailyNote(for: date(2026, 10, 19), createIfMissing: true)?.id, meta.id)
    }

    func testTemplateDateIsTheDay() throws {
        let store = makeStore()
        let template = store.createTemplate()
        store.updateBody(template.id, NSAttributedString(string: "{{title}}\n{{date:yyyy/MM/dd}}", attributes: EditorStyle.bodyAttributes))
        defaults.set(template.id.uuidString, forKey: PrefKey.dailyNoteTemplateID)
        let meta = try XCTUnwrap(store.dailyNote(for: date(2025, 3, 2), createIfMissing: true))
        XCTAssertTrue(store.body(for: meta.id).string.hasSuffix("2025/03/02"), store.body(for: meta.id).string)
    }

    func testAdjacentDailyNotes() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.dailyNote(for: date(2026, 10, 1), createIfMissing: true))
        let b = try XCTUnwrap(store.dailyNote(for: date(2026, 10, 5), createIfMissing: true))
        let c = try XCTUnwrap(store.dailyNote(for: date(2026, 11, 2), createIfMissing: true))
        XCTAssertEqual(store.adjacentDailyNote(to: b.id, forward: false)?.id, a.id)
        XCTAssertEqual(store.adjacentDailyNote(to: b.id, forward: true)?.id, c.id)
        XCTAssertNil(store.adjacentDailyNote(to: a.id, forward: false))
        XCTAssertNil(store.adjacentDailyNote(to: c.id, forward: true))
    }

    func testAdjacentDailyNoteFromSearchStaysSelected() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.dailyNote(for: date(2026, 10, 1), createIfMissing: true))
        let b = try XCTUnwrap(store.dailyNote(for: date(2026, 10, 5), createIfMissing: true))
        store.searchText = "2026-10-05"
        store.selectedNoteID = b.id
        store.openAdjacentDailyNote(to: b.id, forward: false)
        XCTAssertEqual(store.selectedNoteID, a.id)
        XCTAssertTrue(store.notes(for: store.selection, search: store.searchText).contains { $0.id == a.id })
    }

    func testDaysInMonth() throws {
        let store = makeStore()
        _ = try store.dailyNote(for: date(2026, 10, 1), createIfMissing: true)
        _ = try store.dailyNote(for: date(2026, 10, 31), createIfMissing: true)
        _ = try store.dailyNote(for: date(2026, 11, 1), createIfMissing: true)
        XCTAssertEqual(store.dailyNoteDays(inMonthOf: date(2026, 10, 15)),
                       [DayKey(year: 2026, month: 10, day: 1), DayKey(year: 2026, month: 10, day: 31)])
    }

    func testDeletedDailyNoteNotReturned() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.dailyNote(for: date(2026, 10, 1), createIfMissing: true))
        let b = try XCTUnwrap(store.dailyNote(for: date(2026, 10, 2), createIfMissing: true))
        store.deleteNote(a.id)
        XCTAssertNil(store.dailyDay(of: a.id))
        XCTAssertNil(store.adjacentDailyNote(to: b.id, forward: false))
        XCTAssertTrue(store.dailyNoteDays(inMonthOf: date(2026, 10, 1)) == [DayKey(year: 2026, month: 10, day: 2)])
        let again = try XCTUnwrap(store.dailyNote(for: date(2026, 10, 1), createIfMissing: true))
        XCTAssertNotEqual(again.id, a.id)
    }
}
