import AppKit

/// Progress and results of one import run.
struct ImportReport: Equatable {
    var notesImported = 0
    var notebookIDs: Set<UUID> = []
    var lockedSkipped = 0
    var attachmentsSkipped = 0
    var filesSkipped = 0
    var notesSkipped = 0
    var cancelled = false
    /// Notes stopped answering because NoteIt's permission was turned off during the import.
    var permissionDenied = false

    var notebooksUsed: Int { notebookIDs.count }

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

    var errorDescription: String? {
        switch self {
        case .notesPermissionDenied:
            "NoteIt isn't allowed to read your notes from the Notes app. Turn on Notes for NoteIt in System Settings › Privacy & Security › Automation, then try again."
        case .notesUnavailable(let detail):
            "Couldn't read from the Notes app. \(detail)"
        case .nothingToImport:
            "No notes were found to import."
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

    /// An existing notebook with this name (ignoring case), or a new one.
    func notebookForImport(named name: String) -> Notebook {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = notebooks.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing
        }
        let palette = NotebookPalette.colors
        let color = palette.isEmpty ? Tokens.Hex.notebookBlue : palette[notebooks.count % palette.count]
        return createNotebook(name: trimmed.isEmpty ? "Imported" : trimmed, symbol: "folder", colorHex: color)
    }
}
