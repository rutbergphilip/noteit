import Foundation
import NoteItCore

extension NotebookTree {
    /// The children of `parent`, or the top-level notebooks when nil, in display order.
    func siblings(under parent: UUID?) -> [UUID] {
        parent.map(children(of:)) ?? roots
    }
}

extension NoteStore {
    var notebookTree: NotebookTree {
        if let cache = notebookTreeCache, cache.notebooksVersion == notebooksVersion { return cache.tree }
        let tree = NotebookTree(notebooks.map {
            NotebookNodeInput(id: $0.id, parentID: $0.parent, sortIndex: $0.sortIndex, name: $0.name)
        })
        notebookTreeCache = (notebooksVersion, tree)
        return tree
    }

    /// The notebook and every notebook nested in it; a notebook selection and its count cover all of them.
    func notebookIDsIncludingDescendants(_ id: UUID) -> Set<UUID> {
        Set([id] + notebookTree.descendants(of: id))
    }

    /// Notebook names from the top level down, e.g. `Work › Clients`.
    func notebookPathTitle(_ id: UUID) -> String {
        notebookTree.path(of: id).joined(separator: " › ")
    }

    /// Moves a notebook under `parentID` (top level when nil) at a sibling index (the end when nil). Refuses
    /// moves into itself, into its own sub-notebooks, or deeper than four levels.
    @discardableResult
    func moveNotebook(_ id: UUID, under parentID: UUID?, at index: Int? = nil) -> Bool {
        let tree = notebookTree
        guard tree.canMove(id, under: parentID), let position = notebooks.firstIndex(where: { $0.id == id }) else { return false }
        let oldParent = tree.effectiveParent(of: id)
        var siblings = tree.siblings(under: parentID).filter { $0 != id }
        siblings.insert(id, at: min(max(index ?? siblings.count, 0), siblings.count))
        let now = Date()
        if notebooks[position].parent != parentID {
            notebooks[position].parent = parentID
            notebooks[position].revision = UUID()
            notebooks[position].modifiedAt = now
        }
        reindexNotebooks(siblings, now: now)
        if oldParent != parentID { reindexNotebooks(tree.siblings(under: oldParent).filter { $0 != id }, now: now) }
        commitNotebookChange()
        return true
    }
}
