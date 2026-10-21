import AppKit
import CryptoKit
import NoteItCore
import NoteItDoc
import UniformTypeIdentifiers

struct EvernoteResource: Equatable {
    var data: Data
    var mime: String
    var fileName: String?
}

/// One `<note>` of an `.enex` file.
struct EvernoteNote: Equatable {
    var title = ""
    var created: Date?
    var updated: Date?
    var tags: [String] = []
    /// ENML.
    var content = ""
    var resources: [EvernoteResource] = []
    /// Resources over `AttachmentLimit`, left out.
    var resourcesTooLarge = 0
    var reminder: Date?
    var reminderDone = false
}

/// Imports Evernote `.enex` exports. Each file becomes a notebook named after it; a folder of exports keeps its
/// subfolders (Evernote stacks) as parent notebooks.
@MainActor
enum EvernoteImporter {
    nonisolated static let fileExtension = "enex"
    nonisolated static let flushBytes = 8 << 20

    struct Item: Equatable {
        var url: URL
        var notebook: [String]
    }

    /// The `.enex` files among the chosen files and folders, with the notebook path each one goes into.
    nonisolated static func items(for urls: [URL]) -> [Item] {
        var result: [Item] = []
        for url in urls.map(\.standardizedFileURL) {
            if isDirectory(url) {
                walk(url, path: [], into: &result)
            } else if url.pathExtension.lowercased() == fileExtension {
                result.append(Item(url: url, notebook: [url.deletingPathExtension().lastPathComponent]))
            }
        }
        return result
    }

    nonisolated private static func walk(_ folder: URL, path: [String], into result: inout [Item]) {
        let contents = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in contents where !isDirectory(url) && url.pathExtension.lowercased() == fileExtension {
            result.append(Item(url: url, notebook: path + [url.deletingPathExtension().lastPathComponent]))
        }
        for url in contents where isDirectory(url) {
            walk(url, path: path + [url.lastPathComponent], into: &result)
        }
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // MARK: Importing

    static func importFiles(_ urls: [URL], into store: NoteStore,
                            progress: (ImportProgress) -> Void = { _ in }) async -> ImportReport {
        await importItems(items(for: urls), into: store, progress: progress)
    }

    /// Reads one note at a time off the main thread, so a file of any size stays out of memory. Links to other
    /// Evernote notes become title links and point at the imported note with that title at the end, so a cancel
    /// leaves no link to a note that wasn't created.
    static func importItems(_ items: [Item], into store: NoteStore,
                            progress: (ImportProgress) -> Void = { _ in }) async -> ImportReport {
        var report = ImportReport()
        let total = await Task.detached { items.reduce(0) { $0 + ENEXReader.countNotes(in: $1.url) } }.value
        progress(ImportProgress(completed: 0, total: total))
        var created: [UUID] = []
        var titles: [String: UUID] = [:]
        var done = 0
        var unsavedBytes = 0
        files: for item in items {
            if Task.isCancelled { report.cancelled = true; break }
            guard let reader = ENEXReader(url: item.url) else {
                report.filesSkipped += 1
                continue
            }
            var notesInFile = 0
            while true {
                if Task.isCancelled { report.cancelled = true; break files }
                let next = await Task.detached { () -> ENEXReader.Parsed? in autoreleasepool { reader.nextParsed() } }.value
                guard let next else { break }
                notesInFile += 1
                done += 1
                guard case .note(let note) = next else {
                    report.notesSkipped += 1
                    continue
                }
                let title = note.title.isEmpty ? "Untitled" : note.title
                progress(ImportProgress(completed: done - 1, total: max(total, done), currentName: title))
                if Task.isCancelled { report.cancelled = true; break files }
                let notebook = store.notebookForImport(path: item.notebook)
                let meta = autoreleasepool {
                    store.createImportedNote(body: Self.body(for: note, title: title, report: &report), title: title,
                                             notebookID: notebook.id, createdAt: note.created, updatedAt: note.updated)
                }
                created.append(meta.id)
                let key = TextFold.fold(title.trimmingCharacters(in: .whitespacesAndNewlines))
                if titles[key] == nil { titles[key] = meta.id }
                report.notesImported += 1
                report.notebookIDs.insert(notebook.id)
                // Unsaved bodies stay in memory, so a large export is written out as it goes.
                unsavedBytes += note.content.utf8.count + note.resources.reduce(0) { $0 + $1.data.count }
                if unsavedBytes > Self.flushBytes {
                    autoreleasepool { store.flush() }
                    unsavedBytes = 0
                }
                await Task.yield()
            }
            if notesInFile == 0, !reader.isExport { report.filesSkipped += 1 }
        }
        progress(ImportProgress(completed: done, total: max(total, done)))
        store.resolveTitleLinks(in: created, titles: titles)
        store.flush()
        return report
    }

    // MARK: Note bodies

    static func body(for note: EvernoteNote, title: String, report: inout ImportReport) -> NSAttributedString {
        var resources: [String: EvernoteResource] = [:]
        var order: [String] = []
        for resource in note.resources {
            let hash = md5(resource.data)
            if resources[hash] == nil { order.append(hash) }
            resources[hash] = resource
        }
        report.attachmentsSkipped += note.resourcesTooLarge
        if ENMLConverter.hasEncryptedSections(note.content) { report.encryptedSectionsSkipped += 1 }

        let html = ENMLConverter.html(fromENML: note.content, resources: resources)
        let body = NSMutableAttributedString(attributedString: AppleNotesImporter.convert(html: html, title: title).body)
        var used = Set<String>()
        insertResources(into: body, resources: resources, used: &used)
        let unused = order.filter { !used.contains($0) }
        if !unused.isEmpty { ensureTrailingNewline(body) }
        for (n, hash) in unused.enumerated() {
            guard let resource = resources[hash] else { continue }
            let line = NSMutableAttributedString(attributedString: attachment(resource, index: used.count + n + 1,
                                                                             attributes: EditorStyle.bodyAttributes))
            line.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
            body.append(line)
        }
        applyChecklists(body)
        convertEvernoteLinks(body)
        for marker in ENMLConverter.markers {
            body.mutableString.replaceOccurrences(of: marker, with: "", options: [], range: NSRange(location: 0, length: body.length))
        }

        var footer: [String] = []
        if let tags = ImportTags.line(for: note.tags, excluding: body) { footer.append(tags) }
        if let reminder = note.reminder { footer.append(reminderToken(reminder, done: note.reminderDone)) }
        if !footer.isEmpty {
            ensureTrailingNewline(body)
            body.append(EditorStyle.paragraph(footer.joined(separator: " "), kind: .body))
        }
        let ts = NSTextStorage(attributedString: body)
        if ts.length > 0 { NoteItTextView.normalize(ts, around: NSRange(location: 0, length: ts.length)) }
        return NSAttributedString(attributedString: ts)
    }

    nonisolated static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func ensureTrailingNewline(_ body: NSMutableAttributedString) {
        if body.length > 0, !body.string.hasSuffix("\n") {
            body.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
        }
    }

    private static let mediaToken = try! NSRegularExpression(
        pattern: "\(ENMLConverter.mediaStart)([0-9a-f]{32})\(ENMLConverter.mediaEnd)")

    /// Replaces each resource placeholder with the resource as an attachment.
    private static func insertResources(into body: NSMutableAttributedString, resources: [String: EvernoteResource],
                                        used: inout Set<String>) {
        let matches = mediaToken.matches(in: body.string, range: NSRange(location: 0, length: body.length))
        var index = matches.count
        for match in matches.reversed() {
            let hash = (body.string as NSString).substring(with: match.range(at: 1))
            var attrs = body.attributes(at: match.range.location, effectiveRange: nil)
            attrs[.link] = nil
            attrs[.backgroundColor] = nil
            if let resource = resources[hash] {
                body.replaceCharacters(in: match.range, with: attachment(resource, index: index, attributes: attrs))
                used.insert(hash)
            } else {
                body.replaceCharacters(in: match.range, with: "")
            }
            index -= 1
        }
    }

    private static func attachment(_ resource: EvernoteResource, index: Int,
                                   attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let wrapper = FileWrapper(regularFileWithContents: resource.data)
        wrapper.preferredFilename = fileName(for: resource, index: index)
        let piece = NSMutableAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
        return piece
    }

    /// The resource's own file name, given the extension its MIME type calls for when it has none.
    nonisolated static func fileName(for resource: EvernoteResource, index: Int) -> String {
        let type = UTType(mimeType: resource.mime.lowercased())
        let ext = type?.preferredFilenameExtension
        let own = resource.fileName.map {
            $0.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let own, !own.isEmpty, !own.hasPrefix(".") {
            if (own as NSString).pathExtension.isEmpty, let ext { return own + "." + ext }
            return own
        }
        let stem = type?.conforms(to: .image) == true ? "image" : "attachment"
        return ext.map { "\(stem)-\(index).\($0)" } ?? "\(stem)-\(index)"
    }

    /// Paragraphs starting with a to-do marker, after any list marker, become checklist items at the same level.
    private static func applyChecklists(_ body: NSMutableAttributedString) {
        var paragraphs: [NSRange] = []
        let ns = body.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) {
            _, _, enclosing, _ in paragraphs.append(enclosing)
        }
        for para in paragraphs.reversed() {
            let text = (body.string as NSString).substring(with: para) as NSString
            let marker = EditorStyle.listMarker(in: text as String)
            var offset = marker?.length ?? 0
            while offset < text.length, text.character(at: offset) == 32 || text.character(at: offset) == 9 { offset += 1 }
            guard offset < text.length else { continue }
            let first = text.substring(with: NSRange(location: offset, length: 1))
            guard first == ENMLConverter.uncheckedTodo || first == ENMLConverter.checkedTodo else { continue }
            var start = offset + 1
            while start < text.length, text.character(at: start) == 32 { start += 1 }
            let ps = body.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            let level = marker == nil ? 0 : EditorStyle.listLevel(of: ps)
            let content = NSMutableAttributedString(attributedString: body.attributedSubstring(
                from: NSRange(location: para.location + start, length: para.length - start)))
            if !content.string.hasSuffix("\n") {
                content.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
            }
            if first == ENMLConverter.checkedTodo { NoteItTextView.applyCheckedStyle(content) }
            let item = NSMutableAttributedString(string: EditorStyle.markerText(.checkbox(checked: first == ENMLConverter.checkedTodo), level: level),
                                                 attributes: EditorStyle.markerAttributes(level: level))
            item.append(content)
            item.addAttribute(.paragraphStyle, value: EditorStyle.listParagraphStyle(level: level),
                              range: NSRange(location: 0, length: item.length))
            body.replaceCharacters(in: para, with: item)
        }
    }

    /// Links to Evernote notes become title links named by the link's text.
    private static func convertEvernoteLinks(_ body: NSMutableAttributedString) {
        var changes: [(NSRange, URL?)] = []
        body.enumerateAttribute(.link, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url, isEvernoteNoteLink(url) else { return }
            let text = (body.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            changes.append((range, text.isEmpty ? nil : NoteLink.unresolved(title: text, heading: nil).clamped.url))
        }
        for (range, url) in changes {
            if let url { body.addAttribute(.link, value: url, range: range) } else { body.removeAttribute(.link, range: range) }
        }
    }

    /// `evernote:///view/…` and `https://www.evernote.com/shard/…/nl/…` note links.
    nonisolated static func isEvernoteNoteLink(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "evernote" { return true }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased(),
              host == "evernote.com" || host.hasSuffix(".evernote.com") else { return false }
        let parts = url.path.split(separator: "/")
        return parts.first == "shard" && parts.contains("nl")
    }

    nonisolated static func reminderToken(_ date: Date, done: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "@remind(\(formatter.string(from: date))\(done ? " done" : ""))"
    }
}

// MARK: - ENML

/// ENML (Evernote's XHTML subset) → HTML for `AppleNotesImporter.convert(html:title:)`. Rewritten with patterns
/// rather than parsed, so ENML that isn't well-formed still comes through. `en-todo` becomes a marker character,
/// `en-media` a placeholder for its resource (matched by MD5), and `en-crypt` is dropped.
enum ENMLConverter {
    static let uncheckedTodo = "\u{E010}"
    static let checkedTodo = "\u{E011}"
    static let mediaStart = "\u{E012}"
    static let mediaEnd = "\u{E013}"
    static let markers = [uncheckedTodo, checkedTodo, mediaStart, mediaEnd]

    private static let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
    private static let prolog = try! NSRegularExpression(pattern: "<\\?xml[^>]*\\?>|<!DOCTYPE[^>]*>", options: options)
    private static let crypt = try! NSRegularExpression(
        pattern: "<en-crypt\\b[^>]*/>|<en-crypt\\b[^>]*>.*?(?:</en-crypt\\s*>|$)", options: options)
    private static let todo = try! NSRegularExpression(pattern: "<en-todo\\b([^>]*?)/?>", options: options)
    private static let media = try! NSRegularExpression(pattern: "<en-media\\b([^>]*?)/?>", options: options)
    private static let closing = try! NSRegularExpression(pattern: "</en-(?:todo|media)\\s*>", options: options)
    private static let noteOpen = try! NSRegularExpression(pattern: "<en-note\\b", options: options)
    private static let noteClose = try! NSRegularExpression(pattern: "</en-note\\s*>", options: options)
    private static let checked = try! NSRegularExpression(pattern: "\\bchecked\\s*=\\s*[\"']?true", options: options)
    private static let hash = try! NSRegularExpression(pattern: "\\bhash\\s*=\\s*[\"']?([0-9a-f]{32})", options: options)

    static func hasEncryptedSections(_ enml: String) -> Bool {
        enml.range(of: "<en-crypt", options: .caseInsensitive) != nil
    }

    /// `resources` maps the lowercase MD5 hex of each resource's data to the resource.
    static func html(fromENML enml: String, resources: [String: EvernoteResource]) -> String {
        var text = enml
        for marker in markers { text = text.replacingOccurrences(of: marker, with: "") }
        text = replace(prolog, in: text) { _ in "" }
        text = replace(crypt, in: text) { _ in "" }
        text = replace(todo, in: text) { attrs in
            first(checked, in: attrs) != nil ? checkedTodo : uncheckedTodo
        }
        text = replace(media, in: text) { attrs in
            guard let hash = first(hash, in: attrs)?.lowercased(), resources[hash] != nil else { return "" }
            return mediaStart + hash + mediaEnd
        }
        text = replace(closing, in: text) { _ in "" }
        text = replace(noteOpen, in: text) { _ in "<div" }
        text = replace(noteClose, in: text) { _ in "</div>" }
        return text
    }

    /// Replaces every match of `regex`; `with` gets the first capture group (or "").
    private static func replace(_ regex: NSRegularExpression, in text: String, with: (String) -> String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                ? ns.substring(with: match.range(at: 1)) : ""
            result += with(group)
            last = NSMaxRange(match.range)
        }
        guard last > 0 else { return text }
        return result + ns.substring(from: last)
    }

    private static func first(_ regex: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ""
    }
}

// MARK: - Streaming

/// Reads an `.enex` file one `<note>…</note>` at a time, so memory stays at about one note however large the file
/// is. Each note is parsed on its own: XML that is broken inside one note skips only that note.
final class ENEXReader: @unchecked Sendable {
    enum Parsed: Equatable {
        case note(EvernoteNote)
        case unreadable
    }

    static let blockSize = 1 << 20
    /// A note larger than this is skipped without being held in memory.
    static let maxNoteBytes = 256 << 20
    private static let openTag = Array("<note>".utf8)
    private static let closeTag = Array("</note>".utf8)
    private static let exportTag = Array("<en-export".utf8)

    private let handle: FileHandle
    private var buffer = Data()
    private var head = 0
    private var atEnd = false
    private var readBytes = 0
    /// True once the file is seen to start an `<en-export>`.
    private(set) var isExport = false

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    /// The next note, parsed; nil at the end of the file.
    func nextParsed() -> Parsed? {
        guard let chunk = nextChunk() else { return nil }
        guard let data = chunk, let note = ENEXNoteParser.parse(data) else { return .unreadable }
        return .note(note)
    }

    /// The next `<note>…</note>` bytes; `.some(nil)` for a note that is too large or cut off.
    func nextChunk() -> Data?? {
        while true {
            if let start = Self.find(Self.openTag, in: buffer, from: head) {
                head = start
                break
            }
            head = max(head, buffer.count - (Self.openTag.count - 1))
            compact(force: true)
            if !fill() { return nil }
        }
        var scan = head + Self.openTag.count
        var oversized = false
        while true {
            if let end = Self.find(Self.closeTag, in: buffer, from: scan) {
                let stop = end + Self.closeTag.count
                let chunk = oversized ? nil : buffer.subdata(in: head..<stop)
                head = stop
                compact(force: false)
                return .some(chunk)
            }
            scan = max(head, buffer.count - (Self.closeTag.count - 1))
            if buffer.count - head > Self.maxNoteBytes {
                oversized = true
                head = scan
                compact(force: true)
                scan = head
            }
            if !fill() {
                buffer = Data()
                head = 0
                return .some(nil)
            }
        }
    }

    private func fill() -> Bool {
        guard !atEnd, let block = try? handle.read(upToCount: Self.blockSize), !block.isEmpty else {
            atEnd = true
            return false
        }
        if readBytes < 64 * 1024, !isExport {
            isExport = Self.find(Self.exportTag, in: buffer + block, from: 0) != nil
        }
        readBytes += block.count
        buffer.append(block)
        return true
    }

    private func compact(force: Bool) {
        guard head > 0, force || head > Self.blockSize else { return }
        buffer = head >= buffer.count ? Data() : Data(buffer[head...])
        head = 0
    }

    /// The number of notes in the file, counted from their end tags.
    static func countNotes(in url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var carry = Data()
        var count = 0
        // FileHandle hands back autoreleased blocks; without a pool per block the whole file would stay in memory.
        while autoreleasepool(invoking: { () -> Bool in
            guard let block = try? handle.read(upToCount: blockSize), !block.isEmpty else { return false }
            var data = carry
            data.append(block)
            var from = 0
            while let index = find(closeTag, in: data, from: from) {
                count += 1
                from = index + closeTag.count
            }
            carry = Data(data.suffix(min(closeTag.count - 1, data.count - from)))
            return true
        }) {}
        return count
    }

    static func find(_ needle: [UInt8], in data: Data, from: Int) -> Int? {
        guard from >= 0, data.count - from >= needle.count else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress else { return nil }
            return needle.withUnsafeBytes { pattern -> Int? in
                guard let found = memmem(base + from, raw.count - from, pattern.baseAddress, pattern.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(found))
            }
        }
    }
}

/// Parses one `<note>` element.
final class ENEXNoteParser: NSObject, XMLParserDelegate {
    private var note = EvernoteNote()
    private var path: [String] = []
    private var text = ""
    private var base64 = Data()
    private var base64TooLarge = false
    private var resource: EvernoteResource?
    private var resourceTooLarge = false
    /// Base64 is a third larger than its data, plus line breaks.
    private static let maxBase64Bytes = AttachmentLimit.maxBytes / 3 * 4 + AttachmentLimit.maxBytes / 8

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    static func parse(_ data: Data) -> EvernoteNote? {
        let delegate = ENEXNoteParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() && delegate.path.isEmpty ? delegate.note : nil
    }

    static func date(_ text: String) -> Date? {
        dateFormatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var parent: String? { path.count >= 2 ? path[path.count - 2] : nil }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
        if name == "resource", parent == "note" {
            resource = EvernoteResource(data: Data(), mime: "")
            resourceTooLarge = false
        } else if name == "data", parent == "resource" {
            base64 = Data()
            base64TooLarge = false
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if path.last == "data", parent == "resource" {
            guard !base64TooLarge else { return }
            base64.append(contentsOf: string.utf8)
            if base64.count > Self.maxBase64Bytes {
                base64TooLarge = true
                base64 = Data()
            }
        } else {
            text += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(decoding: block, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (name, parent) {
        case ("title", "note"): note.title = value
        case ("created", "note"): note.created = Self.date(value)
        case ("updated", "note"): note.updated = Self.date(value)
        case ("tag", "note"): if !value.isEmpty { note.tags.append(value) }
        case ("content", "note"): note.content = text
        case ("reminder-time", "note-attributes"): note.reminder = Self.date(value)
        case ("reminder-done-time", "note-attributes"): note.reminderDone = Self.date(value) != nil
        case ("data", "resource"):
            if base64TooLarge {
                resourceTooLarge = true
            } else if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                if AttachmentLimit.allows(byteCount: data.count) { resource?.data = data } else { resourceTooLarge = true }
            }
            base64 = Data()
        case ("mime", "resource"): resource?.mime = value
        case ("file-name", "resource-attributes"): if !value.isEmpty { resource?.fileName = value }
        case ("resource", "note"):
            if resourceTooLarge {
                note.resourcesTooLarge += 1
            } else if let resource, !resource.data.isEmpty {
                note.resources.append(resource)
            }
            resource = nil
        default: break
        }
        path.removeLast()
        text = ""
    }
}
