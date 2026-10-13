import Foundation

/// Moves the Inkwell library (`<base>/Inkwell`) to `<base>/NoteIt` the first time NoteIt runs.
public enum LibraryMigration {
    public enum Outcome: Equatable {
        /// Neither folder holds a library: the only case in which a welcome library may be seeded.
        case freshInstall
        /// NoteIt already has a library. An Inkwell library next to it, if any, is left untouched.
        case existing
        /// Inkwell's library was moved in. `setAside` is where a NoteIt folder without a library went.
        case moved(setAside: URL?)
        /// The move failed; the returned directory is the legacy folder, used in place.
        case failed(String)
        /// Inkwell is still running and didn't quit. Nothing was touched; no library may be opened.
        case legacyAppRunning

        public var allowsSeeding: Bool { self == .freshInstall }
    }

    /// Returns the library directory to use under `baseDirectory` (normally Application Support).
    /// Never seeds or creates a library. If the move fails, the legacy folder is returned so the
    /// existing library is opened rather than a fresh one being seeded next to it.
    ///
    /// - Parameters:
    ///   - isLegacyAppRunning: whether Inkwell is running. It would keep writing to the old folder, so
    ///     the library is never moved while it runs.
    ///   - quitLegacyApp: asks Inkwell to quit (and waits); returns whether it's gone. Only called when
    ///     a move is needed and Inkwell is running.
    public static func resolve(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        isLegacyAppRunning: () -> Bool,
        quitLegacyApp: () -> Bool,
        move: ((URL, URL) throws -> Void)? = nil,
        now: Date = Date(),
        log: (String) -> Void = { NSLog("%@", $0) }
    ) -> (directory: URL, outcome: Outcome) {
        let current = baseDirectory.appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true)
        let legacy = baseDirectory.appendingPathComponent(AppIdentity.Legacy.dataFolderName, isDirectory: true)
        let doMove: (URL, URL) throws -> Void = move ?? { try fileManager.moveItem(at: $0, to: $1) }

        if hasLibrary(current, fileManager) {
            if hasLibrary(legacy, fileManager) {
                log("NoteIt: libraries found in both \(current.path) and \(legacy.path); using NoteIt's and leaving Inkwell's untouched")
            }
            return (current, .existing)
        }
        guard hasLibrary(legacy, fileManager) else { return (current, .freshInstall) }

        if isLegacyAppRunning() {
            guard quitLegacyApp(), !isLegacyAppRunning() else {
                log("NoteIt: Inkwell is still running; not moving its library")
                return (legacy, .legacyAppRunning)
            }
        }

        // A NoteIt folder without a library (stray logs, index or sync state) goes aside, not away.
        var setAside: URL?
        if fileManager.fileExists(atPath: current.path) {
            let aside = asideURL(for: current, now: now, fileManager)
            do {
                try doMove(current, aside)
                setAside = aside
                log("NoteIt: moved \(current.path), which held no library, to \(aside.path)")
            } catch {
                log("NoteIt: couldn't move \(current.path) aside (\(error)); using \(legacy.path) in place")
                return (legacy, .failed(String(describing: error)))
            }
        }

        do {
            // A single rename on the same volume: hidden files (.initialized, .trash/) and sync state move with it.
            try doMove(legacy, current)
            log("NoteIt: moved library from \(legacy.path) to \(current.path)")
            return (current, .moved(setAside: setAside))
        } catch {
            log("NoteIt: couldn't move library from \(legacy.path) to \(current.path) (\(error)); using it in place")
            if let setAside {
                do { try doMove(setAside, current) } catch { log("NoteIt: couldn't restore \(setAside.path) (\(error))") }
            }
            return (legacy, .failed(String(describing: error)))
        }
    }

    /// A library is real when it has `library.json`, any note body, or the first-launch marker.
    public static func hasLibrary(_ directory: URL, _ fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: directory.appendingPathComponent("library.json").path) { return true }
        if fileManager.fileExists(atPath: directory.appendingPathComponent(".initialized").path) { return true }
        let notes = directory.appendingPathComponent("notes", isDirectory: true)
        let bodies = (try? fileManager.contentsOfDirectory(atPath: notes.path)) ?? []
        return bodies.contains { !$0.hasPrefix(".") }
    }

    private static func asideURL(for current: URL, now: Date, _ fileManager: FileManager) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(current.lastPathComponent).pre-migration-\(formatter.string(from: now))"
        let parent = current.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent(stem, isDirectory: true)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stem)-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
