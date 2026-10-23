import AppKit
import NoteItCore
import UserNotifications

/// Reminder notifications through `UNUserNotificationCenter`. Only a bundled app can use it; under `swift run` or in
/// tests `isAvailable` is false and delivery does nothing.
@MainActor
final class ReminderNotifications: NSObject, ObservableObject, ReminderNotifying {
    static let shared = ReminderNotifications()
    static let categoryID = "noteit.reminder"

    enum ActionID: String, CaseIterable {
        case done = "noteit.reminder.done"
        case snooze10 = "noteit.reminder.snooze10"
        case snooze60 = "noteit.reminder.snooze60"
        case tomorrow = "noteit.reminder.tomorrow"

        var title: String {
            switch self {
            case .done: "Done"
            case .snooze10: "Snooze 10 Minutes"
            case .snooze60: "Snooze 1 Hour"
            case .tomorrow: "Tomorrow"
            }
        }

        var action: ReminderAction {
            switch self {
            case .done: .done
            case .snooze10: .snooze(10 * 60)
            case .snooze60: .snooze(60 * 60)
            case .tomorrow: .tomorrow
            }
        }
    }

    let isAvailable: Bool
    /// Nil until the first request or settings check.
    @Published private(set) var isAuthorized: Bool?
    private var configured = false
    private let authorizationStatus: (() async -> UNAuthorizationStatus)?

    /// `authorizationStatus` replaces the system lookup in tests.
    init(appEvents: NotificationCenter = .default, authorizationStatus: (() async -> UNAuthorizationStatus)? = nil) {
        isAvailable = Self.isSupported(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier)
        self.authorizationStatus = authorizationStatus
        super.init()
        // Permission is usually changed in System Settings, so look again whenever the user comes back.
        appEvents.addObserver(self, selector: #selector(appDidBecomeActive),
                              name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        Task { await refreshAuthorization() }
    }

    nonisolated static func isSupported(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        bundleURL.pathExtension == "app" && !(bundleIdentifier ?? "").isEmpty
    }

    private var center: UNUserNotificationCenter? {
        guard isAvailable else { return nil }
        let center = UNUserNotificationCenter.current()
        if !configured {
            configured = true
            center.delegate = self
            let actions = ActionID.allCases.map { UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: []) }
            center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryID, actions: actions,
                                                                     intentIdentifiers: [], options: [])])
        }
        return center
    }

    /// Sets the delegate early, so a click on a notification from before launch reaches the app.
    func configure() {
        _ = center
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        isAuthorized = granted
        return granted
    }

    func refreshAuthorization() async {
        if let authorizationStatus {
            isAuthorized = Self.authorization(for: await authorizationStatus())
            return
        }
        guard let center else { return }
        let settings = await center.notificationSettings()
        isAuthorized = Self.authorization(for: settings.authorizationStatus)
    }

    /// Nil while NoteIt hasn't asked yet, so "Notifications are off" only shows after the user said no.
    nonisolated static func authorization(for status: UNAuthorizationStatus) -> Bool? {
        switch status {
        case .notDetermined: nil
        case .denied: false
        default: true
        }
    }

    func canDeliver() async -> Bool {
        guard let center else { return false }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            isAuthorized = true
            return true
        case .notDetermined:
            return await requestAuthorization()
        default:
            isAuthorized = false
            return false
        }
    }

    func deliver(_ reminder: LiveReminder, title: String, subtitle: String) {
        guard let center else {
            #if DEBUG
            NSLog("NoteIt reminder (notifications unavailable): %@ — %@", title, subtitle)
            #endif
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["noteID": reminder.noteID.uuidString, "paragraph": reminder.line.paragraph]
        let request = UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: nil)
        Task {
            if isAuthorized != true { _ = await requestAuthorization() }
            try? await center.add(request)
        }
    }

    func withdraw(_ ids: [UUID]) {
        guard let center, !ids.isEmpty else { return }
        let strings = ids.map(\.uuidString)
        center.removeDeliveredNotifications(withIdentifiers: strings)
        center.removePendingNotificationRequests(withIdentifiers: strings)
    }

    /// Opens System Settings › Notifications.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    fileprivate static func handle(actionIdentifier: String, reminderID: UUID, noteID: UUID?, paragraph: Int?) {
        let store = NoteStore.shared
        if let action = ActionID(rawValue: actionIdentifier) {
            do {
                try store.updateReminder(reminderID, action: action.action)
                SyncController.shared.requestSoonPass()
            } catch {
                NSSound.beep()
            }
            return
        }
        guard actionIdentifier == UNNotificationDefaultActionIdentifier, let noteID else { return }
        WindowRouter.showMainWindow()
        EditorNavigator.reveal(noteID, paragraph: paragraph ?? 0, inAllNotes: true, store: store)
    }
}

extension ReminderNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let request = response.notification.request
        let info = request.content.userInfo
        let reminderID = UUID(uuidString: request.identifier)
        let noteID = (info["noteID"] as? String).flatMap(UUID.init(uuidString:))
        let paragraph = info["paragraph"] as? Int
        Task { @MainActor in
            if let reminderID {
                ReminderNotifications.handle(actionIdentifier: action, reminderID: reminderID, noteID: noteID, paragraph: paragraph)
            }
            completionHandler()
        }
    }
}
