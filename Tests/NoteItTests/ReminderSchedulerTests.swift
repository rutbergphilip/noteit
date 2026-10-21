import AppKit
import NoteItCore
import NoteItSync
import XCTest
@testable import NoteIt

@MainActor
private final class FakeNotifications: ReminderNotifying {
    var isAvailable = true
    var delivered: [(id: UUID, title: String, subtitle: String)] = []
    var withdrawn: [UUID] = []
    func requestAuthorization() async -> Bool { true }
    func deliver(_ reminder: LiveReminder, title: String, subtitle: String) { delivered.append((reminder.id, title, subtitle)) }
    func withdraw(_ ids: [UUID]) { withdrawn += ids }
}

@MainActor
private final class FakeClaims: ReminderClaiming {
    var answer = true
    var asked: [(UUID, Bool)] = []
    func shouldDeliver(_ id: UUID, at: Date, userActive: Bool) async -> Bool {
        asked.append((id, userActive))
        return answer
    }
}

@MainActor
final class ReminderSchedulerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let fm = FileManager.default
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar
    }()
    private var now: Date!
    private var store: NoteStore!
    private var notifications: FakeNotifications!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-scheduler-\(UUID().uuidString)", isDirectory: true)
        suite = "noteit-scheduler-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        now = at(12, 0)
        store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        notifications = FakeNotifications()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? fm.removeItem(at: root)
    }

    /// 2026-10-21 at the time, Stockholm, plus `days`.
    private func at(_ hour: Int, _ minute: Int, days: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 21 + days, hour: hour, minute: minute))!
    }

    private func makeScheduler(claims: ReminderClaiming? = nil) -> ReminderScheduler {
        ReminderScheduler(store: store, notifications: notifications, claims: claims, defaults: defaults,
                          clock: { [unowned self] in self.now }, calendar: { [unowned self] in self.calendar }, userActive: { true })
    }

    private func add(_ text: String) -> UUID {
        store.createNote(in: nil, initial: NSAttributedString(string: text)).id
    }

    func testFiresAtTheTime() {
        _ = add("Plan\ncall bank @remind(2026-10-21 12:30)")
        let scheduler = makeScheduler()
        defaults.set(now, forKey: PrefKey.remindersLastCheck)
        scheduler.check()
        XCTAssertTrue(notifications.delivered.isEmpty)
        XCTAssertEqual(scheduler.nextFireDate, at(12, 30))

        now = at(12, 30)
        scheduler.check()
        XCTAssertEqual(notifications.delivered.map(\.title), ["call bank"])
        XCTAssertEqual(notifications.delivered.first?.subtitle, "Plan")
        scheduler.check()
        XCTAssertEqual(notifications.delivered.count, 1, "delivered once")
    }

    func testCatchUpOnlyWithinADay() {
        _ = add("Plan\nold @remind(2026-10-19 13:00)\nrecent @remind(2026-10-20 13:00)\nbefore last check @remind(2026-10-18 09:00)")
        defaults.set(at(8, 0, days: -3), forKey: PrefKey.remindersLastCheck)
        makeScheduler().check()
        XCTAssertEqual(notifications.delivered.map(\.title), ["recent"])
        XCTAssertEqual(defaults.object(forKey: PrefKey.remindersLastCheck) as? Date, now)
    }

    func testFirstRunDoesNotDeliverThePast() {
        _ = add("Plan\nrecent @remind(2026-10-21 11:00)")
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        XCTAssertTrue(notifications.delivered.isEmpty)
    }

    func testReminderIndexedAfterLaunchCheckStillRings() throws {
        let id = add("Plan\ncall bank @remind(2026-10-21 11:00)")
        let meta = try XCTUnwrap(store.note(with: id))
        let body = store.body(for: id)
        store.searchIndexer.noteRemoved(id)
        defaults.set(at(10, 0), forKey: PrefKey.remindersLastCheck)
        let scheduler = makeScheduler()
        scheduler.check()
        XCTAssertTrue(notifications.delivered.isEmpty)
        XCTAssertEqual(defaults.object(forKey: PrefKey.remindersLastCheck) as? Date, at(10, 0), "kept until the index caught up")

        now = at(12, 5)
        store.searchIndexer.noteChanged(meta, body: body)
        scheduler.indexChanged()
        XCTAssertEqual(notifications.delivered.map(\.title), ["call bank"])
        XCTAssertEqual(defaults.object(forKey: PrefKey.remindersLastCheck) as? Date, now)
    }

    func testDoneTaskIsNotLive() {
        _ = add("Plan\n☑\tpay rent @remind(2026-10-21 11:00)")
        defaults.set(at(10, 0), forKey: PrefKey.remindersLastCheck)
        makeScheduler().check()
        XCTAssertTrue(notifications.delivered.isEmpty)
    }

    func testWithdrawsWhenTheTokenChanges() throws {
        _ = add("Plan\ncall bank @remind(2026-10-21 11:00)")
        defaults.set(at(10, 0), forKey: PrefKey.remindersLastCheck)
        let scheduler = makeScheduler()
        scheduler.check()
        let id = try XCTUnwrap(notifications.delivered.first?.id)
        try store.updateReminder(id, action: .snooze(600), now: now, calendar: calendar)
        scheduler.rearm()
        XCTAssertEqual(notifications.withdrawn, [id])
        XCTAssertEqual(scheduler.nextFireDate, at(12, 10))
    }

    func testLockingWithdrawsReminder() throws {
        let note = add("Plan\ncall bank @remind(2026-10-21 11:00)")
        defaults.set(at(10, 0), forKey: PrefKey.remindersLastCheck)
        let scheduler = makeScheduler()
        scheduler.check()
        let id = try XCTUnwrap(notifications.delivered.first?.id)
        store.searchIndexer.noteRemoved(note)
        scheduler.rearm()
        XCTAssertEqual(notifications.withdrawn, [id])
    }

    func testDisabledDeliversNothing() {
        _ = add("Plan\ncall bank @remind(2026-10-21 11:00)")
        defaults.set(at(10, 0), forKey: PrefKey.remindersLastCheck)
        defaults.set(false, forKey: PrefKey.remindersEnabled)
        let scheduler = makeScheduler()
        scheduler.check()
        XCTAssertTrue(notifications.delivered.isEmpty)
        XCTAssertNil(scheduler.nextFireDate)
    }

    func testClaimDecidesDelivery() async {
        _ = add("Plan\ncall bank @remind(2026-10-21 11:00)\npay rent @remind(2026-10-21 11:30)")
        defaults.set(at(10, 0), forKey: PrefKey.remindersLastCheck)
        let claims = FakeClaims()
        claims.answer = false
        makeScheduler(claims: claims).check()
        for _ in 0..<20 where claims.asked.count < 2 { await Task.yield() }
        XCTAssertEqual(claims.asked.count, 2)
        XCTAssertTrue(claims.asked.allSatisfy(\.1))
        XCTAssertTrue(notifications.delivered.isEmpty)

        claims.answer = true
        claims.asked = []
        defaults.set(at(10, 0), forKey: PrefKey.remindersLastCheck)
        let scheduler = makeScheduler(claims: claims)
        scheduler.check()
        for _ in 0..<20 where notifications.delivered.count < 2 { await Task.yield() }
        XCTAssertEqual(Set(notifications.delivered.map(\.title)), ["call bank", "pay rent"])
    }

    func testIdleMacWaitsAndAlreadyClaimedIsNotShown() async {
        var slept: [TimeInterval] = []
        var outcome: ClaimOutcome? = .claimed
        let claims = ReminderClaims(claim: { _, _ in outcome }, sleep: { slept.append($0) })
        let shownActive = await claims.shouldDeliver(UUID(), at: now, userActive: true)
        XCTAssertTrue(shownActive)
        XCTAssertEqual(slept, [])
        outcome = .alreadyClaimed
        let shownIdle = await claims.shouldDeliver(UUID(), at: now, userActive: false)
        XCTAssertFalse(shownIdle)
        XCTAssertEqual(slept, [ReminderClaims.idleDelay])
        outcome = .unavailable("offline")
        let shownOffline = await claims.shouldDeliver(UUID(), at: now, userActive: true)
        XCTAssertTrue(shownOffline)
        outcome = nil
        let shownWithoutSync = await claims.shouldDeliver(UUID(), at: now, userActive: true)
        XCTAssertTrue(shownWithoutSync)
    }

    func testTwoMacsShowTheReminderOnce() async {
        _ = add("Plan\ncall bank @remind(2026-10-21 11:00)")
        var claimed: Set<UUID> = []
        let claim: (UUID, Date) async -> ClaimOutcome? = { id, _ in claimed.insert(id).inserted ? .claimed : .alreadyClaimed }
        let other = FakeNotifications()
        let otherDefaults = UserDefaults(suiteName: suite + "-b")!
        defer { otherDefaults.removePersistentDomain(forName: suite + "-b") }
        for target in [defaults!, otherDefaults] { target.set(at(10, 0), forKey: PrefKey.remindersLastCheck) }
        let first = ReminderScheduler(store: store, notifications: notifications, claims: ReminderClaims(claim: claim, sleep: { _ in }),
                                      defaults: defaults, clock: { [unowned self] in self.now }, calendar: { [unowned self] in self.calendar },
                                      userActive: { true })
        let second = ReminderScheduler(store: store, notifications: other, claims: ReminderClaims(claim: claim, sleep: { _ in }),
                                       defaults: otherDefaults, clock: { [unowned self] in self.now }, calendar: { [unowned self] in self.calendar },
                                       userActive: { false })
        first.check()
        second.check()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(notifications.delivered.count + other.delivered.count, 1)
        XCTAssertEqual(notifications.delivered.count, 1)
    }

    func testNotAvailableUnderSwiftTest() {
        XCTAssertFalse(ReminderNotifications.shared.isAvailable)
    }
}
