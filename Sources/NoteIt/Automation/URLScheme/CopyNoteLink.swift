import AppKit
import NoteItCore

/// Edit › Copy Note Link (⌃⌘L): the one entry point for the menu, the palette and `linking`'s context menu.
@MainActor
enum CopyNoteLink {
    /// Writes `noteit://note/<UUID>` as `.string` and the note's title linked to it as `.rtf`.
    static func perform(noteID: UUID, store: NoteStore? = nil, pasteboard: NSPasteboard = .general) {
        guard let note = (store ?? .shared).note(with: noteID) else { return }
        let url = NoteLink.note(id: noteID, heading: nil).url
        let linked = NSAttributedString(string: note.displayTitle, attributes: [.link: url])
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .rtf], owner: nil)
        pasteboard.setString(url.absoluteString, forType: .string)
        if let rtf = linked.rtf(from: NSRange(location: 0, length: linked.length), documentAttributes: [:]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }
}
