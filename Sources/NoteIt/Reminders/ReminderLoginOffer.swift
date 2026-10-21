import Foundation
import ServiceManagement

/// Reminders only ring while NoteIt runs, so the first reminder added offers Open at Login once. Nothing is turned on
/// unless the user accepts.
@MainActor
enum ReminderLoginOffer {
    static func shouldOffer(alreadyOffered: Bool, isBundled: Bool, status: SMAppService.Status) -> Bool {
        !alreadyOffered && isBundled && status != .enabled && status != .requiresApproval
    }

    /// True the first time it's asked while Open at Login is off; later calls are false.
    static func take(_ defaults: UserDefaults = .standard) -> Bool {
        let isBundled = Bundle.main.bundleURL.pathExtension == "app"
        guard shouldOffer(alreadyOffered: defaults.bool(forKey: PrefKey.reminderLoginOffered), isBundled: isBundled,
                          status: isBundled ? SMAppService.mainApp.status : .notRegistered) else { return false }
        defaults.set(true, forKey: PrefKey.reminderLoginOffered)
        return true
    }

    static func accept() {
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: PrefKey.launchAtLogin)
        } catch {
            NSLog("NoteIt: couldn't turn on Open at Login: \(error.localizedDescription)")
        }
    }
}
