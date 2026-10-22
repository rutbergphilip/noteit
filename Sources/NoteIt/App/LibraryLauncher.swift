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
    var renameFilesOnTitleChange: Bool = true
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
        /// The Markdown library's content folder isn't there: nothing may be opened or written until the user
        /// locates it.
        case contentRootMissing(URL, dataDir: URL)
        /// `library-location.json` is there but can't be used (newer version or format, read error): nothing may be
        /// opened or written. The reason is shown to the user.
        case libraryLocationUnreadable(String)
    }

    var dataDirectoryOverride: () -> String?
    /// Debug builds: a content folder that opens the `NOTEIT_DATA_DIR` library as Markdown without a location file.
    var markdownRootOverride: () -> String? = { nil }
    var baseDirectory: () -> URL
    var isLegacyAppRunning: () -> Bool
    var quitLegacyApp: () -> Bool
    var fileManager: FileManager = .default
    var log: (String) -> Void = { NSLog("%@", $0) }
    /// Shows the missing folder with the reason the last choice was refused, if any; returns the folder the user
    /// located, or nil for Quit.
    var showContentRootMissing: (URL, String?) -> URL? = { LibraryLauncher.presentContentRootMissing($0, refused: $1) }
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
            if let markdown = markdownRootOverride(), let location = markdownOverride(markdown, dataDir: url) {
                return .open(location)
            }
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

    /// The data folder opened as a Markdown library in `root`; nil (with a log line) when the data folder already
    /// holds RTFD notes or has a location file of its own, or the folder can't be created.
    private func markdownOverride(_ root: String, dataDir: URL) -> LibraryLocation? {
        let content = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let notes = dataDir.appendingPathComponent("notes", isDirectory: true)
        let rtfd = ((try? fileManager.contentsOfDirectory(atPath: notes.path)) ?? []).contains { $0.hasSuffix(".rtfd") }
        if rtfd || fileManager.fileExists(atPath: LibraryLocationFile.url(dataDir: dataDir).path) {
            log("NoteIt: ignoring NOTEIT_MARKDOWN_ROOT; \(dataDir.path) already holds a library")
            return nil
        }
        do {
            try fileManager.createDirectory(at: content, withIntermediateDirectories: true)
        } catch {
            log("NoteIt: ignoring NOTEIT_MARKDOWN_ROOT; can't create \(content.path): \(error)")
            return nil
        }
        return LibraryLocation(url: dataDir, seedsFreshLibrary: false, format: .markdown, contentRootURL: content)
    }

    /// A Markdown library is never seeded, and neither is a data folder whose location file is damaged.
    private func applyingLocationFile(to location: LibraryLocation) -> Decision {
        LibraryConverter.finishInterrupted(dataDir: location.url)
        // A conversion that couldn't be finished or undone: nothing is set aside or seeded until it is.
        let conversionPending = fileManager.fileExists(atPath: LibraryConversionJournal.url(dataDir: location.url).path)
        var file: LibraryLocationFile
        switch LibraryLocationFile.load(dataDir: location.url, fileManager: fileManager, setsAsideDamaged: !conversionPending, log: log) {
        case .missing:
            if conversionPending { return .open(LibraryLocation(url: location.url, seedsFreshLibrary: false)) }
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
            return .contentRootMissing(file.contentRootURL, dataDir: location.url)
        }
        record(check, in: &file, dataDir: location.url)
        guard check.isFolder else { return .contentRootMissing(check.root, dataDir: location.url) }
        return .open(LibraryLocation(url: location.url, seedsFreshLibrary: false, format: .markdown, contentRootURL: check.root,
                                     renameFilesOnTitleChange: file.renameFilesOnTitleChange))
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
        case .contentRootMissing(let url, let dataDir):
            var refused: String?
            while let chosen = showContentRootMissing(url, refused) {
                refused = Self.relocate(to: chosen, dataDir: dataDir, fileManager: fileManager)
                if refused == nil {
                    log("NoteIt: library folder located at \(chosen.path)")
                    return launch(open: open, quit: quit)
                }
            }
            log("NoteIt: quitting; the library folder \(url.path) is missing")
            quit()
            return nil
        case .libraryLocationUnreadable(let reason):
            log("NoteIt: quitting; \(reason)")
            showLibraryLocationUnreadable(reason)
            quit()
            return nil
        }
    }

    /// Points `library-location.json` at `folder` after checking that it holds this library's notes; returns why
    /// it was refused, or nil. Nothing else is written, so a wrong choice changes nothing.
    nonisolated static func relocate(to folder: URL, dataDir: URL, fileManager: FileManager = .default) -> String? {
        let folder = folder.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Choose a folder."
        }
        if LibraryConverter.overlapsLibrary(folder, dataDir: dataDir) {
            return "This folder holds NoteIt’s own library files. Choose a folder outside them."
        }
        guard case .loaded(var file) = LibraryLocationFile.load(dataDir: dataDir, fileManager: fileManager, setsAsideDamaged: false),
              file.format == .markdown else {
            return "NoteIt can’t read its library settings."
        }
        let known = MarkdownPathIndex(dataDir: dataDir).allEntries.values.map(\.path)
            .filter { !$0.hasPrefix(MarkdownBodyStorage.trashFolder + "/") }
        if !known.isEmpty, !known.contains(where: { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
            return "\(LibraryLocationFile.displayPath(folder)) doesn’t have the notes of your library. Choose the folder that holds them."
        }
        file.path = LibraryLocationFile.displayPath(folder)
        file.bookmark = try? folder.bookmarkData()
        do {
            try file.write(dataDir: dataDir)
        } catch {
            return "NoteIt couldn’t save the new location: \(error.localizedDescription)"
        }
        return nil
    }

    static let contentRootMissingTitle = "Your Markdown folder can’t be found"

    /// "Your Markdown folder can't be found" with **Locate…** and **Quit** (spec §3.5).
    static func presentContentRootMissing(_ url: URL, refused: String?) -> URL? {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = contentRootMissingTitle
        alert.informativeText = refused ?? "Your notes are kept in \(LibraryLocationFile.displayPath(url)), which NoteIt can’t reach. If it’s on a disk or NAS that isn’t connected, connect it and choose Locate…, or find the folder if you moved it."
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your notes."
        let parent = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { panel.directoryURL = parent }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The folder went away while NoteIt was open. Locate… saves the new place and relaunches; Quit quits.
    static func contentRootLost(_ url: URL, dataDir: URL) {
        var refused: String?
        while let chosen = presentContentRootMissing(url, refused: refused) {
            refused = relocate(to: chosen, dataDir: dataDir)
            if refused == nil {
                relaunch()
                return
            }
        }
        NSApp.terminate(nil)
    }

    /// Quits and opens the app again once this process has exited. Outside an app bundle it only quits.
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                              bundle.path]
            try? task.run()
        }
        NSApp.terminate(nil)
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
        markdownRootOverride: {
            #if DEBUG
            return AppEnvironment.nonEmpty("MARKDOWN_ROOT")
            #else
            return nil
            #endif
        },
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
