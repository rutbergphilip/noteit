import Foundation
import NoteItSync

/// Where the library lives and whether a welcome library may be seeded there.
struct LibraryLocation: Equatable {
    var url: URL
    var seedsFreshLibrary: Bool
}

/// Decides, at launch, which library NoteStore opens: the `NOTEIT_DATA_DIR` override, or
/// `Application Support/NoteIt` after migrating Inkwell's (see `LibraryMigration`). Every side effect
/// is injectable so the whole path, store load included, can be tested.
@MainActor
struct LibraryLauncher {
    enum Decision: Equatable {
        case open(LibraryLocation)
        /// Inkwell is running and the user chose to quit NoteIt: nothing may be opened or written.
        case quitNoteIt
    }

    var dataDirectoryOverride: () -> String?
    var baseDirectory: () -> URL
    var isLegacyAppRunning: () -> Bool
    var quitLegacyApp: () -> Bool
    var fileManager: FileManager = .default
    var log: (String) -> Void = { NSLog("%@", $0) }

    var legacyDirectory: URL {
        baseDirectory().appendingPathComponent(AppIdentity.Legacy.dataFolderName, isDirectory: true)
    }

    func decide() -> Decision {
        if let override = dataDirectoryOverride() {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            return .open(LibraryLocation(url: url, seedsFreshLibrary: true))
        }
        let result = LibraryMigration.resolve(
            baseDirectory: baseDirectory(),
            fileManager: fileManager,
            isLegacyAppRunning: isLegacyAppRunning,
            quitLegacyApp: quitLegacyApp,
            log: log
        )
        if result.outcome == .legacyAppRunning { return .quitNoteIt }
        return .open(LibraryLocation(url: result.directory, seedsFreshLibrary: result.outcome.allowsSeeding))
    }

    /// Runs `decide()` and hands the result to `open` (normally: build the NoteStore) or `quit`.
    @discardableResult
    func launch<Store>(open: (LibraryLocation) -> Store, quit: () -> Void) -> Store? {
        switch decide() {
        case .open(let location):
            return open(location)
        case .quitNoteIt:
            log("NoteIt: quitting; Inkwell must quit before its notes can move")
            quit()
            return nil
        }
    }

    static let live = LibraryLauncher(
        dataDirectoryOverride: { AppEnvironment.nonEmpty("DATA_DIR") },
        baseDirectory: {
            #if DEBUG
            // Debug-only: stand-in for Application Support, to exercise the migration against fake folders.
            if let fakeBase = AppEnvironment.nonEmpty("APP_SUPPORT_DIR") {
                return URL(fileURLWithPath: (fakeBase as NSString).expandingTildeInPath, isDirectory: true)
            }
            #endif
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        },
        isLegacyAppRunning: { LegacyAppQuitter.isRunning() },
        quitLegacyApp: { LegacyAppQuitter.quit(reason: .moveNotes) }
    )
}
