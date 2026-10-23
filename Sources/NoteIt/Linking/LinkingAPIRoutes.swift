import Foundation
import NoteItAPI
import NoteItCore

/// Linking's Local API routes (spec §15). Body-derived answers for a locked note are `423 note_locked`.
enum LinkingAPIRoutes {
    struct LinkDTO: Codable, Equatable {
        var text: String
        var context: String
        /// UTF-16 offset in the source note's body.
        var location: Int
        /// `noteit://note/<UUID>` of the target; nil when the link doesn't resolve to a live note.
        var url: String?
        var noteID: UUID?
        var heading: String?
        /// The title written in an unresolved link.
        var unresolvedTitle: String?
    }

    struct BacklinkDTO: Codable, Equatable {
        var noteID: UUID
        var title: String
        var url: String
        var notebookID: UUID?
        var notebookName: String?
        var updatedAt: Date
        var links: [LinkDTO]
    }

    struct OutlineItemDTO: Codable, Equatable {
        /// 0 title, 1 heading, 2 subheading.
        var level: Int
        var text: String
        var url: String
    }

    struct TemplateDTO: Codable, Equatable {
        var id: UUID
        var name: String
        var locked: Bool
        var url: String
    }

    struct CreateFromTemplateRequest: Codable {
        var title: String?
        var notebookID: UUID?
    }

    struct Items<T: Codable & Equatable>: Codable, Equatable {
        var items: [T]
    }

    static let routes: [RouteSpec] = [
        RouteSpec(id: "linking.backlinks", method: .GET, pattern: "/v1/notes/{id}/backlinks", scope: .read, body: .none,
                  bucket: .general, maxBodyBytes: nil, summary: "Notes that link to this note, with each link's context"),
        RouteSpec(id: "linking.links", method: .GET, pattern: "/v1/notes/{id}/links", scope: .read, body: .none,
                  bucket: .general, maxBodyBytes: nil, summary: "The links in this note"),
        RouteSpec(id: "linking.outline", method: .GET, pattern: "/v1/notes/{id}/outline", scope: .read, body: .none,
                  bucket: .general, maxBodyBytes: nil, summary: "The note's title, headings and subheadings"),
        RouteSpec(id: "linking.templates", method: .GET, pattern: "/v1/templates", scope: .read, body: .none,
                  bucket: .general, maxBodyBytes: nil, summary: "Templates in the Templates notebook"),
        RouteSpec(id: "linking.createFromTemplate", method: .POST, pattern: "/v1/templates/{id}/notes", scope: .write,
                  body: .json, bucket: .write, maxBodyBytes: nil, summary: "Create a note from a template"),
    ]

    @MainActor
    static func register(in registry: LocalAPIRouteRegistry, store: NoteStore) {
        for spec in routes {
            let id = spec.id
            registry.register(spec) { context in
                await MainActor.run { respond(id, context, store: store) }
            }
        }
    }

    private struct Failure: Error {
        var code: APIErrorCode
        var message: String
    }

    @MainActor
    static func respond(_ routeID: String, _ context: LocalAPIContext, store: NoteStore) -> HTTPResponse {
        do {
            guard !store.isLoading else { throw Failure(code: .notReady, message: "The library is still loading.") }
            switch routeID {
            case "linking.backlinks":
                let meta = try readableNote(context, store: store)
                let items = store.backlinks(to: meta.id).compactMap { backlink -> BacklinkDTO? in
                    guard let source = store.note(with: backlink.source) else { return nil }
                    return BacklinkDTO(noteID: source.id, title: source.title, url: noteURL(source.id),
                                       notebookID: source.notebookID,
                                       notebookName: store.notebook(with: source.notebookID)?.name,
                                       updatedAt: source.updatedAt,
                                       links: backlink.occurrences.map { linkDTO($0, from: source.id, store: store) })
                }
                return .json(Items(items: items))
            case "linking.links":
                let meta = try readableNote(context, store: store)
                return .json(Items(items: store.outgoingLinks(from: meta.id).map { linkDTO($0, from: meta.id, store: store) }))
            case "linking.outline":
                let meta = try readableNote(context, store: store)
                guard let body = store.bodyForOutput(meta.id) else {
                    guard let folder = store.unreadMarkdownFolder(of: meta.id) else {
                        throw Failure(code: .noteUnreadable, message: AutomationError.noteUnreadable.message)
                    }
                    throw Failure(code: .notReady, message: BodyEditError.folderNotAvailableMessage(folder))
                }
                let items = OutlineExtractor.items(in: body).map { item in
                    OutlineItemDTO(level: item.level, text: item.text,
                                   url: NoteLink.note(id: meta.id, heading: item.level == 0 ? nil : item.text).clamped.url.absoluteString)
                }
                return .json(Items(items: items))
            case "linking.templates":
                let items = store.templates.map {
                    TemplateDTO(id: $0.id, name: NoteStore.templateName($0), locked: $0.isLocked, url: noteURL($0.id))
                }
                return .json(Items(items: items))
            case "linking.createFromTemplate":
                return try createFromTemplate(context, store: store)
            default:
                return .error(.notFound, "Not found.")
            }
        } catch let failure as Failure {
            return .error(failure.code, failure.message)
        } catch {
            return .error(.internal, "Something went wrong.")
        }
    }

    @MainActor
    private static func createFromTemplate(_ context: LocalAPIContext, store: NoteStore) throws -> HTTPResponse {
        guard let raw = context.route.params["id"], let templateID = UUID(uuidString: raw),
              let template = store.note(with: templateID), store.isTemplate(templateID) else {
            throw Failure(code: .notFound, message: "No template with that ID.")
        }
        if template.deletedAt != nil { throw Failure(code: .noteDeleted, message: "That template is in Recently Deleted.") }
        if template.isLocked { throw Failure(code: .noteLocked, message: "That template is locked.") }
        var request = CreateFromTemplateRequest()
        if !context.request.body.isEmpty {
            guard let decoded = try? APIJSON.decoder().decode(CreateFromTemplateRequest.self, from: context.request.body) else {
                throw Failure(code: .badRequest, message: "Send a JSON object with an optional title and notebookID.")
            }
            request = decoded
        }
        let notebookID: UUID?
        if let requested = request.notebookID {
            guard store.notebook(with: requested) != nil else { throw Failure(code: .notFound, message: "No notebook with that ID.") }
            notebookID = requested
        } else {
            let fallback = store.defaultNotebookIDForNewNotes
            notebookID = fallback == store.templatesNotebookIDIfSet ? nil : fallback
        }
        let meta: NoteMeta
        do {
            meta = try store.createNote(fromTemplate: templateID, title: request.title ?? "", in: notebookID, readsClipboard: false)
        } catch {
            guard case .folderNotAvailable(let folder) = error else {
                throw Failure(code: .noteUnreadable, message: BodyEditError.templateUnreadableMessage)
            }
            throw Failure(code: .notReady, message: BodyEditError.templateNotReadMessage(folder))
        }
        RichTextEditor.pendingCaret[meta.id] = nil
        let created = store.note(with: meta.id) ?? meta
        return .json(NoteSummaryDTO(id: created.id, title: created.title, notebookID: created.notebookID,
                                    notebookName: store.notebook(with: created.notebookID)?.name, tags: created.tags,
                                    pinned: created.isPinned, createdAt: created.createdAt, updatedAt: created.updatedAt,
                                    revision: created.revision, deletedAt: created.deletedAt,
                                    preview: created.isLocked ? "" : created.preview, conflict: false,
                                    locked: created.isLocked, url: noteURL(created.id)), status: 201)
    }

    /// The live, unlocked note named by the `{id}` path parameter.
    @MainActor
    private static func readableNote(_ context: LocalAPIContext, store: NoteStore) throws -> NoteMeta {
        guard let raw = context.route.params["id"], let id = UUID(uuidString: raw), let meta = store.note(with: id) else {
            throw Failure(code: .notFound, message: "No note with that ID.")
        }
        if meta.deletedAt != nil { throw Failure(code: .noteDeleted, message: "That note is in Recently Deleted.") }
        if meta.isLocked { throw Failure(code: .noteLocked, message: "That note is locked.") }
        return meta
    }

    @MainActor
    private static func linkDTO(_ link: OutgoingLink, from source: UUID, store: NoteStore) -> LinkDTO {
        var dto = LinkDTO(text: link.text, context: link.context, location: link.location)
        guard let parsed = link.link else { return dto }
        switch store.resolve(parsed, from: source) {
        case .note(let id, let heading):
            dto.noteID = id
            dto.heading = heading
            dto.url = NoteLink.note(id: id, heading: heading).url.absoluteString
        case .unresolved(let title):
            dto.unresolvedTitle = title
            dto.heading = parsed.heading
        case .deleted, .missing:
            dto.heading = parsed.heading
        }
        return dto
    }

    private static func noteURL(_ id: UUID) -> String {
        NoteLink.note(id: id, heading: nil).url.absoluteString
    }
}
