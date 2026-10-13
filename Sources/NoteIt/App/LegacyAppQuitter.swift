import AppKit
import NoteItSync

/// Gets a running Inkwell (NoteIt's former name) to quit before its library is moved; otherwise its
/// next save would recreate the old folder and edits would land there.
@MainActor
enum LegacyAppQuitter {
    static var bundleID: String {
        #if DEBUG
        // Debug-only: stand in a harmless app for Inkwell to exercise this flow.
        if let id = AppEnvironment.nonEmpty("DEBUG_LEGACY_BUNDLE_ID") { return id }
        #endif
        return AppIdentity.Legacy.bundleID
    }

    private static var instances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { app in
            !app.isTerminated && (kill(app.processIdentifier, 0) == 0 || errno == EPERM)
        }
    }

    static func isRunning() -> Bool { !instances.isEmpty }

    enum Reason {
        /// At launch, before Inkwell's library moves to NoteIt.
        case moveNotes
        /// While NoteIt runs, when Inkwell would open the library NoteIt has open.
        case sharedLibrary
    }

    private static var isAsking = false

    /// Asks before quitting Inkwell, waits for it to exit, and offers Force Quit only after a timeout.
    /// Returns `true` once Inkwell is gone, `false` if the user chose to quit NoteIt instead.
    static func quit(reason: Reason, timeout: TimeInterval = 15) -> Bool {
        guard !isAsking else { return !isRunning() }
        isAsking = true
        defer { isAsking = false }
        _ = NSApplication.shared
        var timedOut = false
        while isRunning() {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            // These name the old app on purpose: it's Inkwell that has to quit.
            if timedOut {
                alert.messageText = "Inkwell didn't quit"
                alert.informativeText = "Check Inkwell for an open dialog, then try again. Force quitting loses any changes Inkwell hasn't saved yet."
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Force Quit Inkwell")
                alert.addButton(withTitle: "Quit NoteIt")
            } else if reason == .moveNotes {
                alert.messageText = "Quit Inkwell to move your notes to NoteIt"
                alert.informativeText = "Inkwell is still open. NoteIt moves your notes over once Inkwell quits, so no edits are left behind."
                alert.addButton(withTitle: "Quit Inkwell")
                alert.addButton(withTitle: "Quit NoteIt")
            } else {
                alert.messageText = "Quit Inkwell to keep your changes safe"
                alert.informativeText = "Inkwell opened the same notes NoteIt has open. With both running, one can overwrite the other's changes."
                alert.addButton(withTitle: "Quit Inkwell")
                alert.addButton(withTitle: "Quit NoteIt")
            }
            let response = runModalUntilLegacyQuits(alert)
            if response == .abort { continue }
            let quitNoteIt: NSApplication.ModalResponse = timedOut ? .alertThirdButtonReturn : .alertSecondButtonReturn
            if response == quitNoteIt { return false }
            if timedOut, response == .alertSecondButtonReturn {
                instances.forEach { $0.forceTerminate() }
                timedOut = !waitForExit(timeout: 5)
            } else {
                instances.forEach { $0.terminate() }
                timedOut = !waitForExit(timeout: timeout)
            }
        }
        return true
    }

    /// Closes the alert by itself if Inkwell quits while it's showing (say, the user quit it by hand).
    private static func runModalUntilLegacyQuits(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !isRunning() { NSApp.stopModal(withCode: .abort) }
            }
        }
        RunLoop.current.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        return alert.runModal()
    }

    private static func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning() { return true }
            // Lets NSRunningApplication update; sleeps in case the run loop has nothing to wait on.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isRunning()
    }
}
