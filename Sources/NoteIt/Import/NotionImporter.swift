import AppKit
import NoteItCore
import NoteItDoc
import NoteItMarkdown

/// Notion's file and folder names end in the page's 32-character hex id.
enum NotionNames {
    private static let idSuffix = try! NSRegularExpression(pattern: "^(.*?)\\s+([0-9a-f]{32})$", options: [.caseInsensitive])

    /// "Plan 1a2b…c3d4" → ("Plan", "1a2b…c3d4"); a name without an id comes back as it is.
    static func stripID(_ name: String) -> (title: String, id: String?) {
        let ns = name as NSString
        guard let match = idSuffix.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else {
            return (name.trimmingCharacters(in: .whitespaces), nil)
        }
        return (ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces),
                ns.substring(with: match.range(at: 2)).lowercased())
    }

    /// A page or database title from its file name: no `.md` or `.csv`, no `_all` (Notion's full database CSV), no id.
    static func title(ofFile name: String) -> String {
        title(ofStem: stem(ofFile: name))
    }

    /// A title from a folder name or a file name without its extension.
    static func title(ofStem stem: String) -> String {
        let title = stripID(stem).title
        return title.isEmpty ? "Untitled" : title
    }

    static func stem(ofFile name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard ext == "md" || ext == "csv" else { return name }
        var stem = (name as NSString).deletingPathExtension
        if ext == "csv", stem.hasSuffix("_all") { stem.removeLast(4) }
        return stem
    }
}

/// Imports Notion's "Markdown & CSV" export: the `.zip` (with its nested part ZIPs) or the unzipped folder.
/// Each top-level page with subpages becomes a notebook holding it and everything below it; other top-level pages
/// go to a notebook named "Notion". Links between pages become note links.
@MainActor
enum NotionImporter {
    nonisolated static let maxTableRows = 1_000
    nonisolated static let looseNotebookName = "Notion"

    /// A page (`.md`) or database (`.csv`) in the export.
    struct Page: Equatable {
        var file: URL
        /// Path inside the export without the extension (and without `_all` for a database), "/"-separated.
        var key: String
        var notebook: String
        /// The top-level folder the notebook comes from ("" for loose pages); pages with the same one share it.
        var notebookKey: String
        var title: String
        var isTable: Bool
    }

    static func importExport(_ url: URL, into store: NoteStore, limits: ZipLimits = .standard,
                             progress: (ImportProgress) -> Void = { _ in }) async throws -> ImportReport {
        let (roots, temporary, failed) = try await Task.detached { try Self.contentRoots(for: url, limits: limits) }.value
        defer { for folder in temporary { try? FileManager.default.removeItem(at: folder) } }
        let pages: [Page]
        do {
            pages = try await Task.detached { try Self.pages(in: roots) }.value
        } catch ImportError.nothingToImport where !failed.isEmpty {
            throw ImportError.unreadableArchive(failed[0])
        }
        var report = await importPages(pages, roots: roots, into: store, progress: progress)
        report.archivesSkipped = failed
        return report
    }

    // MARK: Finding pages

    /// The folders holding the export: the chosen folder or the unzipped archive, plus each ZIP at its top level
    /// unzipped (one level only).
    /// `temporary` lists the unzipped folders, for the caller to remove; `failed` names the part ZIPs that
    /// couldn't be opened.
    /// Archives that together unpack past `limits` throw `ImportError.archiveTooLarge`.
    nonisolated static func contentRoots(for url: URL, limits: ZipLimits = .standard) throws
        -> (roots: [URL], temporary: [URL], failed: [String]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ImportError.unreadableArchive(url.lastPathComponent) }
        var root = url.standardizedFileURL
        var temporary: [URL] = []
        var budget = limits
        var finished = false
        defer { if !finished { for folder in temporary { try? fm.removeItem(at: folder) } } }
        if !isDir.boolValue {
            guard url.pathExtension.lowercased() == "zip", let unpacked = try MarkdownImporter.unzip(url, within: &budget, excludingTopLevelZips: true) else {
                throw ImportError.unreadableArchive(url.lastPathComponent)
            }
            temporary.append(unpacked)
            root = unpacked
        }
        var roots = [root]
        var failed: [String] = []
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for zip in top.filter({ $0.pathExtension.lowercased() == "zip" })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let unpacked = try MarkdownImporter.unzip(zip, within: &budget) else {
                failed.append(zip.lastPathComponent)
                continue
            }
            temporary.append(unpacked)
            roots.append(unpacked)
        }
        finished = true
        return (roots, temporary, failed)
    }

    /// Every page and database in `roots`, merged by their path inside the export, parents first.
    nonisolated static func pages(in roots: [URL]) throws -> [Page] {
        var files: [(path: [String], url: URL)] = []
        var sawHTML = false
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { continue }
            let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            for case let url as URL in enumerator {
                if url.lastPathComponent == "__MACOSX" { enumerator.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      MarkdownImporter.isInside(url, root: root) else { continue }
                let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                guard parts.starts(with: base) else { continue }
                let path = Array(parts.dropFirst(base.count))
                switch url.pathExtension.lowercased() {
                case "md", "csv": files.append((path, url))
                case "html": sawHTML = true
                default: break
                }
            }
        }
        if files.isEmpty { throw sawHTML ? ImportError.notionHTMLExport : ImportError.nothingToImport }

        // A folder every page sits in (Notion's export or workspace folder) isn't part of the page tree.
        while let first = files.first?.path.first, files.allSatisfy({ $0.path.count > 1 && $0.path[0] == first }) {
            files = files.map { (Array($0.path.dropFirst()), $0.url) }
        }

        func key(_ path: [String]) -> String {
            (path.dropLast() + [NotionNames.stem(ofFile: path.last ?? "")]).joined(separator: "/")
        }
        // A database exported as both `X.csv` (one view) and `X_all.csv` keeps the full one; a page wins over both.
        var chosen: [String: (path: [String], url: URL)] = [:]
        func rank(_ path: [String]) -> Int {
            let name = path.last ?? ""
            if (name as NSString).pathExtension.lowercased() == "md" { return 2 }
            return (name as NSString).deletingPathExtension.hasSuffix("_all") ? 1 : 0
        }
        for file in files {
            let k = key(file.path)
            if let existing = chosen[k], rank(existing.path) >= rank(file.path) { continue }
            chosen[k] = file
        }

        let keys = Set(chosen.keys)
        let topWithChildren = Set(keys.compactMap { $0.split(separator: "/", maxSplits: 1).count > 1 ? String($0.split(separator: "/")[0]) : nil })
        func order(_ a: [String], _ b: [String]) -> Bool {
            for (x, y) in zip(a, b) where x != y { return x.localizedStandardCompare(y) == .orderedAscending }
            return a.count < b.count
        }
        return chosen.values
            .map { file -> Page in
                let k = key(file.path)
                let first = k.split(separator: "/").first.map(String.init) ?? k
                let loose = file.path.count == 1 && !topWithChildren.contains(first)
                return Page(file: file.url, key: k,
                            notebook: loose ? looseNotebookName : NotionNames.title(ofStem: first),
                            notebookKey: loose ? "" : first,
                            title: NotionNames.title(ofFile: file.path.last ?? ""),
                            isTable: (file.path.last as NSString?)?.pathExtension.lowercased() == "csv")
            }
            .sorted { order($0.key.split(separator: "/").map(String.init), $1.key.split(separator: "/").map(String.init)) }
    }

    // MARK: Importing

    static func importPages(_ pages: [Page], roots: [URL], into store: NoteStore,
                            progress: (ImportProgress) -> Void) async -> ImportReport {
        var report = ImportReport()
        let ids = Dictionary(pages.map { ($0.key, UUID()) }, uniquingKeysWith: { a, _ in a })
        var created: [UUID] = []
        var notebooks: [String: UUID] = [:]
        progress(ImportProgress(completed: 0, total: pages.count))
        for (index, page) in pages.enumerated() {
            progress(ImportProgress(completed: index, total: pages.count, currentName: page.title))
            if Task.isCancelled { report.cancelled = true; break }
            guard let id = ids[page.key] else { continue }
            let body: NSAttributedString?
            if page.isTable {
                body = tableBody(page, report: &report)
            } else {
                body = await pageBody(page, roots: roots, ids: ids, report: &report)
            }
            guard let body else {
                report.filesSkipped += 1
                continue
            }
            let notebook = notebooks[page.notebookKey].flatMap { id in store.notebooks.first { $0.id == id } }
                ?? store.newNotebookForImport(named: page.notebook, parentID: nil)
            notebooks[page.notebookKey] = notebook.id
            created.append(store.createImportedNote(body: body, title: page.title, notebookID: notebook.id,
                                                    createdAt: nil, updatedAt: nil, id: id).id)
            report.notesImported += 1
            report.notebookIDs.insert(notebook.id)
            await Task.yield()
        }
        progress(ImportProgress(completed: report.cancelled ? report.notesImported : pages.count, total: pages.count))
        let titles = Dictionary(pages.compactMap { page in ids[page.key].map { ($0, page.title) } }, uniquingKeysWith: { a, _ in a })
        store.unresolveLinksToSkipped(in: created, planned: titles)
        store.flush()
        return report
    }

    private static func pageBody(_ page: Page, roots: [URL], ids: [String: UUID], report: inout ImportReport) async -> NSAttributedString? {
        guard let text = MarkdownImporter.readText(page.file) else { return nil }
        let folder = page.key.split(separator: "/").dropLast().map(String.init)
        let options = MarkdownImportOptions(
            baseURL: page.file.deletingLastPathComponent(),
            resolveImage: { url in Self.readExportFile(url, roots: roots) },
            resolveNoteLink: { target in ids[Self.resolvedKey(target, from: folder)] }
        )
        guard let imported = try? await BodyCodec.attributedString(fromMarkdown: prepared(text), options: options) else {
            return nil
        }
        report.attachmentsSkipped += imported.unresolvedImages.count
        let body = NSMutableAttributedString(attributedString: imported.0)
        retitleUnresolvedLinks(body)
        let first = (body.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let firstText = (body.string as NSString).substring(with: first).trimmingCharacters(in: .whitespacesAndNewlines)
        if firstText.caseInsensitiveCompare(page.title) != .orderedSame {
            body.insert(EditorStyle.paragraph(page.title, kind: .title), at: 0)
        }
        return body
    }

    private static func tableBody(_ page: Page, report: inout ImportReport) -> NSAttributedString? {
        guard let text = MarkdownImporter.readText(page.file) else { return nil }
        let table = NotionCSV.read(text, limit: maxTableRows)
        guard !table.header.isEmpty else { return nil }
        if table.truncated { report.truncatedTables.append(page.title) }
        let columns = table.header.count
        let flat = { (cell: String) in cell.components(separatedBy: .newlines).joined(separator: " ") }
        let rows = table.rows.map { row in (0..<columns).map { $0 < row.count ? flat(row[$0]) : "" } }
        let body = NSMutableAttributedString(attributedString: EditorStyle.paragraph(page.title, kind: .title))
        body.append(EditorStyle.table(header: table.header.map(flat), rows: rows))
        return body
    }

    /// `<aside>` callouts become quotes, links to a database's `.csv` point at its note, and images on the web
    /// become links to them.
    nonisolated static func prepared(_ markdown: String) -> String {
        var out: [String] = []
        var inAside = false
        for line in markdown.components(separatedBy: "\n") {
            var rest = Substring(line)
            if !inAside, rest.trimmingCharacters(in: .whitespaces).hasPrefix("<aside>"),
               let open = rest.range(of: "<aside>") {
                inAside = true
                rest = rest[open.upperBound...]
                if rest.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            }
            guard inAside else {
                out.append(line)
                continue
            }
            if let close = rest.range(of: "</aside>") {
                inAside = false
                let content = rest[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { out.append("> " + content) }
                let after = rest[close.upperBound...].trimmingCharacters(in: .whitespaces)
                if !after.isEmpty { out.append(""); out.append(after) }
                continue
            }
            let content = rest.trimmingCharacters(in: .whitespaces)
            out.append(content.isEmpty ? ">" : "> " + content)
        }
        let text = out.joined(separator: "\n")
        let ns = text as NSString
        let linked = csvLink.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "]($1.md)")
        return remoteImagesAsLinks(linked)
    }

    nonisolated private static let remoteImage = try! NSRegularExpression(
        pattern: #"!\[((?:[^\[\]\\]|\\.)*)\]\(\s*(?:<(https?://[^<>\n]+)>|(https?://[^\s()]+))(?:\s+"[^"\n]*")?\s*\)"#,
        options: [.caseInsensitive])

    /// `![alt](https://…)` → `[alt](https://…)`, named by the address when it has no alt text.
    /// Code blocks (``` and ~~~ fences) and code spans are left as written.
    nonisolated static func remoteImagesAsLinks(_ text: String) -> String {
        var out: [String] = []
        var fence: (char: Character, count: Int)?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let run = trimmed.prefix { $0 == "`" || $0 == "~" }
            let marker = run.first.map { c in (char: c, count: run.prefix { $0 == c }.count) }
            if let open = fence {
                if let marker, marker.char == open.char, marker.count >= open.count,
                   trimmed.dropFirst(marker.count).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                out.append(line)
            } else if let marker, marker.count >= 3, !(marker.char == "`" && trimmed.dropFirst(marker.count).contains("`")) {
                fence = marker
                out.append(line)
            } else {
                out.append(imagesOutsideCodeSpans(line))
            }
        }
        return out.joined(separator: "\n")
    }

    /// Rewrites the parts of `line` outside backtick code spans.
    nonisolated private static func imagesOutsideCodeSpans(_ line: String) -> String {
        guard line.contains("`") else { return imagesAsLinks(line) }
        let chars = Array(line)
        var out = ""
        var plain = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "`" else {
                plain.append(chars[i])
                i += 1
                continue
            }
            var n = 0
            while i + n < chars.count, chars[i + n] == "`" { n += 1 }
            var j = i + n
            var close: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    var m = 0
                    while j + m < chars.count, chars[j + m] == "`" { m += 1 }
                    if m == n { close = j; break }
                    j += m
                } else {
                    j += 1
                }
            }
            guard let close else {
                plain += String(chars[i..<(i + n)])
                i += n
                continue
            }
            out += imagesAsLinks(plain) + String(chars[i..<(close + n)])
            plain = ""
            i = close + n
        }
        return out + imagesAsLinks(plain)
    }

    nonisolated private static func imagesAsLinks(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in remoteImage.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let angled = match.range(at: 2).location != NSNotFound
            let url = ns.substring(with: match.range(at: angled ? 2 : 3))
            var label = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if label.isEmpty {
                label = url.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += "[\(label)](\(url.replacingOccurrences(of: " ", with: "%20")))"
            last = NSMaxRange(match.range)
        }
        return out + ns.substring(from: last)
    }

    nonisolated private static let csvLink = try! NSRegularExpression(pattern: "\\]\\(([^()\\s]*?)(?:_all)?\\.csv\\)", options: [.caseInsensitive])

    /// The page key a link target written in a page in `folder` points at.
    nonisolated static func resolvedKey(_ target: String, from folder: [String]) -> String {
        var parts = folder
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }

    /// The bytes of a file inside the export, or nil for anything outside it, missing or over `AttachmentLimit`.
    nonisolated static func readExportFile(_ url: URL, roots: [URL]) -> Data? {
        guard url.isFileURL else { return nil }
        let file = url.standardizedFileURL
        var candidates = [file]
        // A page's own files may sit in another part of a split export.
        for root in roots where MarkdownImporter.isInside(file, root: root) {
            let relative = file.resolvingSymlinksInPath().pathComponents.dropFirst(root.resolvingSymlinksInPath().pathComponents.count)
            for other in roots where other != root {
                candidates.append(relative.reduce(other) { $0.appendingPathComponent($1) })
            }
        }
        for candidate in candidates where roots.contains(where: { MarkdownImporter.isInside(candidate, root: $0) }) {
            let values = try? candidate.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            guard AttachmentLimit.allows(byteCount: size) else { return nil }
            return try? Data(contentsOf: candidate)
        }
        return nil
    }

    /// Title links left from page links that point outside the export show the page's title, not its file name.
    private static func retitleUnresolvedLinks(_ body: NSMutableAttributedString) {
        var changes: [(NSRange, URL)] = []
        body.enumerateAttribute(.link, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            guard let url = value as? URL, case let .unresolved(title, heading)? = NoteLink(url: url) else { return }
            let clean = NotionNames.title(ofStem: (title as NSString).lastPathComponent)
            guard clean != title else { return }
            changes.append((range, NoteLink.unresolved(title: clean, heading: heading).clamped.url))
        }
        for (range, url) in changes { body.addAttribute(.link, value: url, range: range) }
    }
}

/// CSV as Notion writes it (RFC 4180: quoted fields, doubled quotes, line breaks inside quotes).
enum NotionCSV {
    /// The header and up to `limit` rows; `truncated` when more rows follow. Blank lines are skipped.
    static func read(_ text: String, limit: Int) -> (header: [String], rows: [[String]], truncated: Bool) {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var quoted = false
        var afterQuote = false
        var truncated = false
        let scalars = Array((text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).unicodeScalars)
        var i = 0
        func endRecord() -> Bool {
            record.append(field)
            field = ""
            if !(record.count == 1 && record[0].isEmpty) {
                if records.count == limit + 1 {
                    truncated = true
                    return false
                }
                records.append(record)
            }
            record = []
            return true
        }
        scan: while i < scalars.count {
            let c = scalars[i]
            i += 1
            if quoted {
                if c == "\"" {
                    if i < scalars.count, scalars[i] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 1
                    } else {
                        quoted = false
                        afterQuote = true
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty && !afterQuote:
                quoted = true
            case ",":
                record.append(field)
                field = ""
                afterQuote = false
            case "\r", "\n":
                if c == "\r", i < scalars.count, scalars[i] == "\n" { i += 1 }
                afterQuote = false
                if !endRecord() { break scan }
            default:
                field.unicodeScalars.append(c)
            }
        }
        if !truncated, !field.isEmpty || !record.isEmpty { _ = endRecord() }
        guard let header = records.first else { return ([], [], false) }
        return (header.map { $0.trimmingCharacters(in: .whitespaces) }, Array(records.dropFirst()), truncated)
    }
}
