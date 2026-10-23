import Foundation

/// The files NoteIt itself just wrote, as (content-relative path, SHA-256). The watcher drops an event whose file
/// still has a recorded hash, so NoteIt's own writes aren't taken for external edits (spec §3.5).
final class WriteLedger: @unchecked Sendable {
    static let lifetime: TimeInterval = 10

    var now: () -> Date = Date.init
    private let lock = NSLock()
    private var records: [String: [(sha: String, at: Date)]] = [:]

    func record(path: String, sha256: String) {
        lock.withLock {
            prune()
            records[path.lowercased(), default: []].append((sha256.lowercased(), now()))
        }
    }

    func isOwnWrite(path: String, sha256: String) -> Bool {
        lock.withLock {
            prune()
            return records[path.lowercased()]?.contains { $0.sha == sha256.lowercased() } ?? false
        }
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        for (path, list) in records {
            let kept = list.filter { $0.at > cutoff }
            records[path] = kept.isEmpty ? nil : kept
        }
    }
}
