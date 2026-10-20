import AppKit
import CryptoKit
import Foundation

/// Today's body files: one `.rtfd` package per note in `<rootURL>/notes`. Owned by the foundations plan (Task 4.1).
/// Holds no extras: reads give `.empty` and writes ignore them, so packages are byte-identical to before.
final class RTFDBodyStorage: NoteBodyStorage, @unchecked Sendable {
    let rootURL: URL
    let kind: LibraryFormatKind = .rtfd

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    var contentRootURL: URL { rootURL.appendingPathComponent("notes", isDirectory: true) }
    private var trashURL: URL { rootURL.appendingPathComponent(".trash", isDirectory: true) }

    func fileURL(for id: UUID) -> URL {
        contentRootURL.appendingPathComponent("\(id.uuidString).rtfd", isDirectory: true)
    }

    func revisionInputURL(for id: UUID) -> URL? {
        fileURL(for: id)
    }

    /// IDs of `notes/<uuid>.rtfd` bodies on disk (ignores temp files and corrupt-backups).
    func idsOnDisk() -> [UUID] {
        let items = (try? FileManager.default.contentsOfDirectory(at: contentRootURL, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url in
            guard url.pathExtension == "rtfd" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
    }

    func read(_ id: UUID) throws -> StoredBody {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return StoredBody(text: try Self.readBody(at: url))
    }

    func write(_ text: NSAttributedString, extras: ContainerExtras, for note: NoteMeta, notebook: Notebook?) throws {
        let temp = try prepareTemp(text, extras: extras, for: note.id)
        try installTemp(temp, for: note, notebook: notebook)
    }

    func writeMetadataOnly(for note: NoteMeta, notebook: Notebook?) throws {}

    func prepareTemp(_ text: NSAttributedString, extras: ContainerExtras, for id: UUID) throws -> URL {
        try Self.writeTempBody(text, in: contentRootURL)
    }

    func installTemp(_ temp: URL, for note: NoteMeta, notebook: Notebook?) throws {
        try Self.installBody(temp, at: fileURL(for: note.id))
    }

    func moveToTrash(_ id: UUID) throws {
        let fm = FileManager.default
        let url = fileURL(for: id)
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let dest = Self.uniqueURL(trashURL.appendingPathComponent("\(id.uuidString)-\(Self.timestamp()).rtfd"))
        try fm.moveItem(at: url, to: dest)
    }

    func recover(_ id: UUID) throws -> StoredBody? {
        let prefix = "\(id.uuidString)-"
        let items = (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)) ?? []
        // Names are `<id>-<yyyyMMdd-HHmmss>.rtfd`, with `-<n>` appended by uniqueURL on a clash.
        let candidates = items.compactMap { url -> (stamp: String, n: Int, url: URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), let dot = name.range(of: ".rtfd") else { return nil }
            let stamp = String(name[name.index(name.startIndex, offsetBy: prefix.count)..<dot.lowerBound])
            let rest = name[dot.upperBound...]
            if rest.isEmpty { return (stamp, 0, url) }
            guard rest.hasPrefix("-"), let n = Int(rest.dropFirst()) else { return nil }
            return (stamp, n, url)
        }
        guard let newest = candidates.max(by: { ($0.stamp, $0.n) < ($1.stamp, $1.n) }) else { return nil }
        return StoredBody(text: try Self.readBody(at: newest.url))
    }

    func removePermanently(_ id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func recoveryCopy(_ text: NSAttributedString, for id: UUID, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Self.uniqueURL(directory.appendingPathComponent("\(id.uuidString)-\(Self.timestamp()).rtfd"))
        let temp = try Self.writeTempBody(text, in: directory)
        try Self.installBody(temp, at: url)
        return url
    }

    func renameNotebook(_ notebook: Notebook, from oldName: String) throws {}

    func removeNotebook(_ notebook: Notebook) throws {}

    // MARK: Package files

    static func readBody(at url: URL) throws -> NSAttributedString {
        try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
    }

    /// Writes `text` as RTFD to a hidden temp package in `directory`; safe off the main actor.
    static func writeTempBody(_ text: NSAttributedString, in directory: URL) throws -> URL {
        let range = NSRange(location: 0, length: text.length)
        let wrapper = try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).rtfd.tmp", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try wrapper.write(to: temp, options: [], originalContentsURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return temp
    }

    /// Atomically moves a temp package from `writeTempBody` into place (removed on failure).
    static func installBody(_ temp: URL, at url: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Lowercase hex SHA-256 over the package's regular files, sorted by relative path, each as its UTF-8 path,
    /// a 0 byte, its 8-byte big-endian length and its bytes. Stable for the same package on disk; the sidecar's and
    /// Version History's bodySHA256.
    static func packageDigest(at url: URL) throws -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        var files: [(path: String, url: URL)] = []
        if isDir.boolValue {
            for path in try fm.subpathsOfDirectory(atPath: url.path) {
                let item = url.appendingPathComponent(path)
                let type = try fm.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType
                if type == .typeRegular { files.append((path, item)) }
            }
        } else {
            files.append(("", url))
        }
        var hasher = SHA256()
        for file in files.sorted(by: { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }) {
            let data = try Data(contentsOf: file.url)
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            var length = UInt64(data.count).bigEndian
            hasher.update(data: Data(bytes: &length, count: 8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-\(n)")
            n += 1
        }
        return candidate
    }
}
