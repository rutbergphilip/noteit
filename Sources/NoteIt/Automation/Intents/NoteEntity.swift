import AppIntents
import Foundation
import NoteItCore

struct NoteEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static var defaultQuery = NoteEntityQuery()

    var id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Notebook")
    var notebookName: String?

    @Property(title: "Tags")
    var tags: [String]

    @Property(title: "Created")
    var createdAt: Date

    @Property(title: "Modified")
    var modifiedAt: Date

    init(meta: NoteMeta, notebookName: String?) {
        id = meta.id
        title = meta.displayTitle
        self.notebookName = notebookName
        tags = meta.tags
        createdAt = meta.createdAt
        modifiedAt = meta.updatedAt
    }

    var displayRepresentation: DisplayRepresentation {
        if let notebookName {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(notebookName)")
        }
        return DisplayRepresentation(title: "\(title)")
    }
}

struct NoteEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [NoteEntity] {
        AutomationService.shared.noteEntities(for: identifiers)
    }

    @MainActor
    func entities(matching string: String) async throws -> [NoteEntity] {
        try IntentError.run { () throws(AutomationError) in try AutomationService.shared.noteEntities(matching: string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [NoteEntity] {
        AutomationService.shared.suggestedNoteEntities()
    }
}

struct NotebookEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Notebook"
    static var defaultQuery = NotebookEntityQuery()

    var id: UUID

    @Property(title: "Name")
    var name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct NotebookEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [NotebookEntity] {
        let wanted = Set(identifiers)
        return AutomationService.shared.notebookEntities().filter { wanted.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [NotebookEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = AutomationService.shared.notebookEntities()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @MainActor
    func suggestedEntities() async throws -> [NotebookEntity] {
        AutomationService.shared.notebookEntities()
    }
}

/// Shortcuts shows an error's `errorDescription`, so automation errors keep their wording there.
struct IntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ error: AutomationError) {
        message = error.message
    }

    @MainActor
    static func run<T>(_ body: () throws(AutomationError) -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw IntentError(error)
        }
    }

    @MainActor
    static func run<T>(_ body: () async throws(AutomationError) -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw IntentError(error)
        }
    }
}

extension AutomationService {
    static let suggestedNoteCount = 10

    func noteEntity(_ meta: NoteMeta) -> NoteEntity {
        NoteEntity(meta: visible(meta), notebookName: meta.notebookID.flatMap { store.notebook(with: $0)?.name })
    }

    /// The notes with these ids, in that order, leaving out unknown ones and any in Recently Deleted.
    func noteEntities(for ids: [UUID]) -> [NoteEntity] {
        ids.compactMap { store.note(with: $0) }.filter { $0.deletedAt == nil }.map(noteEntity)
    }

    /// The note list's search; an empty string gives the suggestions.
    func noteEntities(matching text: String) throws(AutomationError) -> [NoteEntity] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return suggestedNoteEntities() }
        return try search(text, notebook: nil, tag: nil, limit: Self.maxListLimit).map { noteEntity($0.0) }
    }

    func suggestedNoteEntities() -> [NoteEntity] {
        store.notes(for: .allNotes, search: "")
            .filter { $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.suggestedNoteCount)
            .map(noteEntity)
    }

    func notebookEntities() -> [NotebookEntity] {
        store.sortedNotebooks.map { NotebookEntity(id: $0.id, name: $0.name) }
    }
}
