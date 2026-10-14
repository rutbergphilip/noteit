import AppKit
import Foundation

struct NoteVersion: Identifiable, Hashable {
    let noteID: UUID
    let date: Date
    let url: URL
    var id: URL { url }
}

/// Earlier bodies of each note, at `history/<note UUID>/<yyyyMMdd'T'HHmmss'Z'>.rtfd`. Versions stay on
/// this Mac: they aren't synced, indexed for search or listed in library.json.
final class VersionHistory {
    /// A saved body is kept only when the newest version is older than this.
    static let minimumInterval: TimeInterval = 10 * 60
    static let maxVersions = 50
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    let rootURL: URL
    /// Replaced in tests.
    var now: () -> Date = Date.init

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Newest first.
    func versions(of id: UUID) -> [NoteVersion] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory(for: id), includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url -> NoteVersion? in
            guard url.pathExtension == "rtfd",
                  let date = Self.fileNameFormatter.date(from: url.deletingPathExtension().lastPathComponent) else { return nil }
            return NoteVersion(noteID: id, date: date, url: url)
        }
        .sorted { $0.date > $1.date }
    }

    /// Keeps the saved body at `bodyURL` before it's replaced: always when `force` is set, otherwise only
    /// when the newest version is more than 10 minutes old or there's none.
    @discardableResult
    func recordSavedBody(at bodyURL: URL, of id: UUID, force: Bool = false) -> NoteVersion? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bodyURL.path) else { return nil }
        let date = now()
        if !force, let newest = versions(of: id).first, date.timeIntervalSince(newest.date) <= Self.minimumInterval {
            return nil
        }
        let dir = directory(for: id)
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).rtfd.tmp", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: bodyURL, to: temp)
            return try install(temp, of: id, at: date)
        } catch {
            try? fm.removeItem(at: temp)
            NSLog("NoteIt: failed to keep a version of note \(id): \(error)")
            return nil
        }
    }

    /// Keeps `text` as a version, for bodies that may not be saved yet (before restoring a version).
    @discardableResult
    func record(_ text: NSAttributedString, of id: UUID) -> NoteVersion? {
        do {
            let temp = try NoteStore.writeTempBody(text, in: directory(for: id))
            return try install(temp, of: id, at: now())
        } catch {
            NSLog("NoteIt: failed to keep a version of note \(id): \(error)")
            return nil
        }
    }

    func load(_ version: NoteVersion) throws -> NSAttributedString {
        try NoteStore.readBody(at: version.url)
    }

    /// Drops versions beyond the newest 50 and any older than 30 days.
    func prune(_ id: UUID) {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        let fm = FileManager.default
        let all = versions(of: id)
        var kept = all.count
        for (offset, version) in all.enumerated() where offset >= Self.maxVersions || version.date < cutoff {
            try? fm.removeItem(at: version.url)
            kept -= 1
        }
        if kept == 0 { removeHistory(of: id) }
    }

    /// Prunes every note's history and removes the history of notes not in `existing`.
    func pruneAll(keeping existing: Set<UUID>) {
        let items = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        for url in items {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            if existing.contains(id) { prune(id) } else { removeHistory(of: id) }
        }
    }

    func removeHistory(of id: UUID) {
        let dir = directory(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            NSLog("NoteIt: failed to remove the history of note \(id): \(error)")
        }
    }

    /// Renames a finished temp package into place. Names are per second, so a clash moves on to the next free one.
    private func install(_ temp: URL, of id: UUID, at date: Date) throws -> NoteVersion {
        let fm = FileManager.default
        var stamp = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        var url = versionURL(id, stamp)
        while fm.fileExists(atPath: url.path) {
            stamp.addTimeInterval(1)
            url = versionURL(id, stamp)
        }
        do {
            try fm.moveItem(at: temp, to: url)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        prune(id)
        return NoteVersion(noteID: id, date: stamp, url: url)
    }

    private func versionURL(_ id: UUID, _ date: Date) -> URL {
        directory(for: id).appendingPathComponent("\(Self.fileNameFormatter.string(from: date)).rtfd", isDirectory: true)
    }
}

extension NoteStore {
    func versions(of id: UUID) -> [NoteVersion] {
        history.versions(of: id)
    }

    /// Replaces the note's body with `version`. The current body, unsaved edits included, is kept as a
    /// version first, so a restore can itself be undone.
    func restoreVersion(_ version: NoteVersion) throws {
        let id = version.noteID
        guard let meta = note(with: id), meta.deletedAt == nil, !isBodyWriteBlocked(id) else { return }
        let text = try history.load(version)
        handOverPendingEdits(id)
        let current = body(for: id)
        guard !current.isEqual(to: text) else { return }
        history.record(current, of: id)
        updateBody(id, text)
        flush()
        externallyUpdatedNoteID = id
    }
}
