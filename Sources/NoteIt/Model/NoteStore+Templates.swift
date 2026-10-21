import AppKit
import NoteItCore

/// Templates are ordinary notes in the templates notebook (spec §11).
extension NoteStore {
    static let templatesNotebookName = "Templates"
    nonisolated(unsafe) static var clipboardString: () -> String? = { NSPasteboard.general.string(forType: .string) }

    /// The notebook from the preference, else one named "Templates". Never creates one.
    var templatesNotebookIDIfSet: UUID? {
        if let raw = preferences.string(forKey: PrefKey.templatesNotebookID), let id = UUID(uuidString: raw),
           notebook(with: id) != nil {
            return id
        }
        return sortedNotebooks.first {
            $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(Self.templatesNotebookName) == .orderedSame
        }?.id
    }

    func templatesNotebookID(createIfMissing: Bool) -> UUID? {
        if let id = templatesNotebookIDIfSet { return id }
        guard createIfMissing else { return nil }
        let created = createNotebook(name: Self.templatesNotebookName, symbol: "doc.on.doc",
                                     colorHex: NotebookPalette.colors.first ?? Tokens.Hex.notebookBlue)
        preferences.set(created.id.uuidString, forKey: PrefKey.templatesNotebookID)
        return created.id
    }

    /// Live notes in the templates notebook, by name.
    var templates: [NoteMeta] {
        guard let notebookID = templatesNotebookIDIfSet else { return [] }
        return notes
            .filter { $0.notebookID == notebookID && $0.deletedAt == nil }
            .sorted {
                let order = Self.templateName($0).localizedStandardCompare(Self.templateName($1))
                return order == .orderedSame ? $0.createdAt < $1.createdAt : order == .orderedAscending
            }
    }

    static func templateName(_ meta: NoteMeta) -> String {
        TemplateExpander.displayName(forTitle: meta.title)
    }

    func isTemplate(_ id: UUID) -> Bool {
        guard let meta = note(with: id), let notebookID = meta.notebookID else { return false }
        return notebookID == templatesNotebookIDIfSet
    }

    /// A live, unlocked template.
    private func usableTemplate(_ id: UUID?) -> NoteMeta? {
        guard let id, let meta = note(with: id), meta.deletedAt == nil, !meta.isLocked, isTemplate(id) else { return nil }
        return meta
    }

    @discardableResult
    func createTemplate() -> NoteMeta {
        createNote(in: templatesNotebookID(createIfMissing: true))
    }

    /// `readsClipboard` false leaves `{{clipboard}}` empty (the Local API never reads the clipboard).
    func expandedTemplate(_ id: UUID, title: String, date: Date, readsClipboard: Bool = true) -> TemplateExpansion? {
        guard usableTemplate(id) != nil else { return nil }
        let context = TemplateContext(title: title, date: date, clipboard: {
            readsClipboard ? NoteStore.clipboardString() : nil
        })
        return TemplateExpander.expand(body(for: id), context: context)
    }

    /// The notebook's template for new notes, while it is still a usable template.
    func defaultTemplateID(for notebookID: UUID?) -> UUID? {
        usableTemplate(notebook(with: notebookID)?.defaultTemplateID)?.id
    }

    /// A note from the expanded template, or a plain note (a title paragraph when `title` isn't empty) without one.
    @discardableResult
    func createNote(fromTemplate templateID: UUID?, title: String, in notebookID: UUID?, date: Date = Date(),
                    readsClipboard: Bool = true) -> NoteMeta {
        if let templateID, let expansion = expandedTemplate(templateID, title: title, date: date, readsClipboard: readsClipboard) {
            let meta = createNote(in: notebookID, initial: expansion.text)
            if let caret = expansion.caret { RichTextEditor.pendingCaret[meta.id] = caret }
            return meta
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return createNote(in: notebookID, initial: trimmed.isEmpty ? nil : Self.linkedNoteBody(title: trimmed))
    }

    /// File › New Note from Template…: in the selected notebook, as ⌘N does, and selected.
    @discardableResult
    func createNoteFromTemplateInCurrentContext(_ templateID: UUID, title: String) -> NoteMeta {
        let notebookID = prepareCurrentContextForNewNote()
        let meta = createNote(fromTemplate: templateID, title: title, in: notebookID)
        selectedNoteID = meta.id
        return meta
    }

    /// `content` placed in the notebook's template at its `{{cursor}}`, else after it on a new line.
    func templatedBody(for notebookID: UUID?, title: String, content: NSAttributedString, date: Date = Date()) -> NSAttributedString? {
        guard let templateID = defaultTemplateID(for: notebookID),
              let expansion = expandedTemplate(templateID, title: title, date: date) else { return nil }
        let text = NSMutableAttributedString(attributedString: expansion.text)
        guard content.length > 0 else { return text }
        if let caret = expansion.caret {
            text.insert(content, at: min(caret, text.length))
        } else {
            if text.length > 0, !text.string.hasSuffix("\n") {
                text.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
            }
            text.append(content)
        }
        return text
    }
}
