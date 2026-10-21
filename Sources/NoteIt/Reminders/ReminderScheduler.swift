import AppKit
import Combine
import CoreGraphics
import NoteItCore

@MainActor
protocol ReminderNotifying: AnyObject {
    var isAvailable: Bool { get }
    func requestAuthorization() async -> Bool
    func deliver(_ reminder: LiveReminder, title: String, subtitle: String)
    func withdraw(_ ids: [UUID])
}

/// Decides whether this Mac shows a reminder when several Macs share a sync store.
@MainActor
protocol ReminderClaiming: AnyObject {
    func shouldDeliver(_ id: UUID, at: Date, userActive: Bool) async -> Bool
}

/// Keeps one timer for the next live reminder and delivers reminders due since the last check (spec 7.2).
@MainActor
final class ReminderScheduler {
    static let catchUpWindow: TimeInterval = 24 * 60 * 60
    /// Re-checks at least this often, so a timer stretched by sleep or a clock change can't run late for long.
    static let maxTimerInterval: TimeInterval = 15 * 60

    private let store: NoteStore
    private let notifications: ReminderNotifying
    private let claims: ReminderClaiming?
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let calendar: () -> Calendar
    private let userActive: () -> Bool

    /// Shown in this session and not handled yet; withdrawn when the reminder stops being live.
    private(set) var delivered: Set<UUID> = []
    private(set) var nextFireDate: Date?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var storeSubscription: AnyCancellable?
    private var lastIndexVersion = -1
    private var isStarted = false

    init(store: NoteStore, notifications: ReminderNotifying, claims: ReminderClaiming?, defaults: UserDefaults,
         clock: @escaping () -> Date, calendar: @escaping () -> Calendar = { .current },
         userActive: @escaping () -> Bool = ReminderScheduler.userWasActiveRecently) {
        self.store = store
        self.notifications = notifications
        self.claims = claims
        self.defaults = defaults
        self.clock = clock
        self.calendar = calendar
        self.userActive = userActive
    }

    var isEnabled: Bool {
        defaults.object(forKey: PrefKey.remindersEnabled) as? Bool ?? PrefDefault.remindersEnabled
    }

    /// End of the last checked window; missing means nothing was checked yet on this Mac.
    var lastCheck: Date? {
        get { defaults.object(forKey: PrefKey.remindersLastCheck) as? Date }
        set { defaults.set(newValue, forKey: PrefKey.remindersLastCheck) }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if lastCheck == nil { lastCheck = clock() }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check() }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, UserDefaults.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    if note.name == UserDefaults.didChangeNotification { self?.rearm() } else { self?.check() }
                }
            })
        }
        storeSubscription = store.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.store.searchIndexer.version != self.lastIndexVersion else { return }
                self.rearm()
            }
        check()
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
        storeSubscription = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    /// Delivers live reminders due in (lastCheck, now] and less than a day old, then moves `lastCheck` to now.
    func check() {
        let now = clock()
        let since = max(lastCheck ?? now, now.addingTimeInterval(-Self.catchUpWindow))
        let due = isEnabled ? store.liveReminders(calendar: calendar()).filter { $0.fireDate > since && $0.fireDate <= now } : []
        lastCheck = now
        for reminder in due where !delivered.contains(reminder.id) {
            if let claims {
                let active = userActive()
                Task { @MainActor [weak self] in
                    guard await claims.shouldDeliver(reminder.id, at: reminder.fireDate, userActive: active) else { return }
                    self?.deliverIfLive(reminder.id)
                }
            } else {
                deliver(reminder)
            }
        }
        rearm()
    }

    /// Withdraws handled reminders and sets the timer for the next one.
    func rearm() {
        lastIndexVersion = store.searchIndexer.version
        let live = isEnabled ? store.liveReminders(calendar: calendar()) : []
        let stale = delivered.subtracting(live.map(\.id))
        if !stale.isEmpty {
            delivered.subtract(stale)
            notifications.withdraw(stale.sorted { $0.uuidString < $1.uuidString })
        }
        timer?.invalidate()
        timer = nil
        let now = clock()
        let since = lastCheck ?? now
        nextFireDate = live.first { $0.fireDate > since }?.fireDate
        guard isStarted, let next = nextFireDate else { return }
        let interval = min(max(next.timeIntervalSince(now), 0), Self.maxTimerInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func deliverIfLive(_ id: UUID) {
        guard isEnabled, !delivered.contains(id),
              let reminder = store.liveReminders(calendar: calendar()).first(where: { $0.id == id }) else { return }
        deliver(reminder)
    }

    private func deliver(_ reminder: LiveReminder) {
        delivered.insert(reminder.id)
        let title = reminder.line.text.isEmpty ? "Reminder" : reminder.line.text
        notifications.deliver(reminder, title: title, subtitle: store.note(with: reminder.noteID)?.displayTitle ?? "")
    }

    /// True when the user touched the keyboard, mouse or trackpad in the last 2 minutes.
    nonisolated static func userWasActiveRecently() -> Bool {
        guard let any = CGEventType(rawValue: UInt32.max) else { return true }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) < 120
    }
}
