import AppKit
import NoteItSync
import ServiceManagement

/// One-time adoption of settings left by Inkwell (NoteIt's former name). The library folder itself
/// is moved by `NoteStore` (see `LibraryMigration`) and keychain secrets on first read (see `Keychain`).
@MainActor
enum LaunchMigration {
    private static var loginItemNeedsApproval = false

    /// `NOTEIT_DATA_DIR` (or, in debug builds, `NOTEIT_APP_SUPPORT_DIR`) points the library elsewhere.
    private static var isIsolatedRun: Bool {
        #if DEBUG
        if AppEnvironment.nonEmpty("APP_SUPPORT_DIR") != nil { return true }
        #endif
        return AppEnvironment.nonEmpty("DATA_DIR") != nil
    }

    /// Call before anything reads or registers defaults.
    static func run() {
        // Isolated runs never pick up the real Inkwell settings, sync configuration included.
        guard !isIsolatedRun else { return }
        let defaults = UserDefaults.standard
        let legacy = defaults.persistentDomain(forName: AppIdentity.Legacy.bundleID)
        guard let copied = DefaultsMigration.migrate(legacyDomain: legacy, into: defaults) else { return }
        if !copied.isEmpty {
            NSLog("NoteIt: adopted %d setting(s) from Inkwell", copied.count)
        }
        if copied.contains(PrefKey.launchAtLogin), defaults.bool(forKey: PrefKey.launchAtLogin) {
            reregisterLoginItem()
        }
    }

    /// The old login item belongs to Inkwell's bundle id; register NoteIt in its place.
    private static func reregisterLoginItem() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                NSLog("NoteIt: couldn't re-register launch at login: \(error)")
            }
        }
        loginItemNeedsApproval = service.status == .requiresApproval
    }

    /// Tells the user once if the re-registered login item is waiting for approval.
    static func presentPendingNotices() {
        guard loginItemNeedsApproval else { return }
        loginItemNeedsApproval = false
        let alert = NSAlert()
        alert.messageText = "Allow NoteIt in Login Items"
        alert.informativeText = "NoteIt was set to open at login. Allow it in System Settings › General › Login Items to keep it that way."
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
