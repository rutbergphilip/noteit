import Foundation

/// Converts a library between formats (markdown-storage Task 5.1). Until then only the launch hook exists.
@MainActor
final class LibraryConverter {
    /// Finishes or rolls back a conversion that a crash interrupted; runs before the library is loaded.
    static func finishInterrupted(dataDir: URL) {}
}
