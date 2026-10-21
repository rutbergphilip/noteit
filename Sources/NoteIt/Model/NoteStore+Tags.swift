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
