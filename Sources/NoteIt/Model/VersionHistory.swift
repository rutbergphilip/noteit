import AppKit
import Foundation

struct NoteVersion: Identifiable, Hashable {
    let noteID: UUID
    let date: Date
    let url: URL
    var id: URL { url }
}

/// Earlier bodies of each note, at `history/<note UUID>/<yyyyMMdd'T'HHmmss'Z'>.rtfd`, or `.noteitdoc` for a Markdown
/// library (its `.md` files aren't a lossless copy of the editor text). Both kinds are listed and restored, whichever
/// the library writes now. Versions stay on this Mac: they aren't synced, indexed for search or listed in library.json.
final class VersionHistory {
    /// A saved body is kept only when the newest version is older than this.
    static let minimumInterval: TimeInterval = 10 * 60
    static let maxVersions = 50
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    let rootURL: URL
    /// `.rtfd` or `.noteItDoc`: what new versions are written as.
    let format: BodyCodec
    /// Replaced in tests.
    var now: () -> Date = Date.init

    init(rootURL: URL, format: BodyCodec = .rtfd) {
        precondition(format != .markdown, "versions are kept losslessly")
        self.rootURL = rootURL
        self.format = format
    }

    private static let versionExtensions: Set<String> = [BodyCodec.rtfd.fileExtension, BodyCodec.noteItDoc.fileExtension]

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
            guard Self.versionExtensions.contains(url.pathExtension),
                  let date = Self.fileNameFormatter.date(from: url.deletingPathExtension().lastPathComponent) else { return nil }
            return NoteVersion(noteID: id, date: date, url: url)
        }
        .sorted { $0.date > $1.date }
    }

    /// Keeps the saved body at `bodyURL` before it's replaced: always when `force` is set, otherwise only
    /// when the newest version is more than 10 minutes old or there's none. `extras` is the saved body's entry
    /// (foundations Task 4.5); it is only evaluated when a version is kept.
    @discardableResult
    func recordSavedBody(at bodyURL: URL, extras: @autoclosure () -> BodyExtrasEntry, of id: UUID,
                         force: Bool = false) -> NoteVersion? {
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
            return try install(temp, extras: extras(), of: id, at: date, as: .rtfd)
        } catch {
            try? fm.removeItem(at: temp)
            NSLog("NoteIt: failed to keep a version of note \(id): \(error)")
            return nil
        }
    }

    /// `recordSavedBody` for a library whose body files aren't versions themselves: `read` loads the saved body
    /// and is only called when a version is kept. A body that can't be read is not kept.
    @discardableResult
    func recordSavedBody(reading read: () throws -> StoredBody?, of id: UUID, force: Bool = false) -> NoteVersion? {
        let date = now()
        if !force, let newest = versions(of: id).first, date.timeIntervalSince(newest.date) <= Self.minimumInterval {
            return nil
        }
        do {
            guard let stored = try read(), stored.readOnlyReason == nil else { return nil }
            return try record(stored.text, extras: stored.extras, of: id, at: date)
        } catch {
            NSLog("NoteIt: failed to keep a version of note \(id): \(error)")
            return nil
        }
    }

    /// Keeps `text` as a version with `extras` and the text's code-language IDs, for bodies that may not be saved
    /// yet (editBody records the current body this way).
    @discardableResult
    func record(_ text: NSAttributedString, extras: ContainerExtras, of id: UUID) -> NoteVersion? {
        if format == .noteItDoc {
            do {
                return try record(text, extras: extras, of: id, at: now())
            } catch {
                NSLog("NoteIt: failed to keep a version of note \(id): \(error)")
                return nil
            }
        }
        var temp: URL?
        do {
            let written = try NoteStore.writeTempBody(text, in: directory(for: id))
            temp = written
            let entry = BodyExtrasEntry(bodySHA256: try RTFDBodyStorage.packageDigest(at: written), extras: extras,
                                        codeLanguageIDs: NoteStore.codeLanguageIDs(of: text))
            return try install(written, extras: entry, of: id, at: now(), as: .rtfd)
        } catch {
            if let temp { try? FileManager.default.removeItem(at: temp) }
            NSLog("NoteIt: failed to keep a version of note \(id): \(error)")
            return nil
        }
    }

    /// A `.noteitdoc` version: the document holds its extras and code languages, so no extras file is written.
    private func record(_ text: NSAttributedString, extras: ContainerExtras, of id: UUID, at date: Date) throws -> NoteVersion {
        let dir = directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).noteitdoc.tmp")
        do {
            try BodyCodec.noteItDoc.data(of: text, extras: extras).write(to: temp, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return try install(temp, extras: nil, of: id, at: date, as: .noteItDoc)
    }

    /// The version's text, and its extras (nil for a version from before extras support, which has no extras
    /// file). Stored code-language IDs are set on the code paragraphs by position when the counts match. Throws
    /// when the extras file exists but can't be read or decoded.
    func load(_ version: NoteVersion) throws -> (text: NSAttributedString, extras: ContainerExtras?) {
        if version.url.pathExtension == BodyCodec.noteItDoc.fileExtension {
            let stored = try BodyCodec.noteItDoc.read(at: version.url)
            return (stored.text, stored.extras)
        }
        let text = try NoteStore.readBody(at: version.url)
        let url = Self.extrasURL(of: version.url)
        guard FileManager.default.fileExists(atPath: url.path) else { return (text, nil) }
        let entry = try BodyExtrasEntry(json: JSONValue.decode(Data(contentsOf: url)))
        let ranges = NoteStore.codeParagraphRanges(in: text)
        guard entry.codeLanguageIDs.contains(where: { $0 != nil }), ranges.count == entry.codeLanguageIDs.count else {
            return (text, entry.extras)
        }
        let result = NSMutableAttributedString(attributedString: text)
        for (range, language) in zip(ranges, entry.codeLanguageIDs) {
            guard let language else { continue }
            result.addAttribute(.noteItCodeLanguageID, value: language, range: range)
        }
        return (result, entry.extras)
    }

    /// Drops versions beyond the newest 50 and any older than 30 days, each with its extras file, and extras files
    /// with no version (left by a crash between the two writes).
    func prune(_ id: UUID) {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        let fm = FileManager.default
        let all = versions(of: id)
        var kept = all.count
        for (offset, version) in all.enumerated() where offset >= Self.maxVersions || version.date < cutoff {
            try? fm.removeItem(at: Self.extrasURL(of: version.url))
            try? fm.removeItem(at: version.url)
            kept -= 1
        }
        let items = (try? fm.contentsOfDirectory(at: directory(for: id), includingPropertiesForKeys: nil)) ?? []
        for url in items where url.lastPathComponent.hasSuffix(Self.extrasSuffix) {
            let stem = String(url.lastPathComponent.dropLast(Self.extrasSuffix.count))
            let package = url.deletingLastPathComponent().appendingPathComponent("\(stem).rtfd", isDirectory: true)
            if !fm.fileExists(atPath: package.path) { try? fm.removeItem(at: url) }
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
        do {
            try deleteHistory(of: id)
        } catch {
            NSLog("NoteIt: failed to remove the history of note \(id): \(error)")
        }
    }

    /// Deletes the note's versions and their extras files; throws when that fails.
    func deleteHistory(of id: UUID) throws {
        let dir = directory(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    /// `<stamp>.extras.json` beside `<stamp>.rtfd`.
    static func extrasURL(of versionURL: URL) -> URL {
        let stem = (versionURL.lastPathComponent as NSString).deletingPathExtension
        return versionURL.deletingLastPathComponent().appendingPathComponent(stem + extrasSuffix, isDirectory: false)
    }

    private static let extrasSuffix = ".extras.json"

    /// Replaced in tests: makes writing a version's extras file fail.
    var failsExtrasWrite = false

    /// Picks a free per-second stamp (a clash moves on to the next one), writes the extras file atomically, then
    /// renames the finished temp package into place. If either step fails, nothing of the version is left.
    private func install(_ temp: URL, extras: BodyExtrasEntry?, of id: UUID, at date: Date, as format: BodyCodec) throws -> NoteVersion {
        let fm = FileManager.default
        var stamp = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        var url = versionURL(id, stamp, format)
        while isTaken(id, stamp) {
            stamp.addTimeInterval(1)
            url = versionURL(id, stamp, format)
        }
        let extrasURL = Self.extrasURL(of: url)
        do {
            if failsExtrasWrite { throw CocoaError(.fileWriteUnknown) }
            if let extras { try extras.json.encoded().write(to: extrasURL, options: .atomic) }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        do {
            try fm.moveItem(at: temp, to: url)
        } catch {
            try? fm.removeItem(at: temp)
            try? fm.removeItem(at: extrasURL)
            throw error
        }
        prune(id)
        return NoteVersion(noteID: id, date: stamp, url: url)
    }

    private func versionURL(_ id: UUID, _ date: Date, _ format: BodyCodec) -> URL {
        directory(for: id).appendingPathComponent("\(Self.fileNameFormatter.string(from: date)).\(format.fileExtension)",
                                                  isDirectory: format == .rtfd)
    }

    private func isTaken(_ id: UUID, _ date: Date) -> Bool {
        let fm = FileManager.default
        let rtfd = versionURL(id, date, .rtfd)
        return fm.fileExists(atPath: rtfd.path) || fm.fileExists(atPath: Self.extrasURL(of: rtfd).path)
            || fm.fileExists(atPath: versionURL(id, date, .noteItDoc).path)
    }
}

extension NoteStore {
    func versions(of id: UUID) -> [NoteVersion] {
        history.versions(of: id)
    }

    /// The extras of the body on disk, for the version `recordSavedBody` keeps before a write replaces it: the sidecar
    /// entry whose digest matches the saved package (what step 1 of the write stores as `previous`), else `.empty`
    /// extras with no IDs and the package's digest. Other stores keep extras in the body file itself.
    func savedBodyVersionEntry(_ id: UUID) -> BodyExtrasEntry {
        let digest = (try? RTFDBodyStorage.packageDigest(at: bodyURL(for: id))) ?? ""
        guard bodyStorage.kind == .rtfd else {
            return BodyExtrasEntry(bodySHA256: digest, extras: .empty, codeLanguageIDs: [])
        }
        if let sidecar = try? readBodyExtrasSidecar(id), let entry = sidecar.matchingEntry(forBodySHA256: digest) {
            return entry
        }
        return BodyExtrasEntry(bodySHA256: digest, extras: .empty, codeLanguageIDs: [])
    }

    /// Replaces the note's body with `version` (its text and, when it has them, its extras) through `editBody`, which
    /// first keeps the current body, unsaved edits included, as a version. In an open note it is one Undo step.
    /// A note that can't be edited is left alone quietly; `versionNotSaved` is thrown.
    func restoreVersion(_ version: NoteVersion) throws {
        let loaded = try history.load(version)
        do {
            try editBody(version.noteID, actionName: "Restore Version", versioning: .recordCurrent, extras: loaded.extras) {
                $0.setAttributedString(loaded.text)
            }
        } catch let error as BodyEditError where error != .versionNotSaved {
            return
        }
    }
}
