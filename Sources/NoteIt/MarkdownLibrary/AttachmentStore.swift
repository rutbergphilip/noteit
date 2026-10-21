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

    init(contentRoot: URL, index: MarkdownPathIndex) {
        self.contentRoot = contentRoot
        self.index = index
    }

    var folderURL: URL { contentRoot.appendingPathComponent(AttachmentPaths.folder, isDirectory: true) }

    enum StoreError: Error, Equatable { case tooLarge(String) }

    /// Stores `attachment` (its SHA-256 is `sha`) unless a file with the same bytes is there, and returns the file
    /// name in `_attachments/`.
    func store(_ attachment: Attachment, sha: String) throws -> String {
        guard AttachmentLimit.allows(byteCount: attachment.data.count) else { throw StoreError.tooLarge(attachment.name) }
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

    /// Moves files unreferenced for 24 hours to the Trash and returns their names. Run after writes and scans.
    @discardableResult
    func sweep() -> [String] {
        let counts = referenceCounts()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []).filter { !$0.hasPrefix(".") }
        let date = now()
        var trashed: [String] = []
        lock.withLock {
            for name in names {
                let key = name.lowercased()
                if counts[key, default: 0] > 0 {
                    seenReferenced.insert(key)
                    unreferencedSince[key] = nil
                    continue
                }
                guard seenReferenced.contains(key) else { continue }
                let since = unreferencedSince[key] ?? date
                unreferencedSince[key] = since
                guard date.timeIntervalSince(since) >= Self.graceInterval else { continue }
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

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
