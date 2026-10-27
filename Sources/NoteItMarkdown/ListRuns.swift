import NoteItDoc

/// Where a run of list items breaks into a new list, as the Mac's Markdown export writes it: a top-level item of a
/// different kind (bullet, numbered, checklist) than the run's last top-level item starts a new list after a blank
/// line. That blank line separates the two lists; it is never an empty paragraph.
struct ListRuns {
    private var topKind: ListKind?

    /// Feeds the next block in document order; true when a separating blank line goes before it.
    mutating func startsNewList(_ node: DocNode?) -> Bool {
        guard case .listItem(let kind, let level, _, _, _, _)? = node else {
            topKind = nil
            return false
        }
        guard level == 0 else { return false }
        defer { topKind = kind }
        return topKind != nil && topKind != kind
    }
}
