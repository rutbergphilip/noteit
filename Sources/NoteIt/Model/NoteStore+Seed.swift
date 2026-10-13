import CryptoKit
import Foundation
import NoteItSync

/// IDs and revisions of the first-launch sample content, so a Mac joining an existing sync library can drop
/// samples the user never touched instead of merging a second copy into the library.
struct SeedManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var id: UUID
        var revision: UUID?
        /// SHA-256 of the note's plain text at seed time (nil for notebooks).
        var fingerprint: String?
    }

    var notes: [Entry]
    var notebooks: [Entry]
}

extension NoteStore {
    var seedManifestURL: URL { rootURL.appendingPathComponent("seed-manifest.json") }

    func recordSeedManifest() {
        let manifest = SeedManifest(
            notes: notes.map { .init(id: $0.id, revision: $0.revision, fingerprint: Self.seedFingerprint(body(for: $0.id))) },
            notebooks: notebooks.map { .init(id: $0.id, revision: $0.revision, fingerprint: nil) }
        )
        do {
            try Self.encoder.encode(manifest).write(to: seedManifestURL, options: .atomic)
        } catch {
            NSLog("NoteIt: failed to save seed manifest: \(error)")
        }
    }

    func loadSeedManifest() -> SeedManifest? {
        guard let data = try? Data(contentsOf: seedManifestURL) else { return nil }
        return try? Self.decoder.decode(SeedManifest.self, from: data)
    }

    func discardSeedManifest() {
        try? FileManager.default.removeItem(at: seedManifestURL)
    }

    /// Called when joining a sync library that already existed, before the first pass. Removes sample notes
    /// still exactly as seeded, then sample notebooks that are unchanged and now empty. Nothing is journaled,
    /// so the removals never propagate. Libraries without a seed manifest are left alone.
    @discardableResult
    func removePristineSeedContent() -> (notes: Int, notebooks: Int) {
        guard let manifest = loadSeedManifest() else { return (0, 0) }
        var removedNotes = 0, removedNotebooks = 0
        for entry in manifest.notes {
            guard note(with: entry.id) != nil else { continue }
            // Open editors commit pending typing first, so an in-flight edit counts.
            commitStagedEditorBody(entry.id)
            NotificationCenter.default.post(name: .noteItSyncWillApplyRemote, object: entry.id)
            guard let meta = note(with: entry.id), isPristine(meta, entry) else { continue }
            applyRemoteDeletion(meta.id, kind: .note)
            removedNotes += 1
        }
        for entry in manifest.notebooks {
            guard let nb = notebook(with: entry.id), entry.revision != nil, nb.revision == entry.revision,
                  !notes.contains(where: { $0.notebookID == nb.id }) else { continue }
            applyRemoteDeletion(nb.id, kind: .notebook)
            removedNotebooks += 1
        }
        discardSeedManifest()
        return (removedNotes, removedNotebooks)
    }

    private func isPristine(_ meta: NoteMeta, _ entry: SeedManifest.Entry) -> Bool {
        guard loadError(for: meta.id) == nil else { return false }
        if let recorded = entry.revision, let current = meta.revision {
            return recorded == current
        }
        guard let fingerprint = entry.fingerprint else { return false }
        return Self.seedFingerprint(body(for: meta.id)) == fingerprint
    }

    static func seedFingerprint(_ text: NSAttributedString) -> String {
        SHA256.hash(data: Data(text.string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
