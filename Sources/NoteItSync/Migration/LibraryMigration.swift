import Foundation

/// Moves the Inkwell library (`<base>/Inkwell`) to `<base>/NoteIt` the first time NoteIt runs.
public enum LibraryMigration {
    public enum Outcome: Equatable {
        /// Nothing to migrate (fresh install, or already migrated).
        case notNeeded
        case moved
        /// The move failed; the returned directory is the legacy folder, used in place.
        case failed(String)
    }

    /// Returns the library directory to use under `baseDirectory` (normally Application Support).
    /// Never seeds or creates anything: if the move fails, the legacy folder is returned so the
    /// existing library is opened rather than a fresh one being seeded next to it.
    public static func resolve(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        move: ((URL, URL) throws -> Void)? = nil,
        log: (String) -> Void = { NSLog("%@", $0) }
    ) -> (directory: URL, outcome: Outcome) {
        let current = baseDirectory.appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true)
        let legacy = baseDirectory.appendingPathComponent(AppIdentity.Legacy.dataFolderName, isDirectory: true)
        guard !exists(current, fileManager), exists(legacy, fileManager) else { return (current, .notNeeded) }
        do {
            // A single rename on the same volume: hidden files (.initialized, .trash/) and sync state move with it.
            if let move { try move(legacy, current) } else { try fileManager.moveItem(at: legacy, to: current) }
            log("NoteIt: moved library from \(legacy.path) to \(current.path)")
            return (current, .moved)
        } catch {
            log("NoteIt: couldn't move library from \(legacy.path) to \(current.path) (\(error)); using it in place")
            return (legacy, .failed(String(describing: error)))
        }
    }

    private static func exists(_ url: URL, _ fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
}
