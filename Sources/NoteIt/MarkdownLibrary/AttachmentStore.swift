import CryptoKit
import Foundation
import NoteItDoc
import NoteItMarkdown

/// `_attachments/` of a Markdown library (spec §3.4): one file per distinct content, shared by every note. A file
/// no note refers to goes to the macOS Trash 24 hours after its last reference went, and only if NoteIt saw it
/// referenced; NoteIt never deletes it outright.
final class AttachmentStore: @unchecked Sendable {
    static let graceInterval: TimeInterval = 24 * 60 * 60

    let contentRoot: URL
    private let index: MarkdownPathIndex
    var now: () -> Date = Date.init
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    private let lock = NSLock()
    private var seenReferenced: Set<String> = []
    private var unreferencedSince: [String: Date] = [:]
    private let sweepQueue = DispatchQueue(label: "NoteIt.AttachmentSweep", qos: .utility)
    private let sweepLock = NSLock()
    private var sweepQueued = false

    init(contentRoot: URL, index: MarkdownPathIndex) {
        self.contentRoot = contentRoot
        self.index = index
    }

    var folderURL: URL { contentRoot.appendingPathComponent(AttachmentPaths.folder, isDirectory: true) }

    enum StoreError: Error, Equatable { case tooLarge(String) }

    /// Stores `attachment` (its SHA-256 is `sha`) unless a file with the same bytes is there, and returns the file
    /// name in `_attachments/`.
    /// Runs under the sweep's lock and restarts the file's 24 hours, so a sweep can't trash a file a note is being
    /// written to refer to.
    func store(_ attachment: Attachment, sha: String) throws -> String {
        guard AttachmentLimit.allows(byteCount: attachment.data.count) else { throw StoreError.tooLarge(attachment.name) }
        return try lock.withLock {
            let name = try storeUnlocked(attachment, sha: sha)
            unreferencedSince[name.lowercased()] = nil
            return name
        }
    }

    private func storeUnlocked(_ attachment: Attachment, sha: String) throws -> String {
        if let existing = existingFile(sha: sha) { return existing }
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var name = AttachmentPaths.fileName(sha256: sha, originalName: attachment.name)
        if fm.fileExists(atPath: folderURL.appendingPathComponent(name).path) {
            name = ExportNaming.uniqueOnDisk((name as NSString).deletingPathExtension,
                                             extension: (name as NSString).pathExtension, in: folderURL)
        }
        let target = folderURL.appendingPathComponent(name)
        let temp = folderURL.appendingPathComponent(".\(name).noteit-tmp")
        do {
            try attachment.data.write(to: temp)
            try fm.moveItem(at: temp, to: target)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return name
    }

    /// A file in `_attachments/` with the SHA-256 `sha`: same 12-hex prefix, then compared by hash.
    func existingFile(sha: String) -> String? {
        let prefix = String(sha.lowercased().prefix(12)) + "-"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? [])
            .filter { $0.lowercased().hasPrefix(prefix) && !$0.hasPrefix(".") }
            .sorted()
        for name in names {
            guard let data = try? Data(contentsOf: folderURL.appendingPathComponent(name)) else { continue }
            if Self.sha256(data) == sha.lowercased() { return name }
        }
        return nil
    }

    /// The bytes of `_attachments/<name>`, read only when the file stays inside the folder.
    func data(named name: String) -> Data? {
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return try? Data(contentsOf: folderURL.appendingPathComponent(name))
    }

    /// File name → number of notes that refer to it, from `markdown-files.json`.
    func referenceCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in index.allEntries.values {
            for name in Set(entry.attachments.map { $0.lowercased() }) { counts[name, default: 0] += 1 }
        }
        return counts
    }

    /// Runs `sweep()` on a serial background queue. A sweep already waiting to start covers this call too, and one
    /// stuck on a folder that stopped answering holds back only later sweeps.
    func scheduleSweep() {
        let enqueue = sweepLock.withLock { () -> Bool in
            defer { sweepQueued = true }
            return !sweepQueued
        }
        guard enqueue else { return }
        sweepQueue.async { [self] in
            sweepLock.withLock { sweepQueued = false }
            sweep()
        }
    }

    /// Moves files unreferenced for 24 hours to the Trash and returns their names. Run after writes and scans
    /// through `scheduleSweep()`.
    @discardableResult
    func sweep() -> [String] {
        let counts = referenceCounts()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []).filter { !$0.hasPrefix(".") }
        let date = now()
        var trashed: [String] = []
        for name in names {
            lock.withLock {
                let key = name.lowercased()
                if counts[key, default: 0] > 0 {
                    seenReferenced.insert(key)
                    unreferencedSince[key] = nil
                    return
                }
                guard seenReferenced.contains(key) else { return }
                let since = unreferencedSince[key] ?? date
                unreferencedSince[key] = since
                guard date.timeIntervalSince(since) >= Self.graceInterval else { return }
                do {
                    try trash(folderURL.appendingPathComponent(name))
                    trashed.append(name)
                    seenReferenced.remove(key)
                    unreferencedSince[key] = nil
                } catch {
                    NSLog("NoteIt: couldn't move the unused attachment \(name) to the Trash: \(error)")
                }
            }
        }
        return trashed
    }

    /// Calls `done` on the sweep queue once every sweep scheduled so far has run.
    func afterScheduledSweeps(_ done: @escaping @Sendable () -> Void) {
        sweepQueue.async(execute: done)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
