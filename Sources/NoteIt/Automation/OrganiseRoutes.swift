import Foundation
import NoteItAPI
import NoteItCore

/// Organise's Local API routes (organise spec §8), plus the tag tree and notebook fields filled through the
/// registry's seams. Handlers call the same `NoteStore` methods as the app.
enum OrganiseRoutes {
    static let routes: [RouteSpec] = [
        spec("tagRename", .POST, "/v1/tags/rename", .write, "Rename a tag in every note; renaming into an existing tag merges"),
        spec("tagDelete", .POST, "/v1/tags/delete", .write, "Remove a tag from every note"),
        spec("notebookMove", .POST, "/v1/notebooks/{id}/move", .write, "Move a notebook into another notebook or to the top level"),
        spec("smartFolderList", .GET, "/v1/smart-folders", .read, "Smart folders in sidebar order"),
        spec("smartFolderCreate", .POST, "/v1/smart-folders", .write, "Create a smart folder"),
        spec("smartFolderGet", .GET, "/v1/smart-folders/{id}", .read, "A smart folder and the notes it finds"),
        spec("smartFolderUpdate", .PATCH, "/v1/smart-folders/{id}", .write, "Change a smart folder's name, search or symbol"),
        spec("smartFolderDelete", .DELETE, "/v1/smart-folders/{id}", .write, "Delete a smart folder; its notes aren't touched"),
        spec("taskList", .GET, "/v1/tasks", .read, "Tasks across notes, grouped by due date"),
        spec("taskComplete", .POST, "/v1/tasks/complete", .write, "Check or uncheck a task"),
        spec("taskDue", .POST, "/v1/tasks/due", .write, "Set or remove a task's due date"),
    ]

    private static func spec(_ name: String, _ method: HTTPMethod, _ pattern: String, _ scope: APIScope,
                             _ summary: String) -> RouteSpec {
        let hasBody = method == .POST || method == .PATCH
        return RouteSpec(id: "organise.\(name)", method: method, pattern: pattern, scope: scope, body: hasBody ? .json : .none,
                         bucket: scope == .write ? .write : .general, maxBodyBytes: nil, summary: summary)
    }

    static let defaultNoteLimit = 100

    @MainActor
    static func register(in registry: LocalAPIRouteRegistry, store: NoteStore) {
        for spec in routes {
            let id = spec.id
            registry.register(spec) { context in
                await respond(id, context, store: store)
            }
        }
        registry.extendTags { tagTree(store) }
        registry.extendNotebooks(with: NotebookExtender(store: store))
    }

    @MainActor
    static func tagTree(_ store: NoteStore) -> [TagNodeDTO] {
        func dto(_ node: TagNode) -> TagNodeDTO {
            TagNodeDTO(name: node.name, path: node.path, noteCount: node.ownCount, totalCount: node.totalCount,
                       children: node.children.map(dto))
        }
        return store.tagTree.map(dto)
    }

    final class NotebookExtender: NotebookDTOExtending, @unchecked Sendable {
        private weak var store: NoteStore?

        init(store: NoteStore) {
            self.store = store
        }

        @MainActor
        func extend(_ dto: inout NotebookDTO, notebookID: UUID) {
            guard let store else { return }
            let tree = store.notebookTree
            dto.parentID = tree.effectiveParent(of: notebookID)
            dto.path = tree.path(of: notebookID)
        }
    }

    private struct Failure: Error {
        var code: APIErrorCode
        var message: String
    }

    @MainActor
    static func respond(_ routeID: String, _ context: LocalAPIContext, store: NoteStore) async -> HTTPResponse {
        do {
            guard !store.isLoading else { throw Failure(code: .notReady, message: "The library is still loading.") }
            switch routeID {
            case "organise.tagRename":
                let request = try decode(TagRenameRequest.self, context, hint: "Send a JSON object with from and to.")
                if let problem = TagRewriter.renameProblem(from: request.from, to: request.to, tags: store.tagsInUse) {
                    throw Failure(code: .badRequest, message: problem)
                }
                try requireTag(request.from, store: store)
                return .json(tagEditResponse(await store.renameTag(request.from, to: request.to)))
            case "organise.tagDelete":
                let request = try decode(TagDeleteRequest.self, context, hint: "Send a JSON object with a tag.")
                try requireTag(request.tag, store: store)
                return .json(tagEditResponse(await store.deleteTag(request.tag)))
            case "organise.notebookMove":
                return try moveNotebook(context, store: store)
            case "organise.smartFolderList":
                return .json(SmartFoldersResponseDTO(smartFolders: store.sortedSmartFolders.map(smartFolderDTO)))
            case "organise.smartFolderCreate":
                let request = try decode(SmartFolderRequest.self, context, hint: "Send a JSON object with a name and a query.")
                let symbol = try validSymbol(request.symbol) ?? SmartFolder.defaultSymbol
                try validQuery(request.query)
                let folder = try smartFolderEdit {
                    try store.createSmartFolder(name: request.name ?? "", query: request.query ?? "", symbol: symbol)
                }
                return .json(smartFolderDTO(folder), status: 201)
            case "organise.smartFolderGet":
                let folder = try smartFolder(context, store: store)
                let limit = try noteLimit(context.request.query["limit"])
                let notes = store.searchResults(for: .smartFolder(folder.id), search: "", order: .dateEdited, decorated: false)
                return .json(SmartFolderNotesDTO(smartFolder: smartFolderDTO(folder),
                                                 notes: notes.prefix(limit).map { summary($0.note, store: store) }))
            case "organise.smartFolderUpdate":
                let folder = try smartFolder(context, store: store)
                let request = try decode(SmartFolderRequest.self, context, hint: "Send a JSON object with a name, query or symbol.")
                let symbol = try validSymbol(request.symbol) ?? folder.symbol
                try validQuery(request.query)
                try smartFolderEdit {
                    try store.updateSmartFolder(folder.id, name: request.name ?? folder.name, query: request.query ?? folder.query,
                                                symbol: symbol)
                }
                return .json(smartFolderDTO(store.smartFolder(with: folder.id) ?? folder))
            case "organise.smartFolderDelete":
                let folder = try smartFolder(context, store: store)
                store.deleteSmartFolder(folder.id)
                return HTTPResponse(status: 204)
            case "organise.taskList":
                let query = context.request.query
                let includeCompleted = query["includeCompleted"].map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
                let groups = store.tasks(query: query["q"] ?? "", includeCompleted: includeCompleted)
                let dtos = TaskGroup.allCases.compactMap { group -> TaskGroupDTO? in
                    guard let items = groups[group], !items.isEmpty else { return nil }
                    return TaskGroupDTO(group: name(of: group), tasks: items.map { taskDTO($0.line, noteID: $0.ref.noteID, store: store) })
                }
                return .json(TasksResponseDTO(groups: dtos))
            case "organise.taskComplete":
                let request = try decode(TaskCompleteRequest.self, context,
                                         hint: "Send a JSON object with noteID, paragraph, textHash and checked.")
                let ref = TaskRef(noteID: request.noteID, paragraph: request.paragraph, textHash: request.textHash)
                let paragraph = try bodyEdit { try store.setTaskChecked(ref, request.checked) }
                return .json(try updatedTask(noteID: ref.noteID, paragraph: paragraph, store: store))
            case "organise.taskDue":
                let request = try decode(TaskDueRequest.self, context,
                                         hint: "Send a JSON object with noteID, paragraph, textHash and due.")
                let due = try request.due.map(parseDue)
                let ref = TaskRef(noteID: request.noteID, paragraph: request.paragraph, textHash: request.textHash)
                let paragraph = try bodyEdit { try store.setDue(ref, due) }
                return .json(try updatedTask(noteID: ref.noteID, paragraph: paragraph, store: store))
            default:
                return .error(.notFound, "Not found.")
            }
        } catch let failure as Failure {
            return .error(failure.code, failure.message)
        } catch {
            return .error(.internal, "Something went wrong.")
        }
    }

    // MARK: - Tags

    @MainActor
    private static func requireTag(_ tag: String, store: NoteStore) throws {
        guard !store.notesTagged(tag).isEmpty else { throw Failure(code: .notFound, message: "No notes have that tag.") }
    }

    private static func tagEditResponse(_ result: TagEditResult) -> TagEditResponseDTO {
        TagEditResponseDTO(changed: result.changed.keys.sorted { $0.uuidString < $1.uuidString },
                           skipped: result.skipped.sorted { $0.key.uuidString < $1.key.uuidString }
                               .map { SkippedNoteDTO(noteID: $0.key, reason: code(for: $0.value).rawValue) })
    }

    // MARK: - Notebooks

    @MainActor
    private static func moveNotebook(_ context: LocalAPIContext, store: NoteStore) throws -> HTTPResponse {
        guard let raw = context.route.params["id"], let id = UUID(uuidString: raw), store.notebook(with: id) != nil else {
            throw Failure(code: .notFound, message: "No notebook with that ID.")
        }
        let request = try decode(NotebookMoveRequest.self, context, hint: "Send a JSON object with parentID and an optional index.")
        if let parent = request.parentID, store.notebook(with: parent) == nil {
            throw Failure(code: .notFound, message: "No notebook with that parent ID.")
        }
        if let index = request.index, index < 0 { throw Failure(code: .badRequest, message: "index can't be negative.") }
        guard store.moveNotebook(id, under: request.parentID, at: request.index), let moved = store.notebook(with: id) else {
            throw Failure(code: .badRequest,
                          message: "A notebook can't move into itself or its own notebooks, or deeper than four levels.")
        }
        let count = store.activeNotes.lazy.filter { $0.notebookID == id }.count
        let tree = store.notebookTree
        return .json(NotebookDTO(id: moved.id, name: moved.name, symbol: moved.symbol, color: moved.colorHex,
                                 sortIndex: moved.sortIndex, noteCount: count, parentID: tree.effectiveParent(of: id),
                                 path: tree.path(of: id)))
    }

    // MARK: - Smart folders

    @MainActor
    private static func smartFolder(_ context: LocalAPIContext, store: NoteStore) throws -> SmartFolder {
        guard let raw = context.route.params["id"], let id = UUID(uuidString: raw), let folder = store.smartFolder(with: id) else {
            throw Failure(code: .notFound, message: "No smart folder with that ID.")
        }
        return folder
    }

    private static func smartFolderDTO(_ folder: SmartFolder) -> SmartFolderDTO {
        SmartFolderDTO(id: folder.id, name: folder.name, query: folder.query, symbol: folder.symbol, sortIndex: folder.sortIndex)
    }

    @discardableResult
    private static func smartFolderEdit<T>(_ edit: () throws -> T) throws -> T {
        do {
            return try edit()
        } catch let error as SmartFolderError {
            throw Failure(code: error == .notFound ? .notFound : .badRequest, message: SmartFolderEditSheet.message(for: error))
        }
    }

    private static func validQuery(_ query: String?) throws {
        if let query, let issue = SearchQuery.parse(query).issues.first {
            throw Failure(code: .badRequest, message: issue.message)
        }
    }

    @MainActor
    private static func validSymbol(_ symbol: String?) throws -> String? {
        do {
            return try AutomationService.symbol(symbol)
        } catch {
            throw Failure(code: .badRequest, message: "That symbol isn't valid.")
        }
    }

    @MainActor
    private static func noteLimit(_ raw: String?) throws -> Int {
        guard let raw else { return defaultNoteLimit }
        guard let value = Int(raw), (1...AutomationService.maxListLimit).contains(value) else {
            throw Failure(code: .badRequest, message: "limit must be between 1 and \(AutomationService.maxListLimit).")
        }
        return value
    }

    // MARK: - Tasks

    static func name(of group: TaskGroup) -> String {
        switch group {
        case .overdue: "overdue"
        case .today: "today"
        case .upcoming: "upcoming"
        case .later: "later"
        case .noDate: "noDate"
        case .completed: "completed"
        }
    }

    @MainActor
    private static func taskDTO(_ line: TaskLine, noteID: UUID, store: NoteStore) -> TaskDTO {
        let meta = store.note(with: noteID)
        return TaskDTO(noteID: noteID, noteTitle: meta?.displayTitle ?? "", notebookID: meta?.notebookID,
                       paragraph: line.paragraph, textHash: line.textHash, text: TaskParser.displayText(line.text),
                       checked: line.checked, due: line.due?.token, remind: line.remindDone ? nil : line.remind?.token,
                       url: AutomationService.link(for: noteID).absoluteString)
    }

    /// The task as it reads after an edit, parsed from the saved body (the index catches up later).
    @MainActor
    private static func updatedTask(noteID: UUID, paragraph: Int, store: NoteStore) throws -> TaskDTO {
        let masked = NoteStore.maskedForTokens(store.body(for: noteID))
        guard let line = TaskParser.parse(masked: masked).tasks.first(where: { $0.paragraph == paragraph }) else {
            throw Failure(code: .revisionMismatch, message: "That task changed. Fetch the tasks again.")
        }
        return taskDTO(line, noteID: noteID, store: store)
    }

    private static func parseDue(_ raw: String) throws -> LocalDateTime {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
        guard let due = LocalDateTime(token: text) else {
            throw Failure(code: .badRequest, message: "Dates look like 2026-10-21 or 2026-10-21 14:00.")
        }
        return due
    }

    private static func bodyEdit<T>(_ edit: () throws -> T) throws -> T {
        do {
            return try edit()
        } catch let error as BodyEditError {
            throw Failure(code: code(for: error), message: message(for: error))
        }
    }

    static func code(for error: BodyEditError) -> APIErrorCode {
        switch error {
        case .noteMissing: .notFound
        case .inTrash: .noteDeleted
        case .locked: .noteLocked
        case .writeBlocked: .noteUnreadable
        case .taskChanged: .revisionMismatch
        case .versionNotSaved: .internal
        case .folderNotAvailable: .notReady
        }
    }

    private static func message(for error: BodyEditError) -> String {
        switch error {
        case .noteMissing: "No note with that ID."
        case .inTrash: "That note is in Recently Deleted."
        case .locked: "That note is locked."
        case .writeBlocked: "That note can't be read, so it can't be changed."
        case .taskChanged: "That task changed. Fetch the tasks again."
        case .versionNotSaved: "Something went wrong."
        case .folderNotAvailable(let folder): BodyEditError.folderNotAvailableMessage(folder)
        }
    }

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ type: T.Type, _ context: LocalAPIContext, hint: String) throws -> T {
        guard let value = try? APIJSON.decoder().decode(type, from: context.request.body) else {
            throw Failure(code: .badRequest, message: hint)
        }
        return value
    }

    @MainActor
    private static func summary(_ meta: NoteMeta, store: NoteStore) -> NoteSummaryDTO {
        NoteSummaryDTO(id: meta.id, title: meta.title, notebookID: meta.notebookID,
                       notebookName: meta.notebookID.flatMap { store.notebook(with: $0)?.name }, tags: meta.tags,
                       pinned: meta.isPinned, createdAt: meta.createdAt, updatedAt: meta.updatedAt, revision: meta.revision,
                       deletedAt: meta.deletedAt, preview: meta.isLocked ? "" : meta.preview,
                       conflict: meta.conflictSource != nil || meta.conflictOriginalID != nil, locked: meta.isLocked,
                       url: AutomationService.link(for: meta.id).absoluteString)
    }
}
