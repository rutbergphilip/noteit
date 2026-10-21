import AppKit
import NoteItCore

/// Imports Markdown and plain-text files, Obsidian vaults and Bear exports (`.textbundle` folders,
/// `.textpack` zips or plain Markdown).
@MainActor
final class MarkdownImporter {
    nonisolated static let textExtensions: Set<String> = ["md", "markdown", "txt"]
    nonisolated static let bundleExtensions: Set<String> = ["textbundle", "textpack"]
    /// Larger images are left out of the note and counted as skipped attachments.
    nonisolated static let maxImageBytes = 25 * 1024 * 1024

    /// One note to import, with the notebook it goes into.
    struct Item: Equatable {
        var url: URL
        var notebook: String
        /// Images must stay inside this folder; for a chosen folder, `![[image.png]]` names are looked up anywhere in it.
        var root: URL
        /// False for loose files, whose images are only looked up next to them.
        var indexesRoot = true
    }

    private let store: NoteStore
    private let fileManager = FileManager.default

    init(store: NoteStore) {
        self.store = store
    }

    // MARK: Walking

    /// The files to import from the chosen files and folders. Folders become notebooks named after
    /// them, subfolders `Folder / Subfolder`; loose files go into a notebook named after their folder.
    nonisolated static func items(for urls: [URL]) -> [Item] {
        var result: [Item] = []
        for url in urls {
            let url = url.standardizedFileURL
            if isDirectory(url), !isBundle(url) {
                walk(url, notebook: url.lastPathComponent, root: url, into: &result)
            } else if isImportable(url) {
                let parent = url.deletingLastPathComponent()
                result.append(Item(url: url, notebook: parent.lastPathComponent, root: parent, indexesRoot: false))
            }
        }
        return result
    }

    nonisolated private static func walk(_ folder: URL, notebook: String, root: URL, into result: inout [Item]) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = contents
            .filter { !isSkipped($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in sorted where !isDirectory(url) || isBundle(url) {
            if isImportable(url), isInside(url, root: root) { result.append(Item(url: url, notebook: notebook, root: root)) }
        }
        for url in sorted where isDirectory(url) && !isBundle(url) {
            walk(url, notebook: notebook + " / " + url.lastPathComponent, root: root, into: &result)
        }
    }

    nonisolated static func isSkipped(_ name: String) -> Bool {
        name.hasPrefix(".")
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    nonisolated private static func isBundle(_ url: URL) -> Bool {
        bundleExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated private static func isImportable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return textExtensions.contains(ext) || bundleExtensions.contains(ext)
    }

    // MARK: Importing

    /// Imports `items`, reporting progress after each note and stopping early when the task is cancelled.
    func run(_ items: [Item], progress: (ImportProgress) -> Void) async -> ImportReport {
        var report = ImportReport()
        var nameIndexes: [URL: [String: URL]] = [:]
        let ids = items.map { _ in UUID() }
        var names: [String: UUID] = [:]
        for (item, id) in zip(items, ids) {
            let key = TextFold.fold(item.url.deletingPathExtension().lastPathComponent)
            if names[key] == nil { names[key] = id }
        }
        let store = store
        let resolveWikiLink = Self.wikiLinkResolver(names: names) { store.noteID(forTitle: $0, preferring: nil) }
        progress(ImportProgress(completed: 0, total: items.count))
        for (index, item) in items.enumerated() {
            if Task.isCancelled { report.cancelled = true; break }
            progress(ImportProgress(completed: index, total: items.count, currentName: item.url.deletingPathExtension().lastPathComponent))
            if item.indexesRoot, nameIndexes[item.root] == nil { nameIndexes[item.root] = Self.fileIndex(under: item.root) }
            if importItem(item, nameIndex: item.indexesRoot ? nameIndexes[item.root] ?? [:] : [:], id: ids[index],
                          resolveWikiLink: item.indexesRoot ? resolveWikiLink : nil, report: &report) == false {
                report.filesSkipped += 1
            }
            await Task.yield()
        }
        progress(ImportProgress(completed: report.cancelled ? report.notesImported : items.count, total: items.count))
        store.flush()
        return report
    }

    /// Imports one file or bundle. Returns false when it couldn't be read.
    @discardableResult
    func importItem(_ item: Item, nameIndex: [String: URL] = [:], id: UUID? = nil, resolveWikiLink: WikiLinkResolver? = nil,
                    report: inout ImportReport) -> Bool {
        let ext = item.url.pathExtension.lowercased()
        if ext == "textpack" {
            guard let unpacked = unzip(item.url) else { return false }
            defer { try? fileManager.removeItem(at: unpacked) }
            guard let bundle = Self.textBundle(in: unpacked) else { return false }
            return importBundle(bundle, named: item.url.deletingPathExtension().lastPathComponent, item: item, id: id, report: &report)
        }
        if ext == "textbundle" {
            return importBundle(item.url, named: item.url.deletingPathExtension().lastPathComponent, item: item, id: id, report: &report)
        }
        guard let text = Self.readText(item.url) else { return false }
        let fileDates = Self.fileDates(item.url)
        let folder = item.url.deletingLastPathComponent()
        let skipped = SkippedImages()
        let resolver = Self.resolver(base: folder, root: item.root, nameIndex: nameIndex, skipped: skipped)
        let name = item.url.deletingPathExtension().lastPathComponent
        let note: MarkdownNote = ext == "txt"
            ? Self.plainTextNote(text, fallbackTitle: name)
            : MarkdownReader.note(from: text, fallbackTitle: name, resolveImage: resolver, resolveWikiLink: resolveWikiLink)
        report.attachmentsSkipped += skipped.count
        save(note, notebook: item.notebook, created: note.frontMatter.created ?? fileDates.created,
             updated: note.frontMatter.updated ?? fileDates.modified, id: id, report: &report)
        return true
    }

    /// A TextBundle: `text.md` (or `.markdown`/`.txt`) plus an `assets` folder; Bear adds its dates to `info.json`.
    private func importBundle(_ bundle: URL, named name: String, item: Item, id: UUID?, report: inout ImportReport) -> Bool {
        let candidates = ["text.md", "text.markdown", "text.txt"].map { bundle.appendingPathComponent($0) }
        let textURL = candidates.first { fileManager.fileExists(atPath: $0.path) }
            ?? ((try? fileManager.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? [])
                .first { Self.textExtensions.contains($0.pathExtension.lowercased()) }
        guard let textURL, Self.isInside(textURL, root: bundle), let text = Self.readText(textURL) else { return false }
        let skipped = SkippedImages()
        let resolver = Self.resolver(base: bundle, root: bundle, nameIndex: Self.fileIndex(under: bundle), skipped: skipped)
        let note = textURL.pathExtension.lowercased() == "txt"
            ? Self.plainTextNote(text, fallbackTitle: name)
            : MarkdownReader.note(from: text, fallbackTitle: name, resolveImage: resolver)
        report.attachmentsSkipped += skipped.count
        let info = Self.bundleDates(bundle)
        let fileDates = Self.fileDates(item.url)
        save(note, notebook: item.notebook,
             created: note.frontMatter.created ?? info.created ?? fileDates.created,
             updated: note.frontMatter.updated ?? info.modified ?? fileDates.modified, id: id, report: &report)
        return true
    }

    private func save(_ note: MarkdownNote, notebook: String, created: Date?, updated: Date?, id: UUID?, report: inout ImportReport) {
        let nb = store.notebookForImport(named: notebook)
        store.createImportedNote(body: note.body, title: note.title, notebookID: nb.id, createdAt: created, updatedAt: updated, id: id)
        report.notesImported += 1
        report.notebookIDs.insert(nb.id)
    }

    /// Resolves a wiki-link target to a note in the same import by file name (folded), then to an existing
    /// note with that title, else to an unresolved title link.
    static func wikiLinkResolver(names: [String: UUID], existing: @escaping (String) -> UUID?) -> WikiLinkResolver {
        { target, heading in
            if let id = names[TextFold.fold(target)] ?? existing(target) { return .note(id: id, heading: heading) }
            return .unresolved(title: target, heading: heading)
        }
    }

    /// Unpacks a `.textpack` into a temporary folder, refusing archives with entries that would land outside it.
    private func unzip(_ url: URL) -> URL? {
        guard let entries = Self.zipEntries(url), entries.allSatisfy(Self.isSafeZipEntry) else { return nil }
        let destination = fileManager.temporaryDirectory.appendingPathComponent("noteit-import-\(UUID().uuidString)", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0, Self.staysInside(destination) else {
            try? fileManager.removeItem(at: destination)
            return nil
        }
        return destination
    }

    /// The entry names in a zip archive, or nil when it can't be listed.
    nonisolated static func zipEntries(_ url: URL) -> [String]? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", url.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    nonisolated static func isSafeZipEntry(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.hasPrefix("/") && !name.hasPrefix("~") && !parts.contains("..")
    }

    /// True when everything under `folder`, with symlinks followed, is still inside it.
    nonisolated static func staysInside(_ folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in enumerator where !isInside(url, root: folder) {
            return false
        }
        return true
    }

    /// The bundle inside an unpacked `.textpack`, or the unpacked folder itself.
    nonisolated static func textBundle(in folder: URL) -> URL? {
        let fm = FileManager.default
        if ["text.md", "text.markdown", "text.txt"].contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
            return folder
        }
        let contents = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if let bundle = contents.first(where: { $0.pathExtension.lowercased() == "textbundle" }) { return bundle }
        if contents.count == 1, isDirectory(contents[0]) { return textBundle(in: contents[0]) }
        return nil
    }

    // MARK: Reading

    nonisolated static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        for encoding: String.Encoding in [.utf16, .windowsCP1252, .isoLatin1] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return nil
    }

    /// Plain text: one body paragraph per line, titled by the file name unless the first line already is.
    nonisolated static func plainTextNote(_ text: String, fallbackTitle: String) -> MarkdownNote {
        var lines = MarkdownReader.lines(of: text)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let body = NSMutableAttributedString()
        var title = fallbackTitle
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty,
           first.caseInsensitiveCompare(fallbackTitle) == .orderedSame {
            title = first
            lines.removeFirst()
        }
        if !title.isEmpty { body.append(EditorStyle.paragraph(title, kind: .title)) }
        for line in lines { body.append(EditorStyle.paragraph(line, kind: .body)) }
        return MarkdownNote(title: title, body: body, frontMatter: MarkdownFrontMatter())
    }

    nonisolated static func fileDates(_ url: URL) -> (created: Date?, modified: Date?) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (values?.creationDate, values?.contentModificationDate)
    }

    /// Bear writes `creationDate` and `modificationDate` into `info.json` under `net.shinyfrog.bear`.
    nonisolated static func bundleDates(_ bundle: URL) -> (created: Date?, modified: Date?) {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("info.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let bear = json["net.shinyfrog.bear"] as? [String: Any] ?? [:]
        func date(_ key: String) -> Date? {
            (bear[key] as? String ?? json[key] as? String).flatMap(MarkdownReader.date(from:))
        }
        return (date("creationDate"), date("modificationDate"))
    }

    // MARK: Images

    /// Every non-hidden file under `root` by lowercased file name, for Obsidian's `![[image.png]]`.
    nonisolated static func fileIndex(under root: URL) -> [String: URL] {
        var index: [String: URL] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return index }
        for case let url as URL in enumerator where MarkdownReader.isImagePath(url.path) {
            let key = url.lastPathComponent.lowercased()
            if index[key] == nil { index[key] = url }
        }
        return index
    }

    /// Resolves an image reference relative to the note, then to the import root, then by file name.
    /// Only image files inside `root` (after following symlinks) and no larger than `maxImageBytes` are used.
    nonisolated static func resolver(base: URL, root: URL, nameIndex: [String: URL],
                                     skipped: SkippedImages = SkippedImages()) -> MarkdownReader.ImageResolver {
        { reference in
            let path = reference.removingPercentEncoding ?? reference
            guard MarkdownReader.isImagePath(path), !path.hasPrefix("/"), !path.hasPrefix("~"), !hasScheme(path) else { return nil }
            let fm = FileManager.default
            var candidates = [base.appendingPathComponent(path), root.appendingPathComponent(path)]
            if let named = nameIndex[(path as NSString).lastPathComponent.lowercased()] { candidates.append(named) }
            var refused = false
            for url in candidates {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard isInside(resolved, root: root), MarkdownReader.isImagePath(resolved.path),
                      let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxImageBytes else {
                    refused = true
                    continue
                }
                return resolved
            }
            if refused { skipped.count += 1 }
            return nil
        }
    }

    /// True for `file:`, `http:` and other URL schemes.
    nonisolated private static func hasScheme(_ path: String) -> Bool {
        guard let colon = path.firstIndex(of: ":") else { return false }
        let scheme = path[..<colon]
        return !scheme.isEmpty && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
    }

    /// True when `url`, with symlinks followed, is `root` or inside it.
    nonisolated static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

/// Counts images an import refused, such as ones that are too large or outside the import folder.
final class SkippedImages {
    var count = 0
}
