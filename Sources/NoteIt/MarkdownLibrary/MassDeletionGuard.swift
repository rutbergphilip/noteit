import AppKit

/// Many files disappearing in one scan usually means a disk was unmounted or a cloud provider evicted them, not
/// that the user deleted them; NoteIt then waits for the user (program §11, markdown-storage spec §3.5).
enum MassDeletionGuard {
    static let maxUnconfirmed = 20
    static let minHeldFiles = 5
    static let heldShare = 0.1

    static func mustHold(removed: Int, totalFiles: Int) -> Bool {
        guard removed > 0 else { return false }
        if removed > maxUnconfirmed { return true }
        return removed >= minHeldFiles && Double(removed) >= heldShare * Double(max(totalFiles, removed))
    }

    static let title = "Many notes disappeared from the folder"
    static let confirmButton = "Move to Recently Deleted"
    static let laterButton = "Not Now"

    static func message(count: Int) -> String {
        let notes = count == 1 ? "1 note’s file is" : "\(count) notes’ files are"
        return "\(notes) no longer in your Markdown folder. If the folder is on a disk or in a cloud service that isn’t "
            + "available right now, choose Not Now; the notes come back when their files do."
    }

    /// The held note IDs, kept in the data folder so the question is asked again at the next launch.
    struct HeldFile: Codable {
        var ids: [UUID]
    }

    static let fileName = "markdown-held-deletions.json"

    static func load(dataDir: URL) -> Set<UUID> {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent(fileName)),
              let held = try? JSONDecoder().decode(HeldFile.self, from: data) else { return [] }
        return Set(held.ids)
    }

    static func save(_ ids: Set<UUID>, dataDir: URL) {
        let url = dataDir.appendingPathComponent(fileName)
        if ids.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            let data = try JSONEncoder().encode(HeldFile(ids: ids.sorted { $0.uuidString < $1.uuidString }))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("NoteIt: couldn't save the held deletions: \(error)")
        }
    }

    /// The held count the user last answered **Not Now** for; the question comes back only when more go missing.
    @MainActor private static var deferredCount = 0

    /// Asks about `store`'s held batch, unless the user already put off a batch this size.
    @MainActor
    static func askIfNeeded(_ store: NoteStore) {
        let count = store.heldMarkdownDeletions.count
        guard count > deferredCount else {
            if count == 0 { deferredCount = 0 }
            return
        }
        if ask(count: count) {
            deferredCount = 0
            store.confirmHeldDeletions()
        } else {
            deferredCount = count
        }
    }

    /// The question for a held batch; true for **Move to Recently Deleted**.
    @MainActor
    private static func ask(count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message(count: count)
        alert.addButton(withTitle: laterButton)
        alert.addButton(withTitle: confirmButton)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
