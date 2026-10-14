import AppKit

/// Imports Markdown and plain-text files, Obsidian vaults and Bear exports (`.textbundle` folders,
/// `.textpack` zips or plain Markdown).
@MainActor
final class MarkdownImporter {
    nonisolated static let textExtensions: Set<String> = ["md", "markdown", "txt"]
    nonisolated static let bundleExtensions: Set<String> = ["textbundle", "textpack"]

    /// One note to import, with the notebook it goes into.
    struct Item: Equatable {
        var url: URL
        var notebook: String
        /// Where wiki-style `![[image.png]]` names are looked up.
        var root: URL
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
                result.append(Item(url: url, notebook: parent.lastPathComponent, root: parent))
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
            if isImportable(url) { result.append(Item(url: url, notebook: notebook, root: root)) }
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
        progress(ImportProgress(completed: 0, total: items.count))
        for (index, item) in items.enumerated() {
            if Task.isCancelled { report.cancelled = true; break }
            progress(ImportProgress(completed: index, total: items.count, currentName: item.url.deletingPathExtension().lastPathComponent))
            if nameIndexes[item.root] == nil { nameIndexes[item.root] = Self.fileIndex(under: item.root) }
            if importItem(item, nameIndex: nameIndexes[item.root] ?? [:], report: &report) == false {
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
    func importItem(_ item: Item, nameIndex: [String: URL] = [:], report: inout ImportReport) -> Bool {
        let ext = item.url.pathExtension.lowercased()
        if ext == "textpack" {
            guard let unpacked = unzip(item.url) else { return false }
            defer { try? fileManager.removeItem(at: unpacked) }
            guard let bundle = Self.textBundle(in: unpacked) else { return false }
            return importBundle(bundle, named: item.url.deletingPathExtension().lastPathComponent, item: item, report: &report)
        }
        if ext == "textbundle" {
            return importBundle(item.url, named: item.url.deletingPathExtension().lastPathComponent, item: item, report: &report)
        }
        guard let text = Self.readText(item.url) else { return false }
        let fileDates = Self.fileDates(item.url)
        let folder = item.url.deletingLastPathComponent()
        let resolver = Self.resolver(base: folder, root: item.root, nameIndex: nameIndex)
        let name = item.url.deletingPathExtension().lastPathComponent
        let note: MarkdownNote = ext == "txt"
            ? Self.plainTextNote(text, fallbackTitle: name)
            : MarkdownReader.note(from: text, fallbackTitle: name, resolveImage: resolver)
        save(note, notebook: item.notebook, created: note.frontMatter.created ?? fileDates.created,
             updated: note.frontMatter.updated ?? fileDates.modified, report: &report)
        return true
    }

    /// A TextBundle: `text.md` (or `.markdown`/`.txt`) plus an `assets` folder; Bear adds its dates to `info.json`.
    private func importBundle(_ bundle: URL, named name: String, item: Item, report: inout ImportReport) -> Bool {
        let candidates = ["text.md", "text.markdown", "text.txt"].map { bundle.appendingPathComponent($0) }
        let textURL = candidates.first { fileManager.fileExists(atPath: $0.path) }
            ?? ((try? fileManager.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? [])
                .first { Self.textExtensions.contains($0.pathExtension.lowercased()) }
        guard let textURL, let text = Self.readText(textURL) else { return false }
        let resolver = Self.resolver(base: bundle, root: bundle, nameIndex: Self.fileIndex(under: bundle))
        let note = textURL.pathExtension.lowercased() == "txt"
            ? Self.plainTextNote(text, fallbackTitle: name)
            : MarkdownReader.note(from: text, fallbackTitle: name, resolveImage: resolver)
        let info = Self.bundleDates(bundle)
        let fileDates = Self.fileDates(item.url)
        save(note, notebook: item.notebook,
             created: note.frontMatter.created ?? info.created ?? fileDates.created,
             updated: note.frontMatter.updated ?? info.modified ?? fileDates.modified, report: &report)
        return true
    }

    private func save(_ note: MarkdownNote, notebook: String, created: Date?, updated: Date?, report: inout ImportReport) {
        let nb = store.notebookForImport(named: notebook)
        store.createImportedNote(body: note.body, title: note.title, notebookID: nb.id, createdAt: created, updatedAt: updated)
        report.notesImported += 1
        report.notebookIDs.insert(nb.id)
    }

    private func unzip(_ url: URL) -> URL? {
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
        guard process.terminationStatus == 0 else {
            try? fileManager.removeItem(at: destination)
            return nil
        }
        return destination
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

    /// Resolves a reference relative to the note, then to the import root, then by file name.
    nonisolated static func resolver(base: URL, root: URL, nameIndex: [String: URL]) -> MarkdownReader.ImageResolver {
        { reference in
            var path = reference.removingPercentEncoding ?? reference
            if path.hasPrefix("file://"), let url = URL(string: reference) { path = url.path }
            let fm = FileManager.default
            var candidates: [URL] = []
            if path.hasPrefix("/") {
                candidates.append(URL(fileURLWithPath: path))
            } else {
                candidates.append(base.appendingPathComponent(path))
                candidates.append(root.appendingPathComponent(path))
            }
            for url in candidates {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { return url.standardizedFileURL }
            }
            return nameIndex[(path as NSString).lastPathComponent.lowercased()]
        }
    }
}
