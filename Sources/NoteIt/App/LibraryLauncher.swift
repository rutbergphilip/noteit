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
        /// `library-location.json` is there but can't be used (newer version or format, read error): nothing may be
        /// opened or written. The reason is shown to the user.
        case libraryLocationUnreadable(String)
    }

    var dataDirectoryOverride: () -> String?
    var baseDirectory: () -> URL
    var isLegacyAppRunning: () -> Bool
    var quitLegacyApp: () -> Bool
    var fileManager: FileManager = .default
    var log: (String) -> Void = { NSLog("%@", $0) }
    var showContentRootMissing: (URL) -> Void = { LibraryLauncher.presentContentRootMissing($0) }
    var showLibraryLocationUnreadable: (String) -> Void = { LibraryLauncher.presentLibraryLocationUnreadable($0) }
    /// Inspects the Markdown content folder, which may be on a NAS that went away: nil when it didn't answer in time.
    var checkContentRoot: (LibraryLocationFile) -> ContentRootCheck? = { file in
        BoundedFileAccess.shared.runBlocking(key: "content-root:\(file.path)", timeout: LibraryLauncher.contentRootTimeout) {
            LibraryLauncher.inspectContentRoot(file)
        }
    }

    nonisolated static let contentRootTimeout: TimeInterval = 10

    struct ContentRootCheck: Equatable {
        /// The bookmark's target when the folder moved, otherwise the recorded path.
        var root: URL
        var moved: Bool
        /// A recreated bookmark when the saved one was stale.
        var freshBookmark: Data?
        var isFolder: Bool
    }

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

    /// A Markdown library is never seeded, and neither is a data folder whose location file is damaged.
    private func applyingLocationFile(to location: LibraryLocation) -> Decision {
        LibraryConverter.finishInterrupted(dataDir: location.url)
        var file: LibraryLocationFile
        switch LibraryLocationFile.load(dataDir: location.url, fileManager: fileManager, log: log) {
        case .missing:
            return .open(location)
        case .corrupt:
            return .open(LibraryLocation(url: location.url, seedsFreshLibrary: false))
        case .unreadable(let reason):
            return .libraryLocationUnreadable(reason)
        case .loaded(let loaded):
            file = loaded
        }
        guard file.format == .markdown else { return .open(location) }
        guard let check = checkContentRoot(file) else {
            log("NoteIt: the library folder \(file.path) didn't respond")
            return .contentRootMissing(file.contentRootURL)
        }
        record(check, in: &file, dataDir: location.url)
        guard check.isFolder else { return .contentRootMissing(check.root) }
        return .open(LibraryLocation(url: location.url, seedsFreshLibrary: false, format: .markdown, contentRootURL: check.root))
    }

    /// Records a moved folder's new path and a recreated bookmark.
    private func record(_ check: ContentRootCheck, in file: inout LibraryLocationFile, dataDir: URL) {
        guard check.moved || check.freshBookmark != nil else { return }
        if check.moved {
            log("NoteIt: library folder moved to \(check.root.path)")
            file.path = LibraryLocationFile.displayPath(check.root)
        }
        if let fresh = check.freshBookmark { file.bookmark = fresh }
        do {
            try file.write(dataDir: dataDir)
        } catch {
            log("NoteIt: couldn't update \(LibraryLocationFile.fileName): \(error)")
        }
    }

    /// Follows the bookmark when the folder was renamed or moved, and checks the folder is there. Every step can
    /// block on a network volume that went away, so this runs off the main thread (`checkContentRoot`).
    nonisolated static func inspectContentRoot(_ file: LibraryLocationFile) -> ContentRootCheck {
        func isFolder(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let recorded = file.contentRootURL
        let unchanged = { ContentRootCheck(root: recorded, moved: false, freshBookmark: nil, isFolder: isFolder(recorded)) }
        guard let bookmark = file.bookmark else { return unchanged() }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &isStale),
              !resolved.pathComponents.contains(".Trash") else { return unchanged() }
        let folder = URL(fileURLWithPath: resolved.path, isDirectory: true)
        let moved = folder.resolvingSymlinksInPath().standardizedFileURL.path
            != recorded.resolvingSymlinksInPath().standardizedFileURL.path
        let fresh = isStale ? try? folder.bookmarkData() : nil
        let root = moved ? folder : recorded
        return ContentRootCheck(root: root, moved: moved, freshBookmark: fresh, isFolder: isFolder(root))
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
        case .libraryLocationUnreadable(let reason):
            log("NoteIt: quitting; \(reason)")
            showLibraryLocationUnreadable(reason)
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
        alert.informativeText = "Your notes are kept in \(LibraryLocationFile.displayPath(url)), which NoteIt can't reach. If it's on a disk or NAS that isn't connected, connect it and open NoteIt again."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    static func presentLibraryLocationUnreadable(_ reason: String) {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "NoteIt can't read its library settings"
        alert.informativeText = reason + " NoteIt will quit without opening or changing your library."
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
