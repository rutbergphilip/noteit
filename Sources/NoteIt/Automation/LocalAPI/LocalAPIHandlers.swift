import Foundation
import NoteItAPI
import NoteItCore

/// The Local API routes the server doesn't answer itself (automation spec §6.10). Every call into
/// `AutomationService` runs on the main actor.
final class LocalAPIHandlers: LocalAPIResponder, @unchecked Sendable {
    static let defaultLimit = 50
    static let maxLimit = 500

    let service: AutomationService
    let registry: LocalAPIRouteRegistry
    private let openNote: @MainActor (UUID) throws -> Void

    init(service: AutomationService, registry: LocalAPIRouteRegistry = .shared,
         openNote: (@MainActor (UUID) throws -> Void)? = nil) {
        self.service = service
        self.registry = registry
        self.openNote = openNote ?? { [unowned service] id in try service.open(id) }
    }

    func respond(_ context: LocalAPIContext) async -> HTTPResponse {
        guard let route = RouteID(rawValue: context.route.spec.id) else {
            return .error(.notFound, "Not found.")
        }
        do {
            return try await handle(route, context)
        } catch let failure as Failure {
            return failure.response
        } catch let error as AutomationError {
            return await response(for: error, context)
        } catch {
            return .error(.internal, "Something went wrong.")
        }
    }

    // MARK: - Routes

    @MainActor
    private func handle(_ route: RouteID, _ context: LocalAPIContext) async throws -> HTTPResponse {
        let request = context.request
        if route == .daily || route == .dailyAppend {
            return .error(.notImplemented, AutomationError.dailyNotesUnavailable.message)
        }
        try service.ensureReady()
        switch route {
        case .notesList:
            let query = request.query
            let page = try service.list(notebook: query["notebook"].map(Self.notebookRef), tag: query["tag"], query: query["q"],
                                        updatedSince: try Self.date(query["updatedSince"], name: "updatedSince"),
                                        deleted: try Self.deletedFilter(query["deleted"]), sort: try Self.sort(query["sort"]),
                                        limit: try Self.limit(query["limit"]), cursor: query["cursor"])
            return .json(Page(items: page.notes.map(summary), nextCursor: page.nextCursor))

        case .noteCreate:
            let body = try Self.decode(CreateNoteRequest.self, request)
            let format = body.format ?? .markdown
            let notebook: NotebookRef? = body.notebookID.map(NotebookRef.id) ?? body.notebook.map(NotebookRef.name)
            let meta = try service.create(title: body.title, body: body.body, format: format, notebook: notebook,
                                          tags: body.tags ?? [], pinned: body.pinned ?? false)
            return try noteResponse(meta, format: format, status: 201)

        case .noteGet:
            let id = try Self.noteID(context)
            let format = try Self.format(request.query["format"]) ?? .markdown
            return try noteResponse(try service.note(id), format: format)

        case .notePatch:
            let id = try Self.noteID(context)
            let body = try Self.decode(PatchNoteRequest.self, request)
            let ifRevision = try Self.ifMatch(request.headers["If-Match"])
            let format = body.format ?? .markdown
            let meta = try await service.patch(id, title: body.title, body: body.body.map { ($0, format) },
                                               notebookID: body.notebookID.map { .some($0) }, pinned: body.pinned,
                                               ifRevision: ifRevision)
            return try noteResponse(meta, format: format, summaryIfLocked: true)

        case .noteDelete:
            let id = try Self.noteID(context)
            if request.query["permanent"].map(Self.isTrue) == true {
                try Self.requireAdmin(context)
                try service.deletePermanently(id)
            } else {
                try service.moveToRecentlyDeleted(id)
            }
            return HTTPResponse(status: 204)

        case .noteRestore:
            let meta = try service.restore(try Self.noteID(context))
            return try noteResponse(meta, format: .markdown, summaryIfLocked: true)

        case .noteAppend:
            let id = try Self.noteID(context)
            let body = try Self.decode(AppendRequest.self, request)
            let format = body.format ?? .text
            guard format == .text || format == .markdown else {
                throw Failure(.badRequest, "Append takes text or markdown.")
            }
            let meta = try await service.append(id, text: body.text, format: format, position: body.position ?? .end,
                                                timestamp: body.timestamp ?? false, ifRevision: body.ifRevision)
            return try noteResponse(meta, format: .markdown)

        case .noteOpen:
            try openNote(try Self.noteID(context))
            return HTTPResponse(status: 204)

        case .attachmentsList:
            return .json(try service.attachments(of: try Self.noteID(context)))

        case .attachmentGet:
            let id = try Self.noteID(context)
            guard let name = context.route.params["name"] else { throw AutomationError.notFound }
            let file = try service.attachment(of: id, named: name)
            return HTTPResponse(status: 200, headers: HTTPHeaders([("Content-Type", file.contentType)]), body: file.data)

        case .attachmentAdd:
            let id = try Self.noteID(context)
            let meta = try service.addAttachment(to: id, data: request.body, filename: Self.filename(request),
                                                 contentType: Self.contentType(request))
            return try noteResponse(meta, format: .markdown)

        case .stagedUpload:
            return .json(try service.staged.stage(request.body), status: 201)

        case .trashEmpty:
            try Self.requireAdmin(context)
            service.emptyRecentlyDeleted()
            return HTTPResponse(status: 204)

        case .search:
            return try await search(context)

        case .notebooksList:
            let notebooks = service.notebooks().map { notebookDTO($0.0, noteCount: $0.noteCount) }
            return .json(NotebooksResponseDTO(notebooks: notebooks, defaultNotebookID: service.defaultNotebookID))

        case .notebookCreate:
            let body = try Self.decode(NotebookRequest.self, request)
            guard let name = body.name else { throw Failure(.badRequest, "A notebook needs a name.") }
            let notebook = try service.createNotebook(name: name, symbol: body.symbol, color: body.color)
            return .json(notebookDTO(notebook, noteCount: 0), status: 201)

        case .notebookPatch:
            let id = try Self.notebookID(context)
            let body = try Self.decode(NotebookRequest.self, request)
            let notebook = try service.updateNotebook(id, name: body.name, symbol: body.symbol, color: body.color)
            let count = service.notebooks().first { $0.0.id == id }?.noteCount ?? 0
            return .json(notebookDTO(notebook, noteCount: count))

        case .notebookDelete:
            try service.deleteNotebook(try Self.notebookID(context))
            return HTTPResponse(status: 204)

        case .tags:
            if request.query["tree"].map(Self.isTrue) == true {
                guard let provider = registry.tagTreeProvider else {
                    throw Failure(.notImplemented, "The tag tree isn't available in this version.")
                }
                return .json(provider())
            }
            return .json(service.tags().map { TagDTO(name: $0.name, noteCount: $0.count) })

        default:
            return .error(.notFound, "Not found.")
        }
    }

    @MainActor
    private func search(_ context: LocalAPIContext) async throws -> HTTPResponse {
        let query = context.request.query
        guard let q = query["q"], !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(.badRequest, "Search needs q.")
        }
        let limit = try Self.limit(query["limit"])
        let mode = query["mode"] ?? "keyword"
        if mode == "keyword" {
            let results = try service.search(q, notebook: query["notebook"].map(Self.notebookRef), tag: query["tag"], limit: limit)
            return .json(SearchResponseDTO(mode: mode, results: results.map { SearchResultDTO(note: summary($0.0), snippet: $0.snippet) }))
        }
        guard let handler = registry.searchMode(mode) else {
            throw Failure(.badRequest, "There's no search mode called \(mode).")
        }
        let request = SearchQuery(q: q, notebook: query["notebook"], tag: query["tag"], limit: limit)
        switch await handler(request, context) {
        case .success(let results):
            return .json(SearchResponseDTO(mode: mode, results: results))
        case .failure(let code):
            return .error(code, code == .notAvailable ? "The \(mode) search mode is turned off." : "The \(mode) search failed.")
        }
    }

    // MARK: - DTOs

    @MainActor
    func summary(_ meta: NoteMeta) -> NoteSummaryDTO {
        NoteSummaryDTO(id: meta.id, title: meta.title, notebookID: meta.notebookID,
                       notebookName: meta.notebookID.flatMap { service.store.notebook(with: $0)?.name }, tags: meta.tags,
                       pinned: meta.isPinned, createdAt: meta.createdAt, updatedAt: meta.updatedAt, revision: meta.revision,
                       deletedAt: meta.deletedAt, preview: meta.isLocked ? "" : meta.preview,
                       conflict: meta.conflictSource != nil || meta.conflictOriginalID != nil, locked: meta.isLocked,
                       url: AutomationService.link(for: meta.id).absoluteString)
    }

    /// A locked note has no readable body; writes that never touch it (pin, move, restore) answer with its summary.
    @MainActor
    private func noteResponse(_ meta: NoteMeta, format: BodyFormatDTO, status: Int = 200,
                              summaryIfLocked: Bool = false) throws -> HTTPResponse {
        if meta.isLocked, summaryIfLocked {
            return .json(summary(meta), status: status)
        }
        let body = try service.body(meta.id, format: format)
        return .json(NoteDTO(summary: summary(meta), format: format, body: body), status: status)
    }

    @MainActor
    private func notebookDTO(_ notebook: Notebook, noteCount: Int) -> NotebookDTO {
        var dto = NotebookDTO(id: notebook.id, name: notebook.name, symbol: notebook.symbol, color: notebook.colorHex,
                              sortIndex: notebook.sortIndex, noteCount: noteCount)
        for extender in registry.notebookExtenders {
            extender.extend(&dto, notebookID: notebook.id)
        }
        return dto
    }

    private struct RevisionMismatchBody: Encodable {
        var error: APIErrorBody.Inner
        var current: NoteSummaryDTO
    }

    /// `412 revision_mismatch` carries the note as it is now in `current`.
    @MainActor
    private func response(for error: AutomationError, _ context: LocalAPIContext) -> HTTPResponse {
        if case .revisionMismatch = error, let id = try? Self.noteID(context), let meta = try? service.note(id) {
            let body = RevisionMismatchBody(error: .init(code: .revisionMismatch, message: error.message), current: summary(meta))
            return .json(body, status: APIErrorCode.revisionMismatch.httpStatus)
        }
        return .error(error.apiCode, error.message)
    }

    // MARK: - Request parsing

    struct Failure: Error {
        let code: APIErrorCode
        let message: String

        init(_ code: APIErrorCode, _ message: String) {
            self.code = code
            self.message = message
        }

        var response: HTTPResponse { .error(code, message) }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) throws -> T {
        do {
            return try APIJSON.decoder().decode(type, from: request.body)
        } catch {
            throw Failure(.badRequest, "The request body isn't valid JSON for this route.")
        }
    }

    static func noteID(_ context: LocalAPIContext) throws -> UUID {
        guard let id = context.route.params["id"].flatMap(UUID.init(uuidString:)) else { throw AutomationError.notFound }
        return id
    }

    static func notebookID(_ context: LocalAPIContext) throws -> UUID {
        guard let id = context.route.params["id"].flatMap(UUID.init(uuidString:)) else { throw AutomationError.notebookNotFound }
        return id
    }

    static func notebookRef(_ value: String) -> NotebookRef {
        UUID(uuidString: value).map(NotebookRef.id) ?? .name(value)
    }

    static func limit(_ value: String?) throws -> Int {
        guard let value else { return defaultLimit }
        guard let limit = Int(value), limit > 0 else { throw Failure(.badRequest, "limit must be a whole number from 1.") }
        return min(limit, maxLimit)
    }

    static func date(_ value: String?, name: String) throws -> Date? {
        guard let value else { return nil }
        guard let json = try? JSONEncoder().encode(value), let date = try? APIJSON.decoder().decode(Date.self, from: json) else {
            throw Failure(.badRequest, "\(name) must be an ISO 8601 date.")
        }
        return date
    }

    static func deletedFilter(_ value: String?) throws -> DeletedFilter {
        switch value {
        case nil: return .exclude
        case "only": return .only
        case "include": return .include
        default: throw Failure(.badRequest, "deleted must be only or include.")
        }
    }

    static func sort(_ value: String?) throws -> ListSort {
        switch value {
        case nil, "list": return .list
        case "updated": return .updated
        default: throw Failure(.badRequest, "sort must be list or updated.")
        }
    }

    static func format(_ value: String?) throws -> BodyFormatDTO? {
        guard let value else { return nil }
        guard let format = BodyFormatDTO(rawValue: value) else {
            throw Failure(.badRequest, "format must be markdown, text, html or noteit-doc.")
        }
        return format
    }

    /// `"<revision>"`, `W/"<revision>"` or a bare revision.
    static func ifMatch(_ value: String?) throws -> UUID? {
        guard var text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("W/") { text.removeFirst(2) }
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let revision = UUID(uuidString: trimmed) else { throw Failure(.badRequest, "If-Match must be a note revision.") }
        return revision
    }

    static func isTrue(_ value: String) -> Bool {
        ["true", "1", "yes"].contains(value.lowercased())
    }

    static func filename(_ request: HTTPRequest) -> String {
        guard let raw = request.headers["X-NoteIt-Filename"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return "attachment"
        }
        return raw.removingPercentEncoding ?? raw
    }

    static func contentType(_ request: HTTPRequest) -> String {
        let value = request.headers["Content-Type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? "application/octet-stream" : value.lowercased()
    }

    static func requireAdmin(_ context: LocalAPIContext) throws {
        guard context.client?.scopes.contains(where: { $0.allows(.admin) }) == true else {
            throw Failure(.forbiddenScope, "This needs the admin scope.")
        }
    }
}
