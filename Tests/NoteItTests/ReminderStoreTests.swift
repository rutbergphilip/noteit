import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class ReminderStoreTests: XCTestCase {
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
        root = fm.temporaryDirectory.appendingPathComponent("noteit-reminders-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    private func add(_ store: NoteStore, _ text: String) -> UUID {
        store.createNote(in: nil, initial: NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])).id
    }

    func testLiveRemindersSkipDoneCheckedAndDeleted() throws {
        let store = makeStore()
        let id = add(store, """
        Plan
        call bank @remind(2026-10-21 15:00)
        ☐\tpay rent @remind(2026-10-21 14:00)
        ☑\tbook train @remind(2026-10-21 13:00)
        water plants @remind(2026-10-21 16:00 done)
        """)
        let gone = add(store, "Old\nping @remind(2026-10-21 17:00)")
        store.moveToRecentlyDeleted([gone])

        let live = store.liveReminders(calendar: calendar)
        XCTAssertEqual(live.map(\.line.text), ["pay rent", "call bank"])
        XCTAssertEqual(live.first?.noteID, id)
        XCTAssertEqual(live.first?.id, ReminderIdentity.id(noteID: id, at: LocalDateTime(token: "2026-10-21 14:00")!, lineText: "pay rent"))
    }

    func testDoneChecksTaskOrMarksTokenDone() throws {
        let store = makeStore()
        let id = add(store, "Plan\n☐\tpay rent @remind(2026-10-21 14:00)\ncall bank @remind(2026-10-21 15:00)")
        for reminder in store.liveReminders(calendar: calendar) {
            try store.updateReminder(reminder.id, action: .done, now: now, calendar: calendar)
        }
        XCTAssertEqual(store.body(for: id).string,
                       "Plan\n☑\tpay rent @remind(2026-10-21 14:00)\ncall bank @remind(2026-10-21 15:00 done)")
        XCTAssertTrue(store.liveReminders(calendar: calendar).isEmpty)
    }

    func testSnoozeTomorrowRemoveAndSetRewriteTheToken() throws {
        let store = makeStore()
        let id = add(store, "Plan\ncall bank @remind(2026-10-21 12:00)")
        func only() throws -> LiveReminder { try XCTUnwrap(store.liveReminders(calendar: calendar).first) }

        try store.updateReminder(try only().id, action: .snooze(10 * 60), now: now, calendar: calendar)
        XCTAssertEqual(store.body(for: id).string, "Plan\ncall bank @remind(2026-10-21 12:10)")
        try store.updateReminder(try only().id, action: .tomorrow, now: now, calendar: calendar)
        XCTAssertEqual(store.body(for: id).string, "Plan\ncall bank @remind(2026-10-22 09:00)")
        try store.updateReminder(try only().id, action: .set(LocalDateTime(token: "2026-10-30 08:15")!), now: now, calendar: calendar)
        XCTAssertEqual(store.body(for: id).string, "Plan\ncall bank @remind(2026-10-30 08:15)")
        try store.updateReminder(try only().id, action: .remove, now: now, calendar: calendar)
        XCTAssertEqual(store.body(for: id).string, "Plan\ncall bank")
    }

    func testUpdatingAChangedReminderFails() throws {
        let store = makeStore()
        let id = add(store, "Plan\ncall bank @remind(2026-10-21 12:00)")
        let stale = try XCTUnwrap(store.liveReminders(calendar: calendar).first)
        store.updateBody(id, NSAttributedString(string: "Plan\ncall the bank @remind(2026-10-21 12:00)"))
        XCTAssertThrowsError(try store.updateReminder(stale.id, action: .done, now: now, calendar: calendar)) {
            XCTAssertEqual($0 as? BodyEditError, .taskChanged)
        }
    }

    func testAddReminderAppendsOrReplaces() throws {
        let store = makeStore()
        let id = add(store, "Plan\ncall bank")
        try store.addReminder(noteID: id, paragraph: 1, at: LocalDateTime(token: "2026-10-22 09:00")!)
        XCTAssertEqual(store.body(for: id).string, "Plan\ncall bank @remind(2026-10-22 09:00)")
        try store.addReminder(noteID: id, paragraph: 1, at: LocalDateTime(token: "2026-10-23 10:30")!)
        XCTAssertEqual(store.body(for: id).string, "Plan\ncall bank @remind(2026-10-23 10:30)")
        XCTAssertThrowsError(try store.addReminder(noteID: id, paragraph: 5, at: LocalDateTime(token: "2026-10-23 10:30")!))
    }

    func testReminderDateReadsTheLine() {
        let date = { (line: String) in NoteStore.reminderDate(inLine: line, now: self.now, calendar: self.calendar, defaultMinutes: 9 * 60 + 30) }
        XCTAssertEqual(date("call the supplier tomorrow 9am")?.token, "2026-10-22 09:00")
        XCTAssertEqual(date("☐\tsend invoice fri")?.token, "2026-10-23 09:30")
        XCTAssertNil(date("call the supplier"))
        XCTAssertNil(date("call at 8am today"), "past times don't count")
    }

    func testReminderSetMessage() {
        let at = { (token: String) in LocalDateTime(token: token)! }
        XCTAssertEqual(ReminderSetPopover.message(for: at("2026-10-22 09:00"), now: now, calendar: calendar), "Reminder set for tomorrow at 09:00")
        XCTAssertEqual(ReminderSetPopover.message(for: at("2026-10-21 18:30"), now: now, calendar: calendar), "Reminder set for today at 18:30")
        XCTAssertEqual(ReminderSetPopover.message(for: at("2026-10-30 08:00"), now: now, calendar: calendar), "Reminder set for Fri 30 Oct at 08:00")
    }

    func testNotificationsNeedABundledApp() {
        XCTAssertFalse(ReminderNotifications.isSupported(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier))
        XCTAssertFalse(ReminderNotifications.isSupported(bundleURL: URL(fileURLWithPath: "/usr/bin/noteit"), bundleIdentifier: "app.noteit"))
        XCTAssertTrue(ReminderNotifications.isSupported(bundleURL: URL(fileURLWithPath: "/Applications/NoteIt.app"), bundleIdentifier: "app.noteit"))
    }
}
