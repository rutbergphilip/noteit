import AppKit
import CoreServices

struct AppleNotesFolder: Equatable {
    var id: String
    var name: String
    /// The parent folder's id, or empty for a top-level folder in an account.
    var parentID: String
}

struct AppleNotesNote {
    var name: String
    var html: String
    var created: Date?
    var modified: Date?
    var attachmentCount: Int
}

struct AppleNotesEntry: Equatable {
    var id: String
    var locked: Bool
}

/// Runs AppleScript against the Notes app; replaced in tests. Called on `AppleScriptThread`, one script at a time.
protocol AppleNotesScripting: Sendable {
    func run(_ source: String) throws -> NSAppleEventDescriptor
}

struct AppleScriptError: Error {
    var code: Int
    var message: String
}

struct SystemAppleNotesScripting: AppleNotesScripting {
    func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError(code: 0, message: "The script couldn't be created.")
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (info[NSAppleScript.errorMessage] as? String) ?? "Unknown error."
            throw AppleScriptError(code: code, message: message)
        }
        return result
    }
}

/// Runs every AppleScript on one background thread, because NSAppleScript isn't thread-safe
/// and blocks while Notes answers.
final class AppleScriptThread: @unchecked Sendable {
    static let shared = AppleScriptThread()

    private let condition = NSCondition()
    private var jobs: [() -> Void] = []

    private init() {
        let thread = Thread { [self] in loop() }
        thread.name = "NoteIt AppleScript"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue { continuation.resume(with: Result { try work() }) }
        }
    }

    private func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job() }
        }
    }
}

/// Reads folders and notes from the Notes app through Apple Events.
@MainActor
final class AppleNotesImporter {
    nonisolated static let notesBundleID = "com.apple.Notes"
    nonisolated static let notPermitted = -1743

    private let store: NoteStore
    private let scripting: AppleNotesScripting

    init(store: NoteStore, scripting: AppleNotesScripting = SystemAppleNotesScripting()) {
        self.store = store
        self.scripting = scripting
    }

    // MARK: Permission

    /// Launches Notes if needed and asks macOS for permission to control it (prompting once).
    static func requestPermission() async throws {
        if NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notesBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        }
        let status: OSStatus = await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(bundleIdentifier: notesBundleID)
            var status: OSStatus = OSStatus(procNotFound)
            for attempt in 0..<20 {
                status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
                guard status == OSStatus(procNotFound), attempt < 19 else { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return status
        }.value
        switch Int(status) {
        case Int(noErr):
            return
        case notPermitted, Int(errAEEventWouldRequireUserConsent):
            throw ImportError.notesPermissionDenied
        case Int(procNotFound):
            throw ImportError.notesUnavailable("Make sure the Notes app is installed and can open.")
        default:
            // Anything else is left to the scripts themselves, which report their own errors.
            return
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Import

    /// Lists and reads notes on `AppleScriptThread`, converting and saving them here on the main actor.
    /// A note that can't be read is skipped; losing permission stops the run but keeps what was imported.
    func run(progress: (ImportProgress) -> Void) async throws -> ImportReport {
        var report = ImportReport()
        let scripting = scripting
        let folders: [AppleNotesFolder]
        do {
            folders = try await AppleScriptThread.shared.run { Self.folders(from: try scripting.run(Self.foldersScript)) }
        } catch {
            throw Self.importError(error)
        }
        let paths = Self.folderPaths(folders)
        let wanted = folders.filter { !Self.isRecentlyDeleted($0) }

        var plan: [(folder: String, entry: AppleNotesEntry)] = []
        var seen = Set<String>()
        for folder in wanted {
            if Task.isCancelled { report.cancelled = true; return finish(report) }
            let path = paths[folder.id] ?? folder.name
            progress(ImportProgress(currentName: path))
            let entries: [AppleNotesEntry]
            do {
                entries = try await AppleScriptThread.shared.run {
                    Self.entries(from: try scripting.run(Self.noteListScript(folderID: folder.id)))
                }
            } catch let error where Self.isPermissionError(error) {
                return try finishDenied(report)
            } catch {
                continue
            }
            for entry in entries where !entry.id.isEmpty && seen.insert(entry.id).inserted {
                plan.append((path, entry))
            }
        }

        progress(ImportProgress(completed: 0, total: plan.count))
        for (index, item) in plan.enumerated() {
            if Task.isCancelled { report.cancelled = true; break }
            defer { progress(ImportProgress(completed: index + 1, total: plan.count)) }
            if item.entry.locked {
                report.lockedSkipped += 1
                continue
            }
            let id = item.entry.id
            let fetched: AppleNotesNote?
            do {
                fetched = try await AppleScriptThread.shared.run { Self.note(from: Self.list(from: try scripting.run(Self.noteScript(noteID: id)))) }
            } catch let error where Self.isPermissionError(error) {
                return try finishDenied(report)
            } catch {
                fetched = nil
            }
            if Task.isCancelled { report.cancelled = true; break }
            guard let note = fetched else {
                report.notesSkipped += 1
                continue
            }
            progress(ImportProgress(completed: index, total: plan.count, currentName: note.name))
            let converted = Self.convert(html: note.html, title: note.name)
            report.attachmentsSkipped += max(0, note.attachmentCount - converted.images)
            let notebook = store.notebookForImport(named: item.folder)
            store.createImportedNote(body: converted.body, title: note.name, notebookID: notebook.id,
                                     createdAt: note.created, updatedAt: note.modified)
            report.notesImported += 1
            report.notebookIDs.insert(notebook.id)
        }
        return finish(report)
    }

    private func finish(_ report: ImportReport) -> ImportReport {
        store.flush()
        return report
    }

    /// Ends a run that lost permission: with the summary if anything was done, else with the permission error.
    private func finishDenied(_ report: ImportReport) throws -> ImportReport {
        var report = finish(report)
        guard report.notesImported > 0 || report.lockedSkipped > 0 || report.notesSkipped > 0 else {
            throw ImportError.notesPermissionDenied
        }
        report.permissionDenied = true
        return report
    }

    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        guard let error = error as? AppleScriptError else { return false }
        return error.code == notPermitted || error.code == Int(errAEEventWouldRequireUserConsent)
    }

    nonisolated private static func importError(_ error: Error) -> Error {
        if isPermissionError(error) { return ImportError.notesPermissionDenied }
        if let error = error as? AppleScriptError { return ImportError.notesUnavailable(error.message) }
        return error
    }

    // MARK: Scripts

    nonisolated static let foldersScript = """
    on walk(f, parentID)
        tell application "Notes"
            set fid to id of f
            set out to {{fid, name of f, parentID}}
            repeat with c in (folders of f)
                set out to out & my walk(c, fid)
            end repeat
        end tell
        return out
    end walk

    with timeout of 600 seconds
        tell application "Notes"
            set out to {}
            repeat with a in accounts
                repeat with f in (folders of a)
                    set out to out & my walk(f, "")
                end repeat
            end repeat
        end tell
    end timeout
    return out
    """

    /// Two Apple Events per folder, whatever its size: every id, then every locked flag.
    nonisolated static func noteListScript(folderID: String) -> String {
        """
        with timeout of 600 seconds
            tell application "Notes"
                set f to folder id "\(escape(folderID))"
                return {id of every note of f, password protected of every note of f}
            end tell
        end timeout
        """
    }

    nonisolated static func noteScript(noteID: String) -> String {
        """
        with timeout of 600 seconds
            tell application "Notes"
                set n to note id "\(escape(noteID))"
                return {name of n, body of n, creation date of n, modification date of n, count of attachments of n}
            end tell
        end timeout
        """
    }

    nonisolated static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Descriptors

    nonisolated private static func list(from descriptor: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
    }

    nonisolated private static func rows(from descriptor: NSAppleEventDescriptor) -> [[NSAppleEventDescriptor]] {
        list(from: descriptor).map(list(from:))
    }

    nonisolated private static func folders(from descriptor: NSAppleEventDescriptor) -> [AppleNotesFolder] {
        var byID: [String: AppleNotesFolder] = [:]
        var order: [String] = []
        for row in rows(from: descriptor) where row.count >= 3 {
            let folder = AppleNotesFolder(id: row[0].stringValue ?? "", name: row[1].stringValue ?? "", parentID: row[2].stringValue ?? "")
            guard !folder.id.isEmpty else { continue }
            if let existing = byID[folder.id] {
                if existing.parentID.isEmpty, !folder.parentID.isEmpty { byID[folder.id] = folder }
            } else {
                byID[folder.id] = folder
                order.append(folder.id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Pairs the id and locked lists that `noteListScript` returns.
    nonisolated private static func entries(from descriptor: NSAppleEventDescriptor) -> [AppleNotesEntry] {
        let columns = list(from: descriptor)
        guard columns.count >= 2 else { return [] }
        let ids = list(from: columns[0])
        let locked = list(from: columns[1])
        return ids.indices.map { AppleNotesEntry(id: ids[$0].stringValue ?? "", locked: locked.indices.contains($0) && locked[$0].booleanValue) }
    }

    nonisolated private static func note(from row: [NSAppleEventDescriptor]) -> AppleNotesNote? {
        guard row.count >= 5 else { return nil }
        return AppleNotesNote(name: row[0].stringValue ?? "", html: row[1].stringValue ?? "",
                              created: row[2].dateValue, modified: row[3].dateValue,
                              attachmentCount: Int(row[4].int32Value))
    }

    static func isRecentlyDeleted(_ folder: AppleNotesFolder) -> Bool {
        folder.parentID.isEmpty && folder.name == "Recently Deleted"
    }

    /// Folder id → notebook name, with nested folders joined by " / " and accounts left out.
    nonisolated static func folderPaths(_ folders: [AppleNotesFolder]) -> [String: String] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [String: String] = [:]
        for folder in folders {
            var names = [folder.name]
            var parent = folder.parentID
            var visited: Set<String> = [folder.id]
            while let p = byID[parent], visited.insert(p.id).inserted {
                names.insert(p.name, at: 0)
                parent = p.parentID
            }
            result[folder.id] = names.joined(separator: " / ")
        }
        return result
    }

    // MARK: HTML → NoteIt

    struct Converted {
        var body: NSAttributedString
        /// Embedded images that became attachments.
        var images: Int
    }

    private static let imageTag = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
    private static let dataURL = try! NSRegularExpression(
        pattern: "src\\s*=\\s*[\"']data:image/([a-z0-9.+-]+);base64,([^\"']+)[\"']", options: [.caseInsensitive]
    )
    private static let imageToken = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")
    private static let listMarkerPrefix = try! NSRegularExpression(pattern: "^\\t[^\\t]*\\t")

    /// Converts a note body from Notes' HTML to NoteIt styles. Headings are found by font size,
    /// fonts and colors are dropped, and the note name becomes the title line.
    static func convert(html: String, title: String = "") -> Converted {
        var images: [(Data, String)] = []
        let prepared = extractImages(html, into: &images)
        let source = parseHTML(prepared)
        let body = NSMutableAttributedString()

        let baseSize = dominantFontSize(source)
        var paragraphs = splitParagraphs(source)
        while let last = paragraphs.last, last.text.string.trimmingCharacters(in: .whitespaces).isEmpty, last.table == nil {
            paragraphs.removeLast()
        }
        while let first = paragraphs.first, first.text.string.trimmingCharacters(in: .whitespaces).isEmpty, first.table == nil {
            paragraphs.removeFirst()
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstIsTitle = paragraphs.first.map {
            $0.table == nil && ($0.lists ?? []).isEmpty
                && (cleanTitle.isEmpty || $0.text.string.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(cleanTitle) == .orderedSame)
        } ?? false
        if !firstIsTitle, !cleanTitle.isEmpty { body.append(EditorStyle.paragraph(cleanTitle, kind: .title)) }

        var counters: [Int: Int] = [:]
        var index = 0
        while index < paragraphs.count {
            let para = paragraphs[index]
            if let table = para.table {
                var cells: [(row: Int, column: Int, text: String)] = []
                while index < paragraphs.count, let block = paragraphs[index].block, paragraphs[index].table === table {
                    cells.append((block.startingRow, block.startingColumn, paragraphs[index].text.string.trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                appendTable(cells, columns: table.numberOfColumns, to: body)
                counters = [:]
                continue
            }
            index += 1

            var text = para.text
            if let lists = para.lists, !lists.isEmpty {
                let level = lists.count - 1
                counters = counters.filter { $0.key <= level }
                text = stripListMarker(text)
                let kind: ListMarker.Kind
                if lists[level].markerFormat.rawValue.contains("decimal") {
                    let n = (counters[level] ?? 0) + 1
                    counters[level] = n
                    kind = .numbered(n)
                } else {
                    counters[level] = nil
                    kind = .bullet
                }
                let item = NSMutableAttributedString(string: EditorStyle.markerText(kind, level: level), attributes: EditorStyle.markerAttributes(level: level))
                item.append(restyle(text, kind: .body))
                item.append(NSAttributedString(string: "\n", attributes: [.font: EditorStyle.bodyFont]))
                item.addAttribute(.paragraphStyle, value: EditorStyle.listParagraphStyle(level: level), range: NSRange(location: 0, length: item.length))
                body.append(item)
                continue
            }
            counters = [:]

            let kind = index == 1 && firstIsTitle ? .title : blockKind(text, baseSize: baseSize)
            let line = restyle(text, kind: kind)
            line.append(NSAttributedString(string: "\n", attributes: [.font: EditorStyle.font(for: kind)]))
            line.addAttribute(.paragraphStyle, value: EditorStyle.paragraphStyle(for: kind), range: NSRange(location: 0, length: line.length))
            body.append(line)
        }

        let used = insertImages(images, into: body)
        let ts = NSTextStorage(attributedString: body)
        if ts.length > 0 { NoteItTextView.normalize(ts, around: NSRange(location: 0, length: ts.length)) }
        return Converted(body: NSAttributedString(attributedString: ts), images: used)
    }

    /// Embedded `data:` images become placeholder tokens; other images are removed.
    private static func extractImages(_ html: String, into images: inout [(Data, String)]) -> String {
        let ns = html as NSString
        var result = ""
        var last = 0
        for match in imageTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = NSMaxRange(match.range)
            let tag = ns.substring(with: match.range)
            let tagNS = tag as NSString
            guard let src = dataURL.firstMatch(in: tag, range: NSRange(location: 0, length: tagNS.length)) else { continue }
            let subtype = tagNS.substring(with: src.range(at: 1)).lowercased()
            let base64 = tagNS.substring(with: src.range(at: 2)).replacingOccurrences(of: "&#10;", with: "")
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { continue }
            let ext = ["jpeg": "jpg", "svg+xml": "svg"][subtype] ?? subtype
            images.append((data, ext))
            result += "\u{E000}\(images.count - 1)\u{E001}"
        }
        result += ns.substring(from: last)
        return result
    }

    private static func parseHTML(_ html: String) -> NSAttributedString {
        let document = html.range(of: "<html", options: .caseInsensitive) == nil
            ? "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(html)</body></html>"
            : html
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return (try? NSAttributedString(data: Data(document.utf8), options: options, documentAttributes: nil))
            ?? NSAttributedString(string: html)
    }

    private struct SourceParagraph {
        var text: NSAttributedString
        var lists: [NSTextList]?
        var table: NSTextTable?
        var block: NSTextTableBlock?
    }

    /// Paragraphs without their line endings; line separators (`<br>`) also start a new paragraph.
    private static func splitParagraphs(_ source: NSAttributedString) -> [SourceParagraph] {
        let ns = source.string as NSString
        var result: [SourceParagraph] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var content = range
            while content.length > 0, let scalar = UnicodeScalar(ns.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                content.length -= 1
            }
            let ps = source.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let block = ps?.textBlocks.compactMap { $0 as? NSTextTableBlock }.last
            let lists = ps?.textLists
            let text = source.attributedSubstring(from: content)
            if block != nil {
                result.append(SourceParagraph(text: text, lists: nil, table: block?.table, block: block))
                continue
            }
            for piece in split(text, on: "\u{2028}") {
                result.append(SourceParagraph(text: piece, lists: lists, table: nil, block: nil))
            }
        }
        return result
    }

    private static func split(_ text: NSAttributedString, on separator: String) -> [NSAttributedString] {
        let ns = text.string as NSString
        var pieces: [NSAttributedString] = []
        var start = 0
        while true {
            let r = ns.range(of: separator, range: NSRange(location: start, length: ns.length - start))
            guard r.location != NSNotFound else { break }
            pieces.append(text.attributedSubstring(from: NSRange(location: start, length: r.location - start)))
            start = NSMaxRange(r)
        }
        pieces.append(text.attributedSubstring(from: NSRange(location: start, length: ns.length - start)))
        return pieces
    }

    private static func stripListMarker(_ text: NSAttributedString) -> NSAttributedString {
        guard let m = listMarkerPrefix.firstMatch(in: text.string, range: NSRange(location: 0, length: (text.string as NSString).length)) else {
            return text
        }
        return text.attributedSubstring(from: NSRange(location: NSMaxRange(m.range), length: text.length - NSMaxRange(m.range)))
    }

    /// The font size covering the most characters, taken as the body size.
    private static func dominantFontSize(_ source: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        let ns = source.string as NSString
        source.enumerateAttribute(.font, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let visible = ns.substring(with: range).filter { !$0.isWhitespace }.count
            counts[font.pointSize.rounded(), default: 0] += visible
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 12
    }

    private static func isMonospaced(_ font: NSFont) -> Bool {
        font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }

    private static func blockKind(_ text: NSAttributedString, baseSize: CGFloat) -> BlockKind {
        var maxSize: CGFloat = 0
        var allBold = true
        var allMono = true
        var visible = 0
        let ns = text.string as NSString
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard ns.substring(with: range).contains(where: { !$0.isWhitespace && $0 != "\u{E000}" && $0 != "\u{E001}" }) else { return }
            visible += 1
            let font = value as? NSFont
            maxSize = max(maxSize, font?.pointSize ?? 0)
            if !(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false) { allBold = false }
            if !(font.map(isMonospaced) ?? false) { allMono = false }
        }
        guard visible > 0, baseSize > 0 else { return .body }
        let ratio = maxSize / baseSize
        if ratio >= 1.6 { return .title }
        if ratio >= 1.3 { return .heading }
        if ratio >= 1.1, allBold { return .subheading }
        if allMono { return .code }
        return .body
    }

    /// Keeps bold, italic, underline, strikethrough, links and inline code; everything else takes the
    /// block's own font and color.
    private static func restyle(_ text: NSAttributedString, kind: BlockKind) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let base = EditorStyle.font(for: kind)
        let fm = NSFontManager.shared
        let headingLike = kind == .title || kind == .heading || kind == .subheading
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let source = attrs[.font] as? NSFont
            let traits = source?.fontDescriptor.symbolicTraits ?? []
            var font = base
            if traits.contains(.bold), !headingLike { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italic) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
            var newAttrs: [NSAttributedString.Key: Any] = [.font: font]
            if kind != .code, let source, isMonospaced(source) {
                newAttrs.merge(EditorStyle.inlineCodeAttributes) { $1 }
            }
            if let underline = attrs[.underlineStyle] as? Int, underline != 0 { newAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { newAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = attrs[.link] {
                newAttrs[.link] = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            }
            out.append(NSAttributedString(string: (text.string as NSString).substring(with: range), attributes: newAttrs))
        }
        return out
    }

    private static func appendTable(_ cells: [(row: Int, column: Int, text: String)], columns: Int, to body: NSMutableAttributedString) {
        let rowCount = (cells.map(\.row).max() ?? -1) + 1
        let columnCount = max(columns, (cells.map(\.column).max() ?? -1) + 1)
        guard rowCount > 0, columnCount > 0 else { return }
        var grid = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
        for cell in cells { grid[cell.row][cell.column] = cell.text }
        body.append(EditorStyle.table(header: grid[0], rows: Array(grid.dropFirst())))
    }

    /// Replaces image tokens with attachments; returns how many were inserted.
    private static func insertImages(_ images: [(Data, String)], into body: NSMutableAttributedString) -> Int {
        var used = 0
        let matches = imageToken.matches(in: body.string, range: NSRange(location: 0, length: body.length))
        for match in matches.reversed() {
            let n = Int((body.string as NSString).substring(with: match.range(at: 1))) ?? -1
            var attrs = body.attributes(at: match.range.location, effectiveRange: nil)
            attrs[.link] = nil
            attrs[.backgroundColor] = nil
            guard images.indices.contains(n) else {
                body.replaceCharacters(in: match.range, with: "")
                continue
            }
            let wrapper = FileWrapper(regularFileWithContents: images[n].0)
            wrapper.preferredFilename = "image-\(n + 1).\(images[n].1)"
            let piece = NSMutableAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
            piece.addAttributes(attrs, range: NSRange(location: 0, length: piece.length))
            body.replaceCharacters(in: match.range, with: piece)
            used += 1
        }
        return used
    }
}
