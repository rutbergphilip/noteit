import AppKit
import NoteItCore

/// Progress and results of one import run.
struct ImportReport: Equatable {
    var notesImported = 0
    var notebookIDs: Set<UUID> = []
    var lockedSkipped = 0
    var attachmentsSkipped = 0
    var filesSkipped = 0
    var notesSkipped = 0
    /// Notes imported without the encrypted sections they had (Evernote `en-crypt`).
    var encryptedSectionsSkipped = 0
    /// Tables cut to their first `NotionImporter.maxTableRows` rows, by name.
    var truncatedTables: [String] = []
    var cancelled = false
    /// Notes stopped answering because NoteIt's permission was turned off during the import.
    var permissionDenied = false

    var notebooksUsed: Int { notebookIDs.count }
    var rowsTruncated: Int { truncatedTables.count }

    /// "Imported 132 notes into 6 notebooks. Skipped 3 locked notes."
    var summary: String {
        var parts: [String] = []
        let notes = Self.count(notesImported, "note", "notes")
        if notebooksUsed > 0 {
            parts.append("Imported \(notes) into \(Self.count(notebooksUsed, "notebook", "notebooks")).")
        } else {
            parts.append("Imported \(notes).")
        }
        var skipped: [String] = []
        if lockedSkipped > 0 { skipped.append(Self.count(lockedSkipped, "locked note", "locked notes")) }
        if attachmentsSkipped > 0 { skipped.append(Self.count(attachmentsSkipped, "attachment", "attachments")) }
        if filesSkipped > 0 { skipped.append(Self.count(filesSkipped, "unreadable file", "unreadable files")) }
        if notesSkipped > 0 { skipped.append(Self.count(notesSkipped, "unreadable note", "unreadable notes")) }
        if !skipped.isEmpty { parts.append("Skipped \(Self.list(skipped)).") }
        if encryptedSectionsSkipped > 0 {
            parts.append(encryptedSectionsSkipped == 1 ? "1 note had encrypted sections that were skipped."
                         : "\(encryptedSectionsSkipped.formatted()) notes had encrypted sections that were skipped.")
        }
        if let table = truncatedTables.first {
            let limit = NotionImporter.maxTableRows.formatted()
            parts.append(truncatedTables.count == 1 ? "Only the first \(limit) rows of “\(table)” were imported."
                         : "Only the first \(limit) rows of \(truncatedTables.count.formatted()) tables were imported.")
        }
        if permissionDenied, let message = ImportError.notesPermissionDenied.errorDescription { parts.append(message) }
        return parts.joined(separator: " ")
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n == 1 ? one : many)"
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

struct ImportProgress: Equatable {
    var completed = 0
    var total = 0
    var currentName = ""

    var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
}

enum ImportError: LocalizedError, Equatable {
    case notesPermissionDenied
    case notesUnavailable(String)
    case nothingToImport
    case notionHTMLExport
    case unreadableArchive(String)

    var errorDescription: String? {
        switch self {
        case .notesPermissionDenied:
            "NoteIt isn't allowed to read your notes from the Notes app. Turn on Notes for NoteIt in System Settings › Privacy & Security › Automation, then try again."
        case .notesUnavailable(let detail):
            "Couldn't read from the Notes app. \(detail)"
        case .nothingToImport:
            "No notes were found to import."
        case .notionHTMLExport:
            "This is an HTML export. In Notion, choose Export › Markdown & CSV and try again."
        case .unreadableArchive(let name):
            "“\(name)” couldn't be opened. Unzip it in Finder and choose the folder instead."
        }
    }
}

extension NoteStore {
    /// Creates a note through the normal creation path (search index, tags, revision, sync), then
    /// stamps it with the source's dates.
    @discardableResult
    func createImportedNote(body: NSAttributedString, title: String, notebookID: UUID?,
                            createdAt: Date?, updatedAt: Date?, id: UUID? = nil) -> NoteMeta {
        var text = body
        if body.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !title.isEmpty {
            text = EditorStyle.paragraph(title, kind: .title)
        }
        var meta = createNote(in: notebookID, initial: text, id: id)
        if let index = noteIndex(meta.id) {
            let updated = updatedAt ?? createdAt ?? meta.updatedAt
            notes[index].createdAt = min(createdAt ?? updated, updated)
            notes[index].updatedAt = updated
            meta = notes[index]
        }
        return meta
    }

    /// Replaces the body of a note made by an import, keeping its imported dates.
    func replaceImportedBody(_ id: UUID, _ body: NSAttributedString) {
        guard let updated = note(with: id)?.updatedAt else { return }
        updateBody(id, body)
        if let index = noteIndex(id) { notes[index].updatedAt = updated }
    }

    /// Links to notes that a cancel or an unreadable file kept out of an import become title links, so no link
    /// points at a note that doesn't exist. `planned` maps each id handed out before the import to its title.
    func unresolveLinksToSkipped(in createdIDs: [UUID], planned: [UUID: String]) {
        let missing = planned.filter { note(with: $0.key) == nil }
        guard !missing.isEmpty else { return }
        rewriteNoteLinks(in: createdIDs) { link in
            guard case let .note(target, heading) = link, let title = missing[target] else { return nil }
            return .unresolved(title: title, heading: heading)
        }
    }

    /// Title links in `createdIDs` that name a note in `titles` (folded title → id) point at that note; other
    /// title links are left as they are.
    func resolveTitleLinks(in createdIDs: [UUID], titles: [String: UUID]) {
        guard !titles.isEmpty else { return }
        rewriteNoteLinks(in: createdIDs) { link in
            guard case let .unresolved(title, heading) = link,
                  let id = titles[TextFold.fold(title.trimmingCharacters(in: .whitespacesAndNewlines))],
                  note(with: id) != nil else { return nil }
            return .note(id: id, heading: heading)
        }
    }

    /// Replaces each note link `change` returns a new link for, keeping the imported dates.
    private func rewriteNoteLinks(in ids: [UUID], _ change: (NoteLink) -> NoteLink?) {
        for id in ids where note(with: id) != nil {
            let body = NSMutableAttributedString(attributedString: self.body(for: id))
            var changed = false
            body.enumerateAttribute(.link, in: NSRange(location: 0, length: body.length)) { value, range, _ in
                guard let url = value as? URL, let link = NoteLink(url: url), let new = change(link) else { return }
                body.addAttribute(.link, value: new.clamped.url, range: range)
                changed = true
            }
            if changed { replaceImportedBody(id, body) }
        }
    }

    /// An existing notebook with this name (ignoring case) among the children of `parentID`, or a new one there.
    func notebookForImport(named name: String, parentID: UUID? = nil) -> Notebook {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tree = notebookTree
        if let existing = notebooks.first(where: {
            tree.effectiveParent(of: $0.id) == parentID
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing
        }
        let palette = NotebookPalette.colors
        let color = palette.isEmpty ? Tokens.Hex.notebookBlue : palette[notebooks.count % palette.count]
        return createNotebook(name: trimmed.isEmpty ? "Imported" : trimmed, symbol: "folder", colorHex: color, parentID: parentID)
    }

    /// Nested notebooks for a folder path, up to the deepest level allowed; deeper folders are named
    /// `Folder / Subfolder` inside the deepest notebook.
    func notebookForImport(path: [String]) -> Notebook {
        let names = path.isEmpty ? ["Imported"] : path
        let nested = Array(names.prefix(NotebookTree.maxDepth - 1))
            + [names.dropFirst(NotebookTree.maxDepth - 1).joined(separator: " / ")].filter { !$0.isEmpty }
        var notebook = notebookForImport(named: nested[0])
        for name in nested.dropFirst() { notebook = notebookForImport(named: name, parentID: notebook.id) }
        return notebook
    }
}

/// Tag names from other apps written in NoteIt's tag grammar.
enum ImportTags {
    /// `name` as a NoteIt tag without `#`: spaces and punctuation become `-`, a segment that doesn't start with a
    /// letter gets a leading `_`, and levels past the fifth join the fifth. Nil when nothing usable is left.
    static func sanitized(_ name: String) -> String? {
        var segments = name.split(separator: "/").compactMap { segment($0) }
        guard !segments.isEmpty else { return nil }
        if segments.count > TokenGrammar.maxTagDepth {
            let tail = segments[(TokenGrammar.maxTagDepth - 1)...].joined(separator: "-")
            segments = Array(segments.prefix(TokenGrammar.maxTagDepth - 1)) + [tail]
        }
        let tag = TokenGrammar.normalizedTag(segments.joined(separator: "/"))
        return TokenGrammar.isValidTagName(tag) ? tag : nil
    }

    /// A line of hashtags for `names`, leaving out tags `body` already has; nil when none are left.
    static func line(for names: [String], excluding body: NSAttributedString) -> String? {
        var seen = Set(NoteStore.parseTags(body))
        let tags = names.compactMap(sanitized).filter { seen.insert($0).inserted }
        return tags.isEmpty ? nil : tags.map { "#" + $0 }.joined(separator: " ")
    }

    private static func segment(_ raw: Substring) -> String? {
        var out = String.UnicodeScalarView()
        var dash = false
        for scalar in raw.unicodeScalars {
            let kept = CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
                || scalar.properties.numericType != nil || scalar == "_"
            if kept {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.append(scalar)
            } else {
                dash = true
            }
        }
        guard let first = out.first else { return nil }
        let startsWell = first == "_" || (CharacterSet.letters.contains(first) && !CharacterSet.nonBaseCharacters.contains(first))
        return startsWell ? String(out) : "_" + String(out)
    }
}
