import Foundation

/// What the evaluator and ranker read about one note.
public protocol SearchDocument {
    /// Folded body, title included; empty for locked notes.
    var foldedText: [UInt8] { get }
    /// Folded text from the `ImageTextProviding` provider; empty when there is none.
    var foldedImageText: [UInt8] { get }
    var foldedTitle: String { get }
    var tags: [String] { get }
    var notebookID: UUID? { get }
    var isPinned: Bool { get }
    var isConflict: Bool { get }
    var createdAt: Date { get }
    var updatedAt: Date { get }
    var openTaskCount: Int { get }
    var doneTaskCount: Int { get }
    var openDueDates: [LocalDateTime] { get }
    var hasLiveReminder: Bool { get }
    var hasAttachment: Bool { get }
}

public struct QueryContext: Sendable {
    public var now: Date, calendar: Calendar
    public var notebooks: NotebookTree

    public init(now: Date, calendar: Calendar, notebooks: NotebookTree) {
        self.now = now
        self.calendar = calendar
        self.notebooks = notebooks
    }
}

public enum QueryEvaluator {
    public static func matches(_ query: SearchQuery, _ doc: some SearchDocument, context: QueryContext) -> Bool {
        evaluate(query.root, doc, context)
    }

    private static func evaluate(_ node: QueryNode, _ doc: some SearchDocument, _ context: QueryContext) -> Bool {
        switch node {
        case .all:
            return true
        case .word(let term), .phrase(let term):
            return containsTerm(term, doc)
        case .title(let term):
            return term.isEmpty || doc.foldedTitle.contains(term)
        case .tag(let tag):
            return doc.tags.contains { TagTree.matches($0, selected: tag) }
        case .notebook(let path):
            guard let id = context.notebooks.id(forPath: path), let notebook = doc.notebookID else { return false }
            return notebook == id || context.notebooks.descendants(of: id).contains(notebook)
        case .is(let filter):
            switch filter {
            case .pinned: return doc.isPinned
            case .todo: return doc.openTaskCount > 0
            case .done: return doc.doneTaskCount > 0 && doc.openTaskCount == 0
            case .untagged: return doc.tags.isEmpty
            case .conflict: return doc.isConflict
            }
        case .has(let filter):
            switch filter {
            case .due: return !doc.openDueDates.isEmpty
            case .reminder: return doc.hasLiveReminder
            case .attachment: return doc.hasAttachment
            }
        case .date(let field, let filter):
            switch field {
            case .edited: return matches(doc.updatedAt, filter, context)
            case .created: return matches(doc.createdAt, filter, context)
            case .due: return doc.openDueDates.contains { matchesDue($0, filter, context) }
            }
        case .not(let inner):
            return !evaluate(inner, doc, context)
        case .and(let nodes):
            return nodes.allSatisfy { evaluate($0, doc, context) }
        case .or(let nodes):
            return nodes.contains { evaluate($0, doc, context) }
        }
    }

    /// Folded substring match, as search always did; the title and image text count too.
    static func containsTerm(_ term: String, _ doc: some SearchDocument) -> Bool {
        guard !term.isEmpty else { return true }
        let needle = Array(term.utf8)
        return ByteSearch.contains(doc.foldedText, needle) || doc.foldedTitle.contains(term)
            || ByteSearch.contains(doc.foldedImageText, needle)
    }

    private static func period(_ filter: DateFilter, _ context: QueryContext) -> DateInterval? {
        let calendar = context.calendar
        let now = context.now
        switch filter {
        case .today:
            return calendar.dateInterval(of: .day, for: now)
        case .yesterday:
            return calendar.date(byAdding: .day, value: -1, to: now).flatMap { calendar.dateInterval(of: .day, for: $0) }
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case .lastWeek:
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now)
                .flatMap { calendar.dateInterval(of: .weekOfYear, for: $0) }
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        default:
            return nil
        }
    }

    private static func dayInterval(_ day: LocalDateTime, _ calendar: Calendar) -> DateInterval? {
        day.dateOnly.date(in: calendar).flatMap { calendar.dateInterval(of: .day, for: $0) }
    }

    private static func matches(_ date: Date, _ filter: DateFilter, _ context: QueryContext) -> Bool {
        switch filter {
        case .within(let interval): return date >= context.now.addingTimeInterval(-interval)
        case .olderThan(let interval): return date < context.now.addingTimeInterval(-interval)
        case .on(let day): return dayInterval(day, context.calendar).map { date >= $0.start && date < $0.end } ?? false
        case .after(let day): return dayInterval(day, context.calendar).map { date >= $0.end } ?? false
        case .before(let day): return dayInterval(day, context.calendar).map { date < $0.start } ?? false
        case .overdue: return false
        default: return period(filter, context).map { date >= $0.start && date < $0.end } ?? false
        }
    }

    /// Due dates are wall-clock dates; `<7d` runs from today to 7 days ahead, `>7d` is later than that.
    private static func matchesDue(_ due: LocalDateTime, _ filter: DateFilter, _ context: QueryContext) -> Bool {
        let calendar = context.calendar
        guard let date = due.date(in: calendar) else { return false }
        let startOfToday = calendar.startOfDay(for: context.now)
        switch filter {
        case .within(let interval):
            return date >= startOfToday && date <= context.now.addingTimeInterval(interval)
        case .olderThan(let interval):
            return date > context.now.addingTimeInterval(interval)
        case .on(let day):
            return due.dateOnly == day.dateOnly
        case .after(let day):
            return due.dateOnly > day.dateOnly
        case .before(let day):
            return due.dateOnly < day.dateOnly
        case .overdue:
            return due.hasTime ? date < context.now : date < startOfToday
        default:
            return period(filter, context).map { date >= $0.start && date < $0.end } ?? false
        }
    }
}

enum ByteSearch {
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        firstIndex(haystack, needle, from: 0) != nil
    }

    static func firstIndex(_ haystack: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, haystack.count - start >= needle.count else { return nil }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                guard let base = hay.baseAddress, let found = memmem(base + start, hay.count - start,
                                                                      pin.baseAddress, pin.count) else { return nil }
                return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            }
        }
    }
}
