import AppKit
import NoteItSync

/// Whatever runs "Clean up unused storage…": `SyncController` in the app (it holds the folder or bucket access),
/// a spy in tests.
protocol StorageCleaning: Sendable {
    func cleanUpUnusedStorage() async throws -> CleanupReport
}

extension SyncController: StorageCleaning {}

/// The confirmation for Settings → Sync → "Clean Up Unused Storage…" (web-app spec §3.4.9). The engine never runs
/// the cleanup by itself; this alert is the only safeguard, so it says what can be lost.
enum CleanupConfirmation {
    static let title = "Clean up unused storage?"
    static let message = "This removes leftover copies of notes that were never finished saving, for example from a Mac that was erased while it was syncing. Only run this when your other devices are idle. A note being saved on another device at the same moment could be lost if that device is then lost before it syncs again."
    /// Shown under the disabled button on storage without atomic conditional writes (every folder).
    static let unavailableCaption = "Needs storage that supports conditional writes. This storage keeps earlier copies of your notes; to free the space, move sync to a NoteIt server or a compatible S3 bucket."
    static let cancelTitle = "Cancel"
    static let cleanUpTitle = "Clean Up"

    /// Cancel first and the default (Return); Clean Up is destructive and has no key equivalent.
    @MainActor
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let cancel = alert.addButton(withTitle: cancelTitle)
        cancel.keyEquivalent = "\r"
        let cleanUp = alert.addButton(withTitle: cleanUpTitle)
        cleanUp.keyEquivalent = ""
        cleanUp.hasDestructiveAction = true
        return alert
    }

    /// Runs the cleanup only for Clean Up; Cancel, Escape and closing the alert do nothing. Returns the line to show,
    /// or nil when nothing ran.
    static func handle(response: NSApplication.ModalResponse, cleaner: StorageCleaning) async -> String? {
        guard response == .alertSecondButtonReturn else { return nil }
        do {
            return resultText(try await cleaner.cleanUpUnusedStorage())
        } catch SyncError.cleanupUnavailable {
            return unavailableCaption
        } catch {
            return "Couldn’t clean up: \(error.localizedDescription)"
        }
    }

    static func resultText(_ report: CleanupReport) -> String {
        let size = ByteCountFormatter.string(fromByteCount: report.deletedBytes, countStyle: .file)
        return "Removed \(report.deletedObjects) \(report.deletedObjects == 1 ? "item" : "items") (\(size))"
    }
}

/// What Settings shows for the cleanup action.
struct CleanupButtonState: Equatable {
    var isEnabled: Bool
    var caption: String?

    /// Enabled only while sync is connected and the storage has atomic conditional writes.
    init(connected: Bool, available: Bool) {
        isEnabled = connected && available
        caption = connected && !available ? CleanupConfirmation.unavailableCaption : nil
    }
}
