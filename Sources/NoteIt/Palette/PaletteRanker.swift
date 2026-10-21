import NoteItCore
import Foundation

struct PaletteCommandInfo: Equatable {
    let id: String
    let title: String
    let symbol: String        // SF Symbol name
    let shortcut: String?     // display string like "⇧⌘N"
    let keywords: [String]    // extra words that can match (not highlighted)
}

enum PaletteMode: Equatable { case everything, commands }

enum PaletteItemKind: Equatable {
    case note(UUID)
    case notebook(UUID)
    case smartFolder(UUID)
    case tag(String)          // tag path
    case command(String)      // PaletteCommandInfo.id
    case createNote(String)   // trimmed title to create
}

struct PaletteItem: Identifiable, Equatable {
    let id: String            // stable, unique: "note:<uuid>", "notebook:<uuid>", "command:<id>", "create"
    let kind: PaletteItemKind
    let title: String
    let subtitle: String?     // notes: notebook name; commands: nil; notebooks: note count like "12 notes"
    let symbol: String
    let shortcut: String?
    let matchedIndices: [Int] // into title, for highlighting
}

enum PaletteRanker {
    static let recentNotesLimit = 10
    /// Notes found only by body text; title matches always score at least 1.
    private static let bodyMatchScore = 0

    /// ">" prefix (after leading whitespace) selects .commands; the rest (trimmed) is the text.
    static func parse(_ raw: String) -> (mode: PaletteMode, text: String) {
        let leading = raw.drop(while: \.isWhitespace)
        if leading.first == ">" {
            return (.commands, leading.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (.everything, raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func items(
        query raw: String,
        notes: [NoteMeta],
        notebooks: [Notebook],
        commands: [PaletteCommandInfo],
        bodyMatches: [UUID: Double],
        smartFolders: [SmartFolder] = [],
        tags: [(path: String, count: Int)] = [],
        limit: Int = 50
    ) -> [PaletteItem] {
        let (mode, text) = parse(raw)
        let cap = max(0, limit)

        switch mode {
        case .commands:
            if text.isEmpty {
                let sorted = commands.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return sorted.prefix(cap).map { commandItem($0, indices: []) }
            }
            let query = FuzzyQuery(text)
            let ranked = commands.compactMap { rankedCommand($0, query: query) }
            return ranked.sorted(by: precedes).prefix(cap).map(\.item)

        case .everything:
            let names = notebookNames(notebooks)
            if text.isEmpty {
                let recent = notes.sorted { $0.updatedAt > $1.updatedAt }
                return recent.prefix(min(cap, recentNotesLimit)).map { noteItem($0, names: names, indices: []) }
            }

            let query = FuzzyQuery(text)
            var ranked: [Ranked] = []
            var hasNoteTitledText = false
            for note in notes {
                if let (match, isExact) = FuzzyMatcher.evaluate(query, in: note.displayTitle) {
                    // Folded equality is coarser than the create-row rule, so only exact folded hits
                    // (or titles with surrounding whitespace) need the full check.
                    if !hasNoteTitledText, isExact || hasSurroundingWhitespace(note.title), titleEquals(note.title, text) {
                        hasNoteTitledText = true
                    }
                    let item = noteItem(note, names: names, indices: match.matchedIndices)
                    ranked.append(Ranked(item: item, score: match.score, kindRank: 0, updatedAt: note.updatedAt))
                } else if let bodyScore = bodyMatches[note.id] {
                    let item = noteItem(note, names: names, indices: [])
                    ranked.append(Ranked(item: item, score: bodyMatchScore, kindRank: 0, updatedAt: note.updatedAt,
                                         bodyScore: bodyScore))
                }
            }

            let counts = noteCounts(notes)
            for notebook in notebooks {
                guard let match = FuzzyMatcher.match(query, in: notebook.name) else { continue }
                let count = counts[notebook.id] ?? 0
                let item = PaletteItem(
                    id: "notebook:\(notebook.id.uuidString)",
                    kind: .notebook(notebook.id),
                    title: notebook.name,
                    subtitle: notebookSubtitle(notebook, paths: names, count: count),
                    symbol: notebook.symbol,
                    shortcut: nil,
                    matchedIndices: match.matchedIndices
                )
                ranked.append(Ranked(item: item, score: match.score, kindRank: 1, updatedAt: nil))
            }

            for folder in smartFolders {
                guard let match = FuzzyMatcher.match(query, in: folder.name) else { continue }
                let item = PaletteItem(id: "smartFolder:\(folder.id.uuidString)", kind: .smartFolder(folder.id), title: folder.name,
                                       subtitle: "Smart Folder · \(folder.query)", symbol: folder.symbol, shortcut: nil,
                                       matchedIndices: match.matchedIndices)
                ranked.append(Ranked(item: item, score: match.score, kindRank: 1, updatedAt: nil))
            }

            for tag in tags {
                let title = "#" + tag.path
                guard let match = FuzzyMatcher.match(query, in: title) else { continue }
                let item = PaletteItem(id: "tag:\(tag.path)", kind: .tag(tag.path), title: title,
                                       subtitle: tag.count == 1 ? "1 note" : "\(tag.count) notes", symbol: "number", shortcut: nil,
                                       matchedIndices: match.matchedIndices)
                ranked.append(Ranked(item: item, score: match.score, kindRank: 1, updatedAt: nil))
            }

            for command in commands {
                if let entry = rankedCommand(command, query: query) { ranked.append(entry) }
            }

            var result = ranked.sorted(by: precedes).prefix(cap).map(\.item)
            if !hasNoteTitledText {
                result.append(PaletteItem(
                    id: "create",
                    kind: .createNote(text),
                    title: "New Note “\(text)”",
                    subtitle: nil,
                    symbol: "square.and.pencil",
                    shortcut: nil,
                    matchedIndices: []
                ))
            }
            return result
        }
    }

    // MARK: - Helpers

    private struct Ranked {
        let item: PaletteItem
        let score: Int
        let kindRank: Int        // notes, then notebooks, smart folders and tags, then commands
        let updatedAt: Date?
        /// Search score of a body-only note match.
        var bodyScore: Double = 0
    }

    /// Score desc, then notes before notebooks before commands, then most recent, then title.
    private static func precedes(_ a: Ranked, _ b: Ranked) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.kindRank != b.kindRank { return a.kindRank < b.kindRank }
        if a.bodyScore != b.bodyScore { return a.bodyScore > b.bodyScore }
        let aDate = a.updatedAt ?? .distantPast
        let bDate = b.updatedAt ?? .distantPast
        if aDate != bDate { return aDate > bDate }
        let order = a.item.title.localizedStandardCompare(b.item.title)
        if order != .orderedSame { return order == .orderedAscending }
        return a.item.id < b.item.id
    }

    /// Title match keeps its score and highlights; a match that needs the keywords scores half and highlights nothing.
    private static func rankedCommand(_ command: PaletteCommandInfo, query: FuzzyQuery) -> Ranked? {
        if let match = FuzzyMatcher.match(query, in: command.title) {
            return Ranked(item: commandItem(command, indices: match.matchedIndices),
                          score: match.score, kindRank: 2, updatedAt: nil)
        }
        guard !command.keywords.isEmpty else { return nil }
        var words = [command.title]
        words.append(contentsOf: command.keywords)
        guard let match = FuzzyMatcher.match(query, in: words.joined(separator: " ")) else { return nil }
        return Ranked(item: commandItem(command, indices: []),
                      score: max(1, match.score / 2), kindRank: 2, updatedAt: nil)
    }

    private static func commandItem(_ command: PaletteCommandInfo, indices: [Int]) -> PaletteItem {
        PaletteItem(
            id: "command:\(command.id)",
            kind: .command(command.id),
            title: command.title,
            subtitle: nil,
            symbol: command.symbol,
            shortcut: command.shortcut,
            matchedIndices: indices
        )
    }

    /// The create row's rule: same title ignoring case and surrounding whitespace, but not accents.
    private static func titleEquals(_ title: String, _ text: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).compare(text, options: .caseInsensitive) == .orderedSame
    }

    private static func hasSurroundingWhitespace(_ title: String) -> Bool {
        (title.first?.isWhitespace ?? false) || (title.last?.isWhitespace ?? false)
    }

    /// A nested notebook names its parents, e.g. `Work › Clients · 3 notes`.
    private static func notebookSubtitle(_ notebook: Notebook, paths: [UUID: String], count: Int) -> String {
        let notes = count == 1 ? "1 note" : "\(count) notes"
        guard let parent = notebook.parent, let path = paths[parent], paths[notebook.id] != notebook.name else { return notes }
        return "\(path) · \(notes)"
    }

    private static func noteItem(_ note: NoteMeta, names: [UUID: String], indices: [Int]) -> PaletteItem {
        PaletteItem(
            id: "note:\(note.id.uuidString)",
            kind: .note(note.id),
            title: note.displayTitle,
            subtitle: note.notebookID.flatMap { names[$0] },
            symbol: note.isPinned ? "pin.fill" : "doc.text",
            shortcut: nil,
            matchedIndices: indices
        )
    }

    private static func notebookNames(_ notebooks: [Notebook]) -> [UUID: String] {
        let tree = NotebookTree(notebooks.map {
            NotebookNodeInput(id: $0.id, parentID: $0.parent, sortIndex: $0.sortIndex, name: $0.name)
        })
        var names: [UUID: String] = [:]
        for notebook in notebooks where names[notebook.id] == nil {
            names[notebook.id] = tree.path(of: notebook.id).joined(separator: " › ")
        }
        return names
    }

    private static func noteCounts(_ notes: [NoteMeta]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for note in notes {
            if let id = note.notebookID { counts[id, default: 0] += 1 }
        }
        return counts
    }
}
