import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

/// foundations Task 4.6: daily-note lookup and DailyLogAppender.
@MainActor
final class DailyNoteStoreTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-daily-\(UUID().uuidString)", isDirectory: true)
        suiteName = "noteit-daily-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        store.preferences = defaults
        return store
    }

    private func day(_ d: Int, hour: Int = 10, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour, minute: minute))!
    }

    private func dailyNotes(_ store: NoteStore) -> [NoteMeta] {
        let id = store.dailyNotesNotebookID(createIfMissing: false)
        return store.notes.filter { $0.notebookID == id && $0.deletedAt == nil }
    }

    private func time(_ date: Date) -> String {
        DailyLogLine.prefix(at: date, timeZone: .current).dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    func testNotebookIsCreatedOnceAndReused() throws {
        let store = makeStore()
        XCTAssertNil(store.dailyNotesNotebookID(createIfMissing: false))
        let id = try XCTUnwrap(store.dailyNotesNotebookID(createIfMissing: true))
        let notebook = try XCTUnwrap(store.notebook(with: id))
        XCTAssertEqual(notebook.name, "Daily Notes")
        XCTAssertEqual(notebook.symbol, "calendar")
        XCTAssertEqual(notebook.colorHex, NotebookPalette.colors.first)
        XCTAssertEqual(defaults.string(forKey: PrefKey.dailyNotesNotebookID), id.uuidString)
        XCTAssertEqual(store.dailyNotesNotebookID(createIfMissing: true), id)
        XCTAssertEqual(store.notebooks.filter { $0.name == "Daily Notes" }.count, 1)

        store.flush()
        XCTAssertEqual(makeStore().dailyNotesNotebookID(createIfMissing: true), id, "reused after relaunch")

        store.deleteNotebook(id)
        let replacement = try XCTUnwrap(store.dailyNotesNotebookID(createIfMissing: true))
        XCTAssertNotEqual(replacement, id, "a deleted notebook is replaced")
    }

    func testSameDayReturnsSameNote() throws {
        let store = makeStore()
        XCTAssertNil(try store.dailyNote(for: day(19), createIfMissing: false))
        let note = try XCTUnwrap(store.dailyNote(for: day(19, hour: 8), createIfMissing: true))
        XCTAssertEqual(note.title, "2026-10-19")
        XCTAssertEqual(try store.dailyNote(for: day(19, hour: 22), createIfMissing: true)?.id, note.id)
        XCTAssertEqual(try store.dailyNote(for: day(19), createIfMissing: false)?.id, note.id)
        XCTAssertNotEqual(try store.dailyNote(for: day(20), createIfMissing: true)?.id, note.id)
        XCTAssertEqual(dailyNotes(store).count, 2)
    }

    func testOldestMatchWins() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.dailyNote(for: day(19), createIfMissing: true))
        let notebookID = try XCTUnwrap(store.dailyNotesNotebookID(createIfMissing: false))
        let later = store.createNote(in: notebookID, initial: NSAttributedString(string: "19 October 2026"))
        XCTAssertGreaterThanOrEqual(later.createdAt, first.createdAt)
        XCTAssertEqual(try store.dailyNote(for: day(19), createIfMissing: true)?.id, first.id)
    }

    func testFormatSwitchFindsExistingNote() throws {
        let store = makeStore()
        defaults.set(DailyTitleFormat.long.rawValue, forKey: PrefKey.dailyNoteTitleFormat)
        let note = try XCTUnwrap(store.dailyNote(for: day(19), createIfMissing: true))
        let longTitle = DailyNoteTitle.title(for: DayKey(year: 2026, month: 10, day: 19), format: .long, locale: .current)
        XCTAssertEqual(note.title, longTitle)

        defaults.set(DailyTitleFormat.weekdayLong.rawValue, forKey: PrefKey.dailyNoteTitleFormat)
        let found = try XCTUnwrap(store.dailyNote(for: day(19), createIfMissing: true))
        XCTAssertEqual(found.id, note.id)
        XCTAssertEqual(store.note(with: note.id)?.title, longTitle)
        XCTAssertEqual(dailyNotes(store).count, 1)
    }

    func testRenamedNoteIsNoLongerFound() throws {
        let store = makeStore()
        let note = try XCTUnwrap(store.dailyNote(for: day(19), createIfMissing: true))
        store.updateBody(note.id, NSAttributedString(string: "Trip planning\n2026-10-19"))
        XCTAssertNil(try store.dailyNote(for: day(19), createIfMissing: false))
        XCTAssertNotEqual(try store.dailyNote(for: day(19), createIfMissing: true)?.id, note.id)
    }

    func testDeletedNoteIsNotReused() throws {
        let store = makeStore()
        let note = try XCTUnwrap(store.dailyNote(for: day(19), createIfMissing: true))
        store.moveToRecentlyDeleted([note.id])
        XCTAssertNil(try store.dailyNote(for: day(19), createIfMissing: false))
        let fresh = try XCTUnwrap(store.dailyNote(for: day(19), createIfMissing: true))
        XCTAssertNotEqual(fresh.id, note.id)
    }

    func testTwoAppendsGiveTwoLinesInOrder() throws {
        let store = makeStore()
        let first = day(19, hour: 9, minute: 5)
        let second = day(19, hour: 14, minute: 30)
        let note = try DailyLogAppender.append(.plain("First\nentry"), to: day(19), in: store, now: first)
        try DailyLogAppender.append(.plain("Second"), to: day(19), in: store, now: second)
        XCTAssertEqual(store.body(for: note.id).string,
                       "2026-10-19\n- \(time(first)) First entry\n- \(time(second)) Second")
        XCTAssertEqual(store.versions(of: note.id).count, 2, "each append records the current body once")
        XCTAssertEqual(dailyNotes(store).count, 1)
    }

    func testTimestampOff() throws {
        let store = makeStore()
        let note = try DailyLogAppender.append(.plain("Idea"), timestamp: false, to: day(19), in: store)
        XCTAssertEqual(store.body(for: note.id).string, "2026-10-19\n- Idea")
    }

    func testAppendAfterTrailingNewlineAddsNoBlankLine() throws {
        let store = makeStore()
        let note = try XCTUnwrap(store.dailyNote(for: day(19), createIfMissing: true))
        store.updateBody(note.id, NSAttributedString(string: "2026-10-19\n"))
        try DailyLogAppender.append(.plain("Idea"), timestamp: false, to: day(19), in: store)
        XCTAssertEqual(store.body(for: note.id).string, "2026-10-19\n- Idea")
    }

    func testAttributedKeepsFormatting() throws {
        let store = makeStore()
        let bold = NSFont.boldSystemFont(ofSize: 15)
        let text = NSMutableAttributedString(string: " \n plain ", attributes: EditorStyle.bodyAttributes)
        text.append(NSAttributedString(string: "bold", attributes: [.font: bold]))
        text.append(NSAttributedString(string: " \n\t", attributes: EditorStyle.bodyAttributes))
        let now = day(19, hour: 0, minute: 5)
        let note = try DailyLogAppender.append(.attributed(text), to: day(19), in: store, now: now)
        let body = store.body(for: note.id)
        let prefix = "- \(time(now)) "
        XCTAssertEqual(body.string, "2026-10-19\n\(prefix)plain bold")
        let boldRange = (body.string as NSString).range(of: "bold")
        let font = body.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let prefixFont = body.attribute(.font, at: (body.string as NSString).range(of: prefix).location,
                                        effectiveRange: nil) as? NSFont
        XCTAssertFalse(prefixFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testEmptyContentThrowsBeforeCreatingANote() throws {
        let store = makeStore()
        XCTAssertThrowsError(try DailyLogAppender.append(.plain(" \n\t "), to: day(19), in: store)) {
            XCTAssertEqual($0 as? DailyLogError, .emptyText)
        }
        XCTAssertThrowsError(try DailyLogAppender.append(.attributed(NSAttributedString(string: "\n  \n")), to: day(19), in: store)) {
            XCTAssertEqual($0 as? DailyLogError, .emptyText)
        }
        XCTAssertNil(store.dailyNotesNotebookID(createIfMissing: false))
        XCTAssertTrue(store.notes.isEmpty)
    }
}
