import Foundation

// The Local API v1 route table (automation spec §6.10). Shapes owned by the automation plan; built in foundations
// Task 5.1. Other sub-projects add routes through LocalAPIRouteRegistry, never here.

public enum HTTPMethod: String, Sendable { case GET, POST, PATCH, DELETE, OPTIONS }

public enum RouteID: String, Sendable, CaseIterable {
    case ping, openapi, pairStart, pairComplete, me, meDelete, notesList, noteCreate, noteGet, notePatch, noteDelete, noteRestore,
         noteAppend, noteOpen, attachmentsList, attachmentGet, attachmentAdd, stagedUpload, trashEmpty, search, notebooksList, notebookCreate,
         notebookPatch, notebookDelete, tags, daily, dailyAppend, changes, events, clientsList, clientDelete
}

public enum RouteBody: Sendable { case none, json, binary }

/// `general` covers every authenticated request.
public enum RouteBucket: Sendable { case unauthenticated, general, write, upload }

public struct RouteSpec: Sendable {
    /// `RouteID.rawValue` for built-in routes; `"<slug>.<name>"` for registered ones.
    public let id: String
    public let method: HTTPMethod
    public let pattern: String
    /// nil only for the built-in public routes; registered routes always give one.
    public let scope: APIScope?
    public let body: RouteBody
    public let bucket: RouteBucket
    /// nil means 2 MB for JSON and 25 MB for binary bodies; at most 60 MB.
    public let maxBodyBytes: Int?
    public let summary: String

    public init(id: String, method: HTTPMethod, pattern: String, scope: APIScope?, body: RouteBody,
                bucket: RouteBucket, maxBodyBytes: Int?, summary: String) {
        self.id = id
        self.method = method
        self.pattern = pattern
        self.scope = scope
        self.body = body
        self.bucket = bucket
        self.maxBodyBytes = maxBodyBytes
        self.summary = summary
    }
}

public enum APIRoutes {
    public static let basePath = "/v1"

    public static let all: [RouteSpec] = [
        route(.ping, .GET, "/ping", nil, .none, .unauthenticated, "Name, API version, app version and capabilities"),
        route(.openapi, .GET, "/openapi.json", nil, .none, .unauthenticated, "The OpenAPI document"),
        route(.pairStart, .POST, "/pair/start", nil, .json, .unauthenticated, "Begin pairing"),
        route(.pairComplete, .POST, "/pair/complete", nil, .json, .unauthenticated, "Exchange a pairing code for a token"),
        route(.me, .GET, "/me", .read, .none, .general, "The calling client"),
        route(.meDelete, .DELETE, "/me", .read, .none, .general, "Revoke the calling token"),
        route(.notesList, .GET, "/notes", .read, .none, .general, "List notes"),
        route(.noteCreate, .POST, "/notes", .write, .json, .write, "Create a note"),
        route(.noteGet, .GET, "/notes/{id}", .read, .none, .general, "One note"),
        route(.notePatch, .PATCH, "/notes/{id}", .write, .json, .write, "Change a note's title, body, notebook or pin"),
        route(.noteDelete, .DELETE, "/notes/{id}", .write, .none, .write, "Move a note to Recently Deleted, or delete it for good"),
        route(.noteRestore, .POST, "/notes/{id}/restore", .write, .none, .write, "Recover a note from Recently Deleted"),
        route(.noteAppend, .POST, "/notes/{id}/append", .write, .json, .write, "Append text to a note"),
        route(.noteOpen, .POST, "/notes/{id}/open", .read, .none, .general, "Bring NoteIt to the front with the note selected"),
        route(.attachmentsList, .GET, "/notes/{id}/attachments", .read, .none, .general, "A note's attachments"),
        route(.attachmentGet, .GET, "/notes/{id}/attachments/{name}", .read, .none, .general, "One attachment's bytes"),
        route(.attachmentAdd, .POST, "/notes/{id}/attachments", .write, .binary, .upload, "Add an attachment at the end of a note"),
        route(.stagedUpload, .POST, "/attachments", .write, .binary, .upload, "Stage an upload for Markdown bodies"),
        route(.trashEmpty, .DELETE, "/trash", .admin, .none, .write, "Empty Recently Deleted"),
        route(.search, .GET, "/search", .read, .none, .general, "Search notes"),
        route(.notebooksList, .GET, "/notebooks", .read, .none, .general, "Notebooks in sidebar order"),
        route(.notebookCreate, .POST, "/notebooks", .write, .json, .write, "Create a notebook"),
        route(.notebookPatch, .PATCH, "/notebooks/{id}", .write, .json, .write, "Rename or restyle a notebook"),
        route(.notebookDelete, .DELETE, "/notebooks/{id}", .write, .none, .write, "Delete a notebook"),
        route(.tags, .GET, "/tags", .read, .none, .general, "Tags with note counts"),
        route(.daily, .GET, "/daily", .read, .none, .general, "A day's daily note"),
        route(.dailyAppend, .POST, "/daily/append", .write, .json, .write, "Append to a daily note"),
        route(.changes, .GET, "/changes", .read, .none, .general, "Changes since a cursor"),
        route(.events, .GET, "/events", .read, .none, .general, "Server-Sent Events of changes"),
        route(.clientsList, .GET, "/clients", .admin, .none, .general, "Paired clients"),
        route(.clientDelete, .DELETE, "/clients/{id}", .admin, .none, .write, "Revoke a client"),
    ]

    private static func route(_ id: RouteID, _ method: HTTPMethod, _ path: String, _ scope: APIScope?, _ body: RouteBody,
                              _ bucket: RouteBucket, _ summary: String) -> RouteSpec {
        RouteSpec(id: id.rawValue, method: method, pattern: basePath + path, scope: scope, body: body, bucket: bucket,
                  maxBodyBytes: nil, summary: summary)
    }
}
