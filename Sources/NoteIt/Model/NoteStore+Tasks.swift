import AppKit
import Foundation
import NoteItCore

struct TaskRef: Hashable, Codable {
    var noteID: UUID
    var paragraph: Int
    var textHash: String
}

struct TaskItem: Identifiable, Hashable {
    var ref: TaskRef
    var line: TaskLine
    var noteTitle: String
    var notebookID: UUID?
    var noteUpdatedAt: Date
    var id: TaskRef { ref }

    func hash(into hasher: inout Hasher) { hasher.combine(ref) }
}

enum TaskGroup: CaseIterable {
    case overdue, today, upcoming, later, noDate, completed

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .later: "Later"
        case .noDate: "No Date"
        case .completed: "Completed"
        }
    }
}

/// One task as the query language sees it: words match the task's own text, `tag:` the line's tags or the note's,
/// `notebook:`, `edited:`, `created:` and `is:pinned` the note.
struct TaskSearchDocument: SearchDocument {
    var line: TaskLine
    var meta: NoteMeta
    var hasAttachment: Bool

    var foldedText: [UInt8] { Array(TextFold.fold(line.text).utf8) }
    var foldedImageText: [UInt8] { [] }
    var foldedTitle: String { "" }
    var tags: [String] { Array(Set(meta.tags + TokenGrammar.tags(inMasked: line.text))) }
    var notebookID: UUID? { meta.notebookID }
    var isPinned: Bool { meta.isPinned }
    var isConflict: Bool { meta.conflictSource != nil }
    var createdAt: Date { meta.createdAt }
    var updatedAt: Date { meta.updatedAt }
    var openTaskCount: Int { line.checked ? 0 : 1 }
    var doneTaskCount: Int { line.checked ? 1 : 0 }
    var openDueDates: [LocalDateTime] { line.checked ? [] : line.due.map { [$0] } ?? [] }
    var hasLiveReminder: Bool { line.remind != nil && !line.remindDone && !line.checked }
}

extension NoteStore {
    /// Every checkbox in notes that aren't locked or in Recently Deleted, filtered by `query` and grouped by due date.
    /// Upcoming is the next 7 days. Completed (only with `includeCompleted`) lists the newest notes first.
    func tasks(query: String, includeCompleted: Bool, now: Date = Date(), calendar: Calendar = .current) -> [TaskGroup: [TaskItem]] {
        let parsed = SearchQuery.parse(query)
        let context = QueryContext(now: now, calendar: calendar, notebooks: notebookTree)
        let entries = searchIndexer.entries
        let templates = templatesNotebookIDIfSet
        var groups: [TaskGroup: [TaskItem]] = [:]
        for meta in notes where meta.deletedAt == nil && !meta.isLocked && (templates == nil || meta.notebookID != templates) {
            guard let entry = entries[meta.id], let lines = entry.tasks, !lines.isEmpty else { continue }
            for line in lines {
                if line.checked && !includeCompleted { continue }
                if !parsed.isEmpty {
                    let doc = TaskSearchDocument(line: line, meta: meta, hasAttachment: entry.hasAttachment == true)
                    guard QueryEvaluator.matches(parsed, doc, context: context) else { continue }
                }
                let item = TaskItem(ref: TaskRef(noteID: meta.id, paragraph: line.paragraph, textHash: line.textHash),
                                    line: line, noteTitle: meta.displayTitle, notebookID: meta.notebookID,
                                    noteUpdatedAt: meta.updatedAt)
                groups[Self.group(of: line, now: now, calendar: calendar), default: []].append(item)
            }
        }
        for (group, items) in groups {
            groups[group] = items.sorted { a, b in
                if group != .completed, group != .noDate, let ad = a.line.due, let bd = b.line.due, ad != bd { return ad < bd }
                if a.noteUpdatedAt != b.noteUpdatedAt { return a.noteUpdatedAt > b.noteUpdatedAt }
                if a.ref.noteID != b.ref.noteID { return a.ref.noteID.uuidString < b.ref.noteID.uuidString }
                return a.ref.paragraph < b.ref.paragraph
            }
        }
        return groups
    }

    static func group(of line: TaskLine, now: Date, calendar: Calendar) -> TaskGroup {
        if line.checked { return .completed }
        guard let due = line.due else { return .noDate }
        let today = LocalDateTime(now, calendar: calendar, includeTime: false)
        let day = due.dateOnly
        if day < today { return .overdue }
        if day == today {
            if due.hasTime, let date = due.date(in: calendar), date < now { return .overdue }
            return .today
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let limit = calendar.date(byAdding: .day, value: 8, to: startOfToday), let date = day.date(in: calendar), date < limit {
            return .upcoming
        }
        return .later
    }

    /// Open tasks due today or overdue: the Tasks row's badge.
    var openDueTodayOrOverdueCount: Int {
        let groups = tasks(query: "", includeCompleted: false)
        return (groups[.overdue]?.count ?? 0) + (groups[.today]?.count ?? 0)
    }

    /// The task's paragraph range in `body`: the paragraph at the index if its text still matches, else the first
    /// paragraph with the same text, else `taskChanged`.
    nonisolated static func resolveTask(_ ref: TaskRef, in body: NSAttributedString) throws -> NSRange {
        let masked = maskedForTokens(body) as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location <= masked.length {
            let end = masked.range(of: "\n", options: [], range: NSRange(location: location, length: masked.length - location))
            let stop = end.location == NSNotFound ? masked.length : end.location
            ranges.append(NSRange(location: location, length: stop - location))
            if end.location == NSNotFound { break }
            location = stop + 1
        }
        func matches(_ range: NSRange) -> Bool {
            let text = masked.substring(with: range)
            return (text.hasPrefix(ChecklistMarkers.unchecked + "\t") || text.hasPrefix(ChecklistMarkers.checked + "\t"))
                && TaskParser.textHash(text) == ref.textHash
        }
        if ref.paragraph < ranges.count, matches(ranges[ref.paragraph]) { return ranges[ref.paragraph] }
        if let range = ranges.first(where: matches) { return range }
        throw BodyEditError.taskChanged
    }

    /// Checks or unchecks a task the way the checkbox in the editor does (marker and checked style), as one undoable
    /// change in an open editor. Doesn't record a version, like a click on the checkbox.
    func setTaskChecked(_ ref: TaskRef, _ checked: Bool) throws {
        try editBody(ref.noteID, actionName: checked ? "Check" : "Uncheck", versioning: .none) { body in
            let range = try Self.resolveTask(ref, in: body)
            Self.setChecked(checked, paragraph: range, in: body)
        }
    }

    static func setChecked(_ checked: Bool, paragraph range: NSRange, in body: NSMutableAttributedString) {
        let marker = checked ? ChecklistMarkers.checked : ChecklistMarkers.unchecked
        let markerLength = (marker as NSString).length
        let attributes = body.attributes(at: range.location, effectiveRange: nil)
        body.replaceCharacters(in: NSRange(location: range.location, length: markerLength),
                               with: NSAttributedString(string: marker, attributes: attributes))
        let contentStart = range.location + markerLength + 1
        let content = NSRange(location: contentStart, length: max(0, NSMaxRange(range) - contentStart))
        guard content.length > 0 else { return }
        let text = NSMutableAttributedString(attributedString: body.attributedSubstring(from: content))
        NoteItTextView.removeCheckedStyle(text)
        if checked { NoteItTextView.applyCheckedStyle(text) }
        body.replaceCharacters(in: content, with: text)
    }

    /// Writes, replaces or (with nil) removes the task's `@due(…)` token; a new token goes at the end of the line.
    func setDue(_ ref: TaskRef, _ due: LocalDateTime?) throws {
        let action = due == nil ? "Remove Due Date" : "Set Due Date"
        try editBody(ref.noteID, actionName: action, versioning: .none) { body in
            let range = try Self.resolveTask(ref, in: body)
            Self.setToken(.due, value: due.map { "@due(\($0.token))" }, paragraph: range, in: body)
        }
    }

    enum LineToken { case due, remind }

    /// Replaces the first token of the kind in the paragraph with `value`, removes it when `value` is nil, or appends
    /// `value` at the end of the line, separated by a space.
    static func setToken(_ kind: LineToken, value: String?, paragraph range: NSRange, in body: NSMutableAttributedString) {
        let masked = (maskedForTokens(body) as NSString).substring(with: range)
        let existing = TokenGrammar.tokens(inMasked: masked).first { token in
            switch (token.kind, kind) {
            case (.due, .due), (.remind, .remind): true
            default: false
            }
        }
        if let existing {
            var target = NSRange(location: range.location + existing.range.location, length: existing.range.length)
            if value == nil {
                let ns = body.string as NSString
                if target.location > range.location, ns.character(at: target.location - 1) == 0x20 {
                    target.location -= 1
                    target.length += 1
                }
                body.replaceCharacters(in: target, with: "")
            } else {
                let attributes = body.attributes(at: target.location, effectiveRange: nil)
                body.replaceCharacters(in: target, with: NSAttributedString(string: value!, attributes: attributes))
            }
            return
        }
        guard let value else { return }
        let ns = body.string as NSString
        let end = NSMaxRange(range)
        let needsSpace = end > range.location && !(ns.character(at: end - 1) == 0x20 || ns.character(at: end - 1) == 0x09)
        var attributes = end > range.location ? body.attributes(at: end - 1, effectiveRange: nil) : [:]
        attributes[.link] = nil
        if let font = attributes[.font] as? NSFont, font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            attributes[.font] = EditorStyle.bodyFont
        }
        body.insert(NSAttributedString(string: (needsSpace ? " " : "") + value, attributes: attributes), at: end)
    }
}

extension NoteStore {
    /// View › Tasks and the Show Tasks hotkey.
    func showTasks() {
        searchText = ""
        selection = .tasks
    }
}
