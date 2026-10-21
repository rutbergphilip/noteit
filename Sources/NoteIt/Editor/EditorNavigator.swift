import AppKit

/// Opens a note at one of its lines: from the Tasks view and from reminder notifications.
@MainActor
enum EditorNavigator {
    /// Paragraph ranges are counted on "\n" like `TaskParser`; nil past the end.
    nonisolated static func paragraphRange(_ paragraph: Int, in text: String) -> NSRange? {
        guard paragraph >= 0 else { return nil }
        let ns = text as NSString
        var location = 0
        for _ in 0..<paragraph {
            let newline = ns.range(of: "\n", options: [], range: NSRange(location: location, length: ns.length - location))
            guard newline.location != NSNotFound else { return nil }
            location = NSMaxRange(newline)
        }
        let end = ns.range(of: "\n", options: [], range: NSRange(location: location, length: ns.length - location))
        return NSRange(location: location, length: (end.location == NSNotFound ? ns.length : end.location) - location)
    }

    /// Selects the note, puts the caret at the start of `paragraph`, scrolls to it and flashes it once.
    /// With `inAllNotes`, the note is shown in All Notes; otherwise the sidebar selection stays.
    static func reveal(_ noteID: UUID, paragraph: Int, inAllNotes: Bool, store: NoteStore) {
        guard let meta = store.note(with: noteID) else { return }
        let range = meta.isLocked ? nil : paragraphRange(paragraph, in: store.body(for: noteID).string)
        if let range, OpenEditorRegistry.shared.textView(for: noteID) == nil {
            RichTextEditor.pendingCaret[noteID] = range.location
        }
        if inAllNotes {
            store.reveal(noteID)
        } else {
            store.selectedNoteID = noteID
        }
        guard let range else { return }
        // The editor loads the note on the next turns of the run loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let textView = OpenEditorRegistry.shared.textView(for: noteID) else { return }
            let target = textView.clamp(range)
            textView.setSelectedRange(NSRange(location: target.location, length: 0))
            textView.scrollRangeToVisible(target)
            if target.length > 0 { textView.showFindIndicator(for: target) }
        }
    }
}
