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
}

extension NoteStore {
    static let tagEditBatchSize = 50

    /// Renames `from` (and the tags nested in it) to `to` in every note's text; merges when `to` exists.
    func renameTag(_ from: String, to: String, progress: ((Int, Int) -> Bool)? = nil) async -> TagEditResult {
        guard TagRewriter.renameProblem(from: from, to: to) == nil else { return TagEditResult() }
        let target = to.hasPrefix("#") ? String(to.dropFirst()) : to
        var result = await applyTagEdit(.rename(from: from, to: target), tag: from, actionName: "Rename Tag", progress: progress)
        if !result.cancelled {
            rewriteSmartFolderQueries { QueryRewriter.renamingTag(TokenGrammar.normalizedTag(from), to: target, in: $0) }
        }
        result.untouchedInTrash = trashedNotes(tagged: from)
        return result
    }

    /// Removes `#tag` (and the tags nested in it) from every note's text.
    func deleteTag(_ tag: String, progress: ((Int, Int) -> Bool)? = nil) async -> TagEditResult {
        var result = await applyTagEdit(.delete(tag), tag: tag, actionName: "Delete Tag", progress: progress)
        result.untouchedInTrash = trashedNotes(tagged: tag)
        return result
    }

    /// Puts back the bodies from before a tag edit, except in notes changed since. Returns how many were left alone.
    @discardableResult
    func undoTagEdit(_ result: TagEditResult) -> Int {
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

    /// Notes not in Recently Deleted that carry `tag` or a tag nested in it.
    func notesTagged(_ tag: String) -> [NoteMeta] {
        let selected = TokenGrammar.normalizedTag(tag)
        return activeNotes.filter { $0.tags.contains { TagTree.matches($0, selected: selected) } }
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
