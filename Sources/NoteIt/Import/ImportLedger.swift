import CryptoKit
import Foundation

/// Which note of a source an import saw, as the ledger knows it: the source's own identity (a file path or a
/// source note id, depending on the importer) and a hash of its content.
struct ImportIdentity: Hashable {
    var source: String
    var hash: String

    init(source: String, hash: String) {
        self.source = source
        self.hash = hash
    }

    init(source: String, content: Data) {
        self.init(source: source, hash: ImportLedger.hash(of: content))
    }

    init(source: String, content: String) {
        self.init(source: source, content: Data(content.utf8))
    }
}

enum ImportStatus: Equatable {
    /// Never imported, or every note imported from it has since been deleted for good.
    case new
    /// The same source with the same content is already a note.
    case alreadyImported(UUID)
    /// The source was imported before but its content is different now.
    case changed
}

/// Remembers which notes an import made, so importing the same source again can tell what's already there.
/// Kept on this Mac in `import-ledger.json`; it isn't synced, so a second Mac that imports the same source
/// makes its own notes.
///
/// A note counts as already imported while it exists, including in Recently Deleted. A changed source is
/// imported again as a new note and remembered next to the old one.
final class ImportLedger {
    static let fileName = "import-ledger.json"

    private struct File: Codable {
        var version = 1
        /// Source identity → content hash → the note it became.
        var entries: [String: [String: UUID]] = [:]
    }

    private let url: URL?
    private var entries: [String: [String: UUID]] = [:]
    private var dirty = false

    /// `url` nil keeps the ledger in memory only.
    init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        do {
            entries = try JSONDecoder().decode(File.self, from: data).entries
        } catch {
            NSLog("NoteIt: \(Self.fileName) is unreadable (\(error)); imports won't recognize earlier ones")
        }
    }

    func status(of identity: ImportIdentity, noteExists: (UUID) -> Bool) -> ImportStatus {
        guard let known = entries[identity.source] else { return .new }
        if let id = known[identity.hash], noteExists(id) { return .alreadyImported(id) }
        return known.values.contains(where: noteExists) ? .changed : .new
    }

    func record(_ identity: ImportIdentity, noteID: UUID) {
        entries[identity.source, default: [:]][identity.hash] = noteID
        dirty = true
    }

    func save() {
        guard dirty, let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(File(entries: entries)).write(to: url, options: .atomic)
            dirty = false
        } catch {
            NSLog("NoteIt: couldn’t save \(Self.fileName): \(error)")
        }
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension NoteStore {
    /// True when `identity` is already a note, counting it in `report`; a source that changed since it was
    /// imported counts too but is still imported, as a new note.
    func shouldSkipImport(_ identity: ImportIdentity, report: inout ImportReport) -> Bool {
        switch importLedger.status(of: identity, noteExists: { note(with: $0) != nil }) {
        case .alreadyImported:
            report.notesAlreadyImported += 1
            return true
        case .changed:
            report.notesChanged += 1
            return false
        case .new:
            return false
        }
    }
}
