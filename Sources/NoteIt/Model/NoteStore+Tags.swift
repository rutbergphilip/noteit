import Foundation
import NoteItCore

extension NoteStore {
    /// Tags of notes not in Recently Deleted as a tree, with implied parents.
    var tagTree: [TagNode] {
        if let cache = tagTreeCache, cache.notesVersion == notesVersion { return cache.tree }
        let tree = TagTree.build(noteTags: activeNotes.map(\.tags))
        tagTreeCache = (notesVersion, tree)
        return tree
    }
}

struct TagEditResult {
    /// Note ID → revision before the edit.
    var changed: [UUID: UUID] = [:]
    var skipped: [UUID: BodyEditError] = [:]
    /// Note ID → revision right after the edit; Undo leaves notes that moved on alone.
    var revisionsAfter: [UUID: UUID] = [:]
    /// Note ID → body before the edit, put back by Undo.
    var bodiesBefore: [UUID: NSAttributedString] = [:]
    var cancelled = false
    /// Matching notes in Recently Deleted, which aren't changed.
    var untouchedInTrash = 0
    /// Smart folders whose query the rename rewrote, put back by Undo.
    var smartFolderQueries: [UUID: SmartFolderQueryChange] = [:]
    /// The sidebar selection before and after the edit moved it off the old tag; Undo goes back if it's still there.
    var selectionMove: (before: SidebarSelection, after: SidebarSelection)?
}

extension NoteStore {
    static let tagEditBatchSize = 50

    /// Renames `from` (and the tags nested in it) to `to` in every note's text; merges when `to` exists.
    func renameTag(_ from: String, to: String, progress: ((Int, Int) -> Bool)? = nil) async -> TagEditResult {
        guard TagRewriter.renameProblem(from: from, to: to, tags: tagsInUse) == nil else { return TagEditResult() }
        let target = to.hasPrefix("#") ? String(to.dropFirst()) : to
        var result = await applyTagEdit(.rename(from: from, to: target), tag: from, actionName: "Rename Tag", progress: progress)
        if !result.cancelled {
            result.smartFolderQueries = rewriteSmartFolderQueries { QueryRewriter.renamingTag(TokenGrammar.normalizedTag(from), to: target, in: $0) }
            result.selectionMove = moveTagSelection(from: from) { remainder in
                .tag(TokenGrammar.normalizedTag(([target] + remainder).joined(separator: "/")))
            }
        }
        result.untouchedInTrash = trashedNotes(tagged: from)
        return result
    }

    /// Removes `#tag` (and the tags nested in it) from every note's text.
    func deleteTag(_ tag: String, progress: ((Int, Int) -> Bool)? = nil) async -> TagEditResult {
        var result = await applyTagEdit(.delete(tag), tag: tag, actionName: "Delete Tag", progress: progress)
        if !result.cancelled { result.selectionMove = moveTagSelection(from: tag) { _ in .allNotes } }
        result.untouchedInTrash = trashedNotes(tagged: tag)
        return result
    }

    /// Puts back the bodies from before a tag edit, except in notes changed since. Returns how many were left alone.
    @discardableResult
    func undoTagEdit(_ result: TagEditResult) -> Int {
        restoreSmartFolderQueries(result.smartFolderQueries)
        if let move = result.selectionMove, selection == move.after { selection = move.before }
        var leftAlone = 0
        for (id, after) in result.revisionsAfter {
            guard let before = result.bodiesBefore[id], note(with: id)?.revision == after else {
                leftAlone += 1
                continue
            }
            do {
                try editBody(id, actionName: "Undo Tag Change") { $0.setAttributedString(before) }
            } catch {
                leftAlone += 1
            }
        }
        return leftAlone
    }

    /// Every tag written in a note, Recently Deleted included.
    var tagsInUse: [String] {
        Array(Set(notes.flatMap(\.tags)))
    }

    /// Notes not in Recently Deleted that carry `tag` or a tag nested in it.
    func notesTagged(_ tag: String) -> [NoteMeta] {
        let selected = TokenGrammar.normalizedTag(tag)
        return activeNotes.filter { $0.tags.contains { TagTree.matches($0, selected: selected) } }
    }

    /// Moves a selected tag (or one nested in `tag`) to `destination`, given the segments below `tag`.
    private func moveTagSelection(from tag: String, to destination: ([String]) -> SidebarSelection)
        -> (before: SidebarSelection, after: SidebarSelection)? {
        guard case .tag(let selected)? = selection else { return nil }
        let source = TokenGrammar.normalizedTag(tag), current = TokenGrammar.normalizedTag(selected)
        guard TagTree.matches(current, selected: source) else { return nil }
        let remainder = current.split(separator: "/").dropFirst(source.split(separator: "/").count).map(String.init)
        let before = SidebarSelection.tag(selected), after = destination(remainder)
        selection = after
        return (before, after)
    }

    private func trashedNotes(tagged tag: String) -> Int {
        let selected = TokenGrammar.normalizedTag(tag)
        return notes.filter { $0.deletedAt != nil && $0.tags.contains { TagTree.matches($0, selected: selected) } }.count
    }

    private func applyTagEdit(_ edit: TagEdit, tag: String, actionName: String,
                              progress: ((Int, Int) -> Bool)?) async -> TagEditResult {
        let targets = notesTagged(tag).filter { !$0.isLocked }.map(\.id)
        var result = TagEditResult()
        for (offset, id) in targets.enumerated() {
            if offset > 0, offset % Self.tagEditBatchSize == 0 {
                if let progress, !progress(offset, targets.count) {
                    result.cancelled = true
                    break
                }
                await Task.yield()
            }
            guard let meta = note(with: id), meta.deletedAt == nil, !meta.isLocked else { continue }
            let before = NSAttributedString(attributedString: body(for: id))
            do {
                try editBody(id, actionName: actionName) { body in
                    for change in TagRewriter.edits(for: edit, inMasked: Self.maskedForTokens(body))
                    where NSMaxRange(change.range) <= body.length {
                        body.replaceCharacters(in: change.range, with: change.replacement)
                    }
                }
            } catch let error as BodyEditError {
                result.skipped[id] = error
                continue
            } catch {
                continue
            }
            guard let after = note(with: id)?.revision, after != meta.revision else { continue }
            result.changed[id] = meta.revision ?? UUID()
            result.revisionsAfter[id] = after
            result.bodiesBefore[id] = before
        }
        _ = progress?(targets.count, targets.count)
        return result
    }
}
