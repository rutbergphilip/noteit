import Foundation
@testable import NoteIt

@MainActor
extension NoteStore {
    /// Runs the main run loop until the rescan was applied (or failed); for synchronous tests.
    @discardableResult
    func rescanNow(timeout: TimeInterval = 20) -> Bool {
        var result: Bool?
        rescanMarkdownFolder { result = $0 }
        Self.spin(until: { result != nil }, timeout: timeout)
        return result ?? false
    }

    func confirmHeldDeletionsNow(timeout: TimeInterval = 20) {
        var done = false
        confirmHeldDeletions { _ in done = true }
        Self.spin(until: { done }, timeout: timeout)
    }

    /// A store whose launch scan was applied (or failed), for tests that use the library right after opening it.
    static func opened(location: LibraryLocation, bodyStorage: NoteBodyStorage? = nil, timeout: TimeInterval = 20) -> NoteStore {
        let store = NoteStore(location: location, bodyStorage: bodyStorage)
        store.waitForLaunchScan(timeout: timeout)
        return store
    }

    /// Waits on the scan and IO jobs themselves, so it works from async tests too.
    func waitForLaunchScan(timeout: TimeInterval = 20) {
        let deadline = Date() + timeout
        while markdownFolderChecking, Date() < deadline {
            guard let job = markdownScanJob ?? markdownIOJobs.first else { break }
            _ = job.wait(upTo: deadline.timeIntervalSinceNow)
        }
    }

    static func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date() + timeout
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
    }
}
