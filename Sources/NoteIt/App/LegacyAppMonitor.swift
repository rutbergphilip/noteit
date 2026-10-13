import AppKit
import NoteItSync

/// Watches for Inkwell while NoteIt runs. After migration `Application Support/Inkwell` links to
/// NoteIt's library, so a relaunched Inkwell (an old login item, say) would write to the same files;
/// this asks it to quit, or quits NoteIt if the user prefers.
@MainActor
final class LegacyAppMonitor {
    let legacyBundleID: String
    private let isLegacyAppRunning: () -> Bool
    private let sharesLibrary: () -> Bool
    private let quitLegacyApp: () -> Bool
    private let quitNoteIt: () -> Void
    private var observer: NSObjectProtocol?

    init(
        legacyBundleID: String,
        isLegacyAppRunning: @escaping () -> Bool,
        sharesLibrary: @escaping () -> Bool,
        quitLegacyApp: @escaping () -> Bool,
        quitNoteIt: @escaping () -> Void
    ) {
        self.legacyBundleID = legacyBundleID
        self.isLegacyAppRunning = isLegacyAppRunning
        self.sharesLibrary = sharesLibrary
        self.quitLegacyApp = quitLegacyApp
        self.quitNoteIt = quitNoteIt
    }

    /// Observes app launches and checks once for an Inkwell that's already running.
    func start(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard observer == nil else { return }
        observer = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            // Next turn of the run loop: the alert shouldn't run inside notification delivery.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleLaunch(bundleID: bundleID) } }
        }
        check()
    }

    func stop(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }

    func handleLaunch(bundleID: String?) {
        guard bundleID == legacyBundleID else { return }
        check()
    }

    /// Only an Inkwell that would open NoteIt's own library matters; one with a library of its own is left alone.
    func check() {
        guard isLegacyAppRunning(), sharesLibrary() else { return }
        if !quitLegacyApp() { quitNoteIt() }
    }

    static let shared = LegacyAppMonitor(
        legacyBundleID: LegacyAppQuitter.bundleID,
        isLegacyAppRunning: { LegacyAppQuitter.isRunning() },
        sharesLibrary: {
            LibraryMigration.isShared(legacy: LibraryLauncher.live.legacyDirectory, with: NoteStore.shared.rootURL)
        },
        quitLegacyApp: { LegacyAppQuitter.quit(reason: .sharedLibrary) },
        quitNoteIt: { NSApp.terminate(nil) }
    )
}
