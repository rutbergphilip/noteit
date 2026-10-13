import AppKit

/// First-launch content.
@MainActor
enum SeedData {
    static func seed(into store: NoteStore) {
        let inbox = store.createNotebook(name: "Inbox", symbol: "tray", colorHex: "#0A84FF")
        let shortcuts = store.createNotebook(name: "Shortcuts", symbol: "command", colorHex: "#BF5AF2")
        _ = store.createNotebook(name: "Ideas", symbol: "lightbulb", colorHex: "#FF9F0A")

        let shortcutsNote = store.createNote(in: shortcuts.id, initial: shortcutsBody())
        let welcome = store.createNote(in: inbox.id, initial: welcomeBody())
        store.togglePin(welcome.id)

        // Keep the welcome note on top of "All Notes".
        if let i = store.notes.firstIndex(where: { $0.id == shortcutsNote.id }) {
            store.notes[i].updatedAt = Date().addingTimeInterval(-60)
            store.notes[i].createdAt = store.notes[i].updatedAt
        }
    }

    // MARK: - Builders (styles live in Editor/EditorStyles.swift)

    private static func h1(_ text: String) -> NSAttributedString { EditorStyle.paragraph(text, kind: .title) }
    private static func h2(_ text: String) -> NSAttributedString { EditorStyle.paragraph(text, kind: .heading) }
    private static func para(_ text: String) -> NSAttributedString { EditorStyle.paragraph(text, kind: .body) }
    private static func bullet(_ text: String, code: String? = nil) -> NSAttributedString { EditorStyle.bullet(text, code: code) }

    static func table(header: [String], rows: [[String]]) -> NSAttributedString {
        EditorStyle.table(header: header, rows: rows, widths: header.count == 2 ? [30, 70] : nil, monospacedFirstColumn: true)
    }

    // MARK: - Notes

    static func shortcutsBody() -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(h1("Custom keyboard shortcuts"))
        s.append(h2("Ghostty"))
        s.append(table(
            header: ["Shortcut", "Action"],
            rows: [
                ["⌃⌘E", "Equalize the size of all split tabs in Ghostty"],
                ["⇧⌘L", "Switch theme mode in Ghostty"],
            ]
        ))
        s.append(para(""))
        s.append(para("#shortcuts #ghostty"))
        return s
    }

    static func welcomeBody() -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(h1("Welcome to NoteIt"))
        s.append(para("NoteIt is a calm, fast place for your notes. Everything is saved automatically as you type, and stays on your Mac."))

        s.append(h2("Getting around"))
        s.append(bullet("New note", code: "⌘N"))
        s.append(bullet("New notebook", code: "⇧⌘N"))
        s.append(bullet("Search all notes", code: "⌘F"))
        s.append(bullet("Drag notes onto a notebook in the sidebar to move them, and drag notebooks to reorder."))
        s.append(bullet("Pin important notes so they stay on top."))
        s.append(bullet("Add hashtags anywhere in a note to group it under Tags."))
        s.append(bullet("NoteIt also lives in your menu bar, and you can assign global hotkeys in Settings."))

        s.append(h2("Markdown shortcuts"))
        s.append(para("Type these at the start of a line and NoteIt formats as you go:"))
        s.append(bullet("Heading 1, 2 and 3", code: "#  ##  ###"))
        s.append(bullet("Bulleted list", code: "-"))
        s.append(bullet("Numbered list", code: "1."))
        s.append(bullet("Checklist", code: "[]"))
        s.append(bullet("Block quote", code: ">"))
        s.append(bullet("Code block", code: "```"))
        s.append(bullet("Divider", code: "---"))
        s.append(bullet("Bold text", code: "**bold**"))

        s.append(h2("Rich formatting"))
        s.append(para("Use the formatting toolbar for text color, highlights, tables, links, alignment and more. Paste or drop images straight into a note."))
        s.append(para(""))
        s.append(para("#welcome"))
        return s
    }
}
