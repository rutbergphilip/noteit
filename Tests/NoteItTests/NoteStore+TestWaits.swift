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

    static func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date() + timeout
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
    }
}
