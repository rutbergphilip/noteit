import AppKit
import NoteItSync
import XCTest
@testable import NoteIt

/// web-app Task 0.4: "Clean up unused storage…" asks first, in the spec's words, and runs only on Clean Up.
@MainActor
final class CleanupConfirmationTests: XCTestCase {
    /// Copied from spec §3.4.9, so a wording change has to touch both.
    private let specMessage = "This removes leftover copies of notes that were never finished saving, for example from a Mac that was erased while it was syncing. Only run this when your other devices are idle. A note being saved on another device at the same moment could be lost if that device is then lost before it syncs again."
    private let specCaption = "Needs storage that supports conditional writes. This storage keeps earlier copies of your notes; to free the space, move sync to a NoteIt server or a compatible S3 bucket."

    actor SpyCleaner: StorageCleaning {
        private(set) var calls = 0
        func cleanUpUnusedStorage() async throws -> CleanupReport {
            calls += 1
            return CleanupReport(deletedObjects: 2, deletedBytes: 3_000_000)
        }
    }

    func testAlertWordingAndButtons() {
        let alert = CleanupConfirmation.makeAlert()
        XCTAssertEqual(alert.messageText, "Clean up unused storage?")
        XCTAssertEqual(alert.informativeText, specMessage)
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Clean Up"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "Return cancels")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
        XCTAssertEqual(CleanupConfirmation.unavailableCaption, specCaption)
    }

    func testOnlyCleanUpRunsTheCleanup() async {
        let spy = SpyCleaner()
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .cancel, .abort, .stop] {
            let result = await CleanupConfirmation.handle(response: response, cleaner: spy)
            XCTAssertNil(result)
        }
        let none = await spy.calls
        XCTAssertEqual(none, 0, "Cancel, Escape and closing the alert do nothing")
        let result = await CleanupConfirmation.handle(response: .alertSecondButtonReturn, cleaner: spy)
        let once = await spy.calls
        XCTAssertEqual(once, 1)
        XCTAssertTrue(result?.hasPrefix("Removed 2 items (") == true, result ?? "nil")
    }

    func testButtonStateFollowsTheStorage() {
        XCTAssertEqual(CleanupButtonState(connected: true, available: false), CleanupButtonState(connected: true, available: false))
        let unavailable = CleanupButtonState(connected: true, available: false)
        XCTAssertFalse(unavailable.isEnabled)
        XCTAssertEqual(unavailable.caption, specCaption)
        let available = CleanupButtonState(connected: true, available: true)
        XCTAssertTrue(available.isEnabled)
        XCTAssertNil(available.caption)
        XCTAssertFalse(CleanupButtonState(connected: false, available: true).isEnabled)
    }

    func testNoteItServerPreset() {
        let preset = SyncProvider.noteItServer
        XCTAssertEqual(preset.displayName, "NoteIt Server")
        XCTAssertEqual(preset.endpointTemplate, "https://<host>/s3")
        XCTAssertTrue(preset.defaultPathStyle)
        XCTAssertEqual(preset.defaultBucket, "noteit")
        XCTAssertEqual(preset.defaultRegion, "us-east-1")
        XCTAssertEqual(preset.helpText, "Create an access key in the NoteIt web app under Settings → Account → S3 Access Keys. Each person uses their own key and their own sync passphrase.")
        XCTAssertTrue(preset.isS3)
        XCTAssertNil(SyncProvider.awsS3.defaultBucket)
    }
}
