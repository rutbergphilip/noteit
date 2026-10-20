import Foundation

/// The single filter, search and sort for every `SidebarSelection` case, shared by the Mac list, organise
/// and the phone. Moved out of `NoteStore` in foundations Task 1.4; each new case's owner fills in its filter.
public enum LibraryQuery {
    /// Window during which notes count as "Recent".
    public static let recentInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Pinned first, then most recently updated; Recently Deleted is newest deletion first.
    /// `indexedText` returns a note's folded search text from the caller's index, or nil to fall back to
    /// `TextFold.fold(title + "\n" + preview)`. Every folded search term must occur in it.
    public static func notes(
        _ all: [NoteMeta],
        for selection: SidebarSelection?,
        search: String,
        now: Date,
        indexedText: (UUID) -> String?
    ) -> [NoteMeta] {
        let filtered = filter(all, for: selection ?? .allNotes, now: now)

        let terms = TextFold.fold(search).split(whereSeparator: \.isWhitespace)
        let searched: [NoteMeta]
        if terms.isEmpty {
            searched = filtered
        } else {
            searched = filtered.filter { note in
                let haystack = indexedText(note.id) ?? TextFold.fold(note.title + "\n" + note.preview)
                return terms.allSatisfy { haystack.contains($0) }
            }
        }

        if selection == .recentlyDeleted {
            return searched.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        }
        return searched.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    public static func count(_ all: [NoteMeta], for selection: SidebarSelection, now: Date) -> Int {
        filter(all, for: selection, now: now).count
    }

    private static func filter(_ all: [NoteMeta], for selection: SidebarSelection, now: Date) -> [NoteMeta] {
        let active = all.filter { $0.deletedAt == nil }
        switch selection {
        case .allNotes:
            return active
        case .pinned:
            return active.filter(\.isPinned)
        case .recent:
            let cutoff = now.addingTimeInterval(-recentInterval)
            return active.filter { $0.updatedAt >= cutoff }
        case .conflicts:
            return active.filter { $0.conflictSource != nil }
        case .recentlyDeleted:
            return all.filter { $0.deletedAt != nil }
        case .notebook(let id):
            return active.filter { $0.notebookID == id }
        case .tag(let tag):
            return active.filter { $0.tags.contains(tag) }
        case .today, .tasks, .smartFolder:
            return []
        }
    }
}
