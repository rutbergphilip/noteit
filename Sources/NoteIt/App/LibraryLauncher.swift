import AppKit
import Foundation
import NoteItSync

/// Where the library lives and whether a welcome library may be seeded there. `url` is the data folder
/// (`NoteStore.rootURL`); a Markdown library's notes are in `contentRootURL`.
struct LibraryLocation: Equatable {
    var url: URL
    var seedsFreshLibrary: Bool
    var format: LibraryFormatKind = .rtfd
    var contentRootURL: URL? = nil
}

/// Decides, at launch, which library NoteStore opens: the `NOTEIT_DATA_DIR` override, or
/// `Application Support/NoteIt` after migrating Inkwell's (see `LibraryMigration`), then the format and content
/// folder from `library-location.json`. Every side effect is injectable so the whole path, store load included,
/// can be tested.
@MainActor
struct LibraryLauncher {
    enum Decision: Equatable {
        case open(LibraryLocation)
        /// Inkwell is running and the user chose to quit NoteIt: nothing may be opened or written.
        case quitNoteIt
        /// The Markdown library's content folder isn't there: nothing may be opened or written.
        case contentRootMissing(URL)
    }

    var dataDirectoryOverride: () -> String?
    var baseDirectory: () -> URL
    var isLegacyAppRunning: () -> Bool
    var quitLegacyApp: () -> Bool
    var fileManager: FileManager = .default
    var log: (String) -> Void = { NSLog("%@", $0) }
    var showContentRootMissing: (URL) -> Void = { LibraryLauncher.presentContentRootMissing($0) }

    var legacyDirectory: URL {
        baseDirectory().appendingPathComponent(AppIdentity.Legacy.dataFolderName, isDirectory: true)
    }

    func decide() -> Decision {
        if let override = dataDirectoryOverride() {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            return applyingLocationFile(to: LibraryLocation(url: url, seedsFreshLibrary: true))
        }
        let result = LibraryMigration.resolve(
            baseDirectory: baseDirectory(),
            fileManager: fileManager,
            isLegacyAppRunning: isLegacyAppRunning,
            quitLegacyApp: quitLegacyApp,
            log: log
        )
        if result.outcome == .legacyAppRunning { return .quitNoteIt }
        return applyingLocationFile(to: LibraryLocation(url: result.directory, seedsFreshLibrary: result.outcome.allowsSeeding))
    }

    /// A Markdown library is never seeded.
    private func applyingLocationFile(to location: LibraryLocation) -> Decision {
        LibraryConverter.finishInterrupted(dataDir: location.url)
        guard var file = LibraryLocationFile.load(dataDir: location.url, fileManager: fileManager, log: log),
              file.format == .markdown else { return .open(location) }
        let root = contentRoot(of: &file, dataDir: location.url)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .contentRootMissing(root)
        }
        return .open(LibraryLocation(url: location.url, seedsFreshLibrary: false, format: .markdown, contentRootURL: root))
    }

    /// Follows the bookmark when the folder was renamed or moved, and records the new path.
    private func contentRoot(of file: inout LibraryLocationFile, dataDir: URL) -> URL {
        let recorded = file.contentRootURL
        guard let bookmark = file.bookmark else { return recorded }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &isStale),
              !resolved.pathComponents.contains(".Trash") else { return recorded }
        let folder = URL(fileURLWithPath: resolved.path, isDirectory: true)
        let moved = folder.resolvingSymlinksInPath().standardizedFileURL.path
            != recorded.resolvingSymlinksInPath().standardizedFileURL.path
        guard moved || isStale else { return recorded }
        if moved {
            log("NoteIt: library folder moved to \(folder.path)")
            file.path = LibraryLocationFile.displayPath(folder)
        }
        if isStale, let fresh = try? folder.bookmarkData() { file.bookmark = fresh }
        do {
            try file.write(dataDir: dataDir)
        } catch {
            log("NoteIt: couldn't update \(LibraryLocationFile.fileName): \(error)")
        }
        return moved ? folder : recorded
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
        case .contentRootMissing(let url):
            log("NoteIt: quitting; the library folder \(url.path) is missing")
            showContentRootMissing(url)
            quit()
            return nil
        }
    }

    /// Locate… comes with the folder watcher (markdown-storage Task 4.2).
    static func presentContentRootMissing(_ url: URL) {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "NoteIt can't find your library folder"
        alert.informativeText = "Your notes are kept in \(LibraryLocationFile.displayPath(url)), which isn't there. If it's on a disk that isn't connected, connect it and open NoteIt again."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
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
