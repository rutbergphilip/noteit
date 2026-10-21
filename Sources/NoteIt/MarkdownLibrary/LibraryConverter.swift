import Foundation

/// Converts a library between formats (markdown-storage Task 5.1).
@MainActor
final class LibraryConverter {
    /// Finishes or rolls back a conversion that a crash interrupted; runs before the library is loaded.
    static func finishInterrupted(dataDir: URL) {}

    /// The folders a content folder may not be equal to, inside, or contain (spec §3.6).
    nonisolated static func managedFolders(dataDir: URL) -> [URL] {
        [dataDir] + ["notes", "backups", "sync-meta-raw", "body-extras", "history"].map {
            dataDir.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Compared by path components after resolving symlinks and standardising, ignoring case as APFS does.
    nonisolated static func overlapsLibrary(_ folder: URL, dataDir: URL) -> Bool {
        func components(_ url: URL) -> [String] {
            url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
        }
        let candidate = components(folder)
        return managedFolders(dataDir: dataDir).contains { managed in
            let parts = components(managed)
            return candidate.starts(with: parts) || parts.starts(with: candidate)
        }
    }
}
