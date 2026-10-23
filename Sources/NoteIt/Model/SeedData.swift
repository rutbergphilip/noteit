import AppKit

/// First-launch content.
@MainActor
enum SeedData {
    static func seed(into store: NoteStore) {
        let inbox = store.createNotebook(name: "Inbox", symbol: "tray", colorHex: Tokens.Hex.notebookBlue)
        _ = store.createNotebook(name: "Ideas", symbol: "lightbulb", colorHex: Tokens.Hex.notebookOrange)

        let welcome = store.createNote(in: inbox.id, initial: welcomeBody())
        store.togglePin(welcome.id)
    }

    // MARK: - Builders (styles live in Editor/EditorStyles.swift)

    private static func h1(_ text: String) -> NSAttributedString { EditorStyle.paragraph(text, kind: .title) }
    private static func h2(_ text: String) -> NSAttributedString { EditorStyle.paragraph(text, kind: .heading) }
    private static func para(_ text: String) -> NSAttributedString { EditorStyle.paragraph(text, kind: .body) }
    private static func bullet(_ text: String, code: String? = nil) -> NSAttributedString { EditorStyle.bullet(text, code: code) }

    // MARK: - Notes

    static func welcomeBody() -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(h1("Welcome to NoteIt"))
        s.append(para("A calm, fast place for your notes. Everything saves as you type and lives on your Mac. There's no account, and nothing leaves this Mac unless you turn on sync."))

        s.append(h2("Getting around"))
        s.append(bullet("New note", code: "⌘N"))
        s.append(bullet("New notebook", code: "⇧⌘N"))
        s.append(bullet("Search all notes", code: "⌘F"))
        s.append(bullet("Open Quickly: jump to any note, notebook or command", code: "⌘O"))
        s.append(bullet("Command Palette: run any command by name", code: "⇧⌘P"))

        s.append(h2("Capture from anywhere"))
        s.append(para("NoteIt lives in your menu bar too. Give Quick Capture and Capture Selection a global hotkey to jot something down or save selected text from any app. They start unbound, so set them in Settings › Shortcuts, where you can also change NoteIt's own shortcuts."))

        s.append(h2("Write in Markdown"))
        s.append(para("Type these at the start of a line and NoteIt formats as you go:"))
        s.append(bullet("Heading 1, 2 and 3", code: "#  ##  ###"))
        s.append(bullet("Bulleted list", code: "-"))
        s.append(bullet("Numbered list", code: "1."))
        s.append(bullet("Checklist", code: "[]"))
        s.append(bullet("Quote", code: ">"))
        s.append(bullet("Code block", code: "```"))
        s.append(bullet("Divider", code: "---"))
        s.append(bullet("Bold text, anywhere in a line", code: "**bold**"))
        s.append(para("Copied Markdown pastes in formatted with ⌘V. ⇧⌘V pastes just the text."))

        s.append(h2("Stay organized"))
        s.append(bullet("Pin important notes so they stay on top."))
        s.append(bullet("Add a hashtag such as #welcome anywhere in a note to find it under Tags."))
        s.append(bullet("Drag notes onto a notebook to move them, and drag notebooks to reorder."))
        s.append(bullet("Paste or drop images straight into a note."))

        s.append(h2("Your notes, safe"))
        s.append(bullet("Sync your Macs through a folder or S3-compatible storage you own, end-to-end encrypted. It's optional and off until you set it up in Settings › Sync."))
        s.append(bullet("Export a note as Markdown, HTML, PDF, rich text or plain text.", code: "⇧⌘S"))
        s.append(bullet("Deleted notes wait in Recently Deleted for 30 days."))
        s.append(bullet("Version History brings back earlier versions of a note.", code: "⌥⌘Y"))
        s.append(para(""))
        s.append(para("#welcome"))
        return s
    }
}
