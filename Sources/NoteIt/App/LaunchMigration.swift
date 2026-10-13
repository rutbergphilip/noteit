import AppKit
import NoteItSync
import ServiceManagement

/// One-time adoption of settings left by Inkwell (NoteIt's former name). The library folder itself
/// is moved by `NoteStore` (see `LibraryMigration`) and keychain secrets on first read (see `Keychain`).
@MainActor
enum LaunchMigration {
    private enum Notice { case approveLoginItem, offerLoginItem }
    private static var pendingNotice: Notice?

    /// `NOTEIT_DATA_DIR` (or, in debug builds, `NOTEIT_APP_SUPPORT_DIR`) points the library elsewhere.
    private static var isIsolatedRun: Bool {
        #if DEBUG
        if AppEnvironment.nonEmpty("APP_SUPPORT_DIR") != nil { return true }
        #endif
        return AppEnvironment.nonEmpty("DATA_DIR") != nil
    }

    private static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Call before anything reads or registers defaults.
    static func run() {
        // Isolated runs never pick up the real Inkwell settings, sync configuration included.
        guard !isIsolatedRun else { return }
        let defaults = UserDefaults.standard
        let legacy = defaults.persistentDomain(forName: AppIdentity.Legacy.bundleID)
        if let copied = DefaultsMigration.migrate(legacyDomain: legacy, into: defaults) {
            if !copied.isEmpty {
                NSLog("NoteIt: adopted %d setting(s) from Inkwell", copied.count)
            }
            if legacy != nil { migrateLoginItem(knownEnabled: copied.contains(PrefKey.launchAtLogin) && defaults.bool(forKey: PrefKey.launchAtLogin)) }
        }
        // Leave a copied value alone until the pending notice has been dealt with.
        if pendingNotice == nil { mirrorLoginItemState() }
    }

    /// The old login item belongs to Inkwell's bundle id, and its state can't be read from here
    /// (SMAppService only reports on this app). Re-register when a mirrored `launchAtLogin` says it
    /// was on (builds that record it); otherwise offer it once, since Inkwell never recorded it.
    private static func migrateLoginItem(knownEnabled: Bool) {
        guard isBundled else { return }
        switch SMAppService.mainApp.status {
        case .enabled:
            return
        case .requiresApproval:
            pendingNotice = .approveLoginItem
        default:
            if knownEnabled { register() }
            // Not known to be on, or the silent re-register failed: ask.
            if pendingNotice == nil, SMAppService.mainApp.status != .enabled { pendingNotice = .offerLoginItem }
        }
    }

    private static func register() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("NoteIt: couldn't register launch at login: \(error)")
        }
        if SMAppService.mainApp.status == .requiresApproval { pendingNotice = .approveLoginItem }
    }

    /// Keeps `launchAtLogin` current so a future identity change can re-register without asking.
    private static func mirrorLoginItemState() {
        guard isBundled else { return }
        let status = SMAppService.mainApp.status
        UserDefaults.standard.set(status == .enabled || status == .requiresApproval, forKey: PrefKey.launchAtLogin)
    }

    /// Shows the one-time login item notice, if migration left one.
    static func presentPendingNotices() {
        guard let notice = pendingNotice else { return }
        pendingNotice = nil
        let alert = NSAlert()
        NSApp.activate()
        switch notice {
        case .approveLoginItem:
            alert.messageText = "Allow NoteIt in Login Items"
            alert.informativeText = "NoteIt was set to open at login. Allow it in System Settings › General › Login Items to keep it that way."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
        case .offerLoginItem:
            alert.messageText = "Open NoteIt at Login?"
            alert.informativeText = "Your notes and settings moved over with the new name. Launch at login has to be turned on again. You can change it later in Settings › General."
            alert.addButton(withTitle: "Open at Login")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            register()
            mirrorLoginItemState()
            if pendingNotice != nil { presentPendingNotices() }
        }
    }
}
