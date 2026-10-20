import Foundation

/// The OpenAPI 3.1 document served at `GET /v1/openapi.json`, generated from `APIRoutes.all` and the routes and
/// search modes in a `LocalAPIRouteRegistry`. Schemas are written by hand from the wire types (spec §6.9).
public enum OpenAPIDocument {
    public static func data(registry: LocalAPIRouteRegistry = .shared, appVersion: String = "1") -> Data {
        (try? JSONSerialization.data(withJSONObject: build(registry: registry, appVersion: appVersion),
                                     options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    public static func build(registry: LocalAPIRouteRegistry = .shared, appVersion: String = "1") -> [String: Any] {
        let searchModes = ["keyword"] + registry.searchModes
        var paths: [String: [String: Any]] = [:]
        for spec in APIRoutes.all + registry.routes {
            paths[spec.pattern, default: [:]][spec.method.rawValue.lowercased()] = operation(spec, searchModes: searchModes)
        }
        return [
            "openapi": "3.1.0",
            "info": [
                "title": "NoteIt Local API",
                "version": appVersion,
                "description": "Loopback HTTP+JSON API of the NoteIt app. Off by default; tokens come from pairing.",
            ],
            "servers": [[
                "url": "http://127.0.0.1:{port}",
                "variables": ["port": ["default": "47600"]],
            ]],
            "security": [["bearer": [String]()]],
            "paths": paths,
            "components": [
                "securitySchemes": ["bearer": ["type": "http", "scheme": "bearer"]],
                "schemas": schemas,
            ],
        ]
    }

    // MARK: - Operations

    private static func operation(_ spec: RouteSpec, searchModes: [String]) -> [String: Any] {
        var operation: [String: Any] = [
            "operationId": spec.id,
            "summary": spec.summary,
            "x-noteit-route-id": spec.id,
        ]
        if let scope = spec.scope {
            operation["x-noteit-scope"] = scope.rawValue
        } else {
            operation["security"] = [[String: Any]]()
        }
        let pathParams = spec.pattern.split(separator: "/").filter { $0.hasPrefix("{") && $0.hasSuffix("}") }
            .map { parameter(String($0.dropFirst().dropLast()), in: "path", required: true) }
        let route = RouteID(rawValue: spec.id)
        let queryParams = route.map { queryParameters($0, searchModes: searchModes) } ?? []
        let headerParams = route.map(headerParameters) ?? []
        if !(pathParams + queryParams + headerParams).isEmpty {
            operation["parameters"] = pathParams + queryParams + headerParams
        }
        switch spec.body {
        case .none:
            break
        case .json:
            let schema = route.flatMap(requestSchema) ?? ["type": "object"]
            operation["requestBody"] = ["required": true, "content": ["application/json": ["schema": schema]]]
        case .binary:
            operation["requestBody"] = ["required": true,
                                        "content": ["*/*": ["schema": ["type": "string", "contentMediaType": "application/octet-stream"]]]]
        }
        var responses: [String: Any] = ["default": [
            "description": "An error",
            "content": ["application/json": ["schema": ref("Error")]],
        ]]
        let (status, success) = route.map(successResponse) ?? ("200", ["description": "Success"])
        responses[status] = success
        operation["responses"] = responses
        return operation
    }

    private static func queryParameters(_ route: RouteID, searchModes: [String]) -> [[String: Any]] {
        switch route {
        case .notesList:
            return [parameter("notebook", description: "Notebook id or name"), parameter("tag"), parameter("q"),
                    parameter("updatedSince", schema: ["type": "string", "format": "date-time"]),
                    parameter("deleted", schema: ["type": "string", "enum": ["only", "include"]]),
                    parameter("sort", schema: ["type": "string", "enum": ["list", "updated"]]),
                    limit, parameter("cursor")]
        case .noteGet:
            return [parameter("format", schema: ["type": "string", "enum": ["markdown", "text", "html", "noteit-doc"]])]
        case .noteDelete:
            return [parameter("permanent", schema: ["type": "boolean"], description: "Needs admin")]
        case .search:
            return [parameter("q", required: true), parameter("notebook"), parameter("tag"), limit,
                    parameter("mode", schema: ["type": "string", "enum": searchModes, "default": "keyword"])]
        case .tags:
            return [parameter("tree", schema: ["type": "string", "enum": ["1"]])]
        case .daily:
            return [parameter("date", schema: ["type": "string", "format": "date"]),
                    parameter("create", schema: ["type": "boolean"], description: "Needs write"),
                    parameter("format", schema: ["type": "string", "enum": ["plain", "markdown"]])]
        case .changes:
            return [parameter("since"), limit]
        case .events:
            return [parameter("since")]
        default:
            return []
        }
    }

    private static func headerParameters(_ route: RouteID) -> [[String: Any]] {
        switch route {
        case .notePatch:
            return [parameter("If-Match", in: "header", description: "\"<revision>\"")]
        case .attachmentAdd, .stagedUpload:
            return [parameter("X-NoteIt-Filename", in: "header")]
        case .events:
            return [parameter("Last-Event-ID", in: "header")]
        default:
            return []
        }
    }

    private static func requestSchema(_ route: RouteID) -> [String: Any]? {
        switch route {
        case .pairStart: return ref("PairStartRequest")
        case .pairComplete: return ref("PairCompleteRequest")
        case .noteCreate: return ref("CreateNoteRequest")
        case .notePatch: return ref("PatchNoteRequest")
        case .noteAppend: return ref("AppendRequest")
        case .notebookCreate, .notebookPatch: return ref("NotebookRequest")
        case .dailyAppend: return ref("DailyAppendRequest")
        default: return nil
        }
    }

    private static func successResponse(_ route: RouteID) -> (String, [String: Any]) {
        func json(_ schema: [String: Any], _ status: String = "200") -> (String, [String: Any]) {
            (status, ["description": "Success", "content": ["application/json": ["schema": schema]]])
        }
        let noContent: (String, [String: Any]) = ("204", ["description": "No content"])
        switch route {
        case .ping: return json(ref("Ping"))
        case .openapi: return json(["type": "object"])
        case .pairStart: return json(ref("PairStartResponse"))
        case .pairComplete: return json(ref("PairCompleteResponse"))
        case .me: return json(ref("Client"))
        case .meDelete, .noteDelete, .noteOpen, .trashEmpty, .notebookDelete, .clientDelete: return noContent
        case .notesList: return json(ref("NoteSummaryPage"))
        case .noteCreate: return json(ref("Note"), "201")
        case .noteGet, .notePatch, .noteRestore, .noteAppend, .attachmentAdd, .daily, .dailyAppend: return json(ref("Note"))
        case .attachmentsList: return json(array(ref("Attachment")))
        case .attachmentGet:
            return ("200", ["description": "The attachment's bytes",
                            "content": ["*/*": ["schema": ["type": "string", "contentMediaType": "application/octet-stream"]]]])
        case .stagedUpload: return json(ref("StagedUpload"), "201")
        case .search: return json(ref("SearchResponse"))
        case .notebooksList: return json(ref("NotebooksResponse"))
        case .notebookCreate: return json(ref("Notebook"), "201")
        case .notebookPatch: return json(ref("Notebook"))
        case .tags: return json(["oneOf": [array(ref("Tag")), array(ref("TagNode"))]])
        case .changes: return json(ref("ChangesPage"))
        case .events:
            return ("200", ["description": "Server-Sent Events: `event: change` with a Change, `event: revoked` before closing",
                            "content": ["text/event-stream": ["schema": ["type": "string"]]]])
        case .clientsList: return json(array(ref("Client")))
        }
    }

    // MARK: - Schemas

    private static let schemas: [String: Any] = [
        "Error": object(["error": object(["code": ["type": "string", "enum": APIErrorCode.allCases.map(\.rawValue)],
                                          "message": string])]),
        "NoteSummary": noteSummary,
        "Note": ["allOf": [ref("NoteSummary"),
                           object(["format": bodyFormat, "body": string])]],
        "NoteSummaryPage": object(["items": array(ref("NoteSummary")), "nextCursor": nullable(string)]),
        "Notebook": object(["id": uuid, "name": string, "symbol": string, "color": string, "sortIndex": integer,
                            "noteCount": integer, "parentID": nullable(uuid), "path": nullable(array(string))],
                           optional: ["parentID", "path"]),
        "NotebooksResponse": object(["notebooks": array(ref("Notebook")), "defaultNotebookID": nullable(uuid)]),
        "Tag": object(["name": string, "noteCount": integer]),
        "TagNode": object(["name": string, "path": string, "noteCount": integer, "totalCount": integer,
                           "children": array(ref("TagNode"))]),
        "Highlight": object(["field": ["type": "string", "enum": ["title", "body"]],
                             "ranges": array(["type": "array", "items": integer, "minItems": 2, "maxItems": 2])]),
        "SearchResult": object(["note": ref("NoteSummary"), "snippet": string, "score": ["type": "number"],
                                "highlights": array(ref("Highlight")), "matchedBy": array(string)],
                               optional: ["score", "highlights", "matchedBy"]),
        "SearchResponse": object(["mode": string, "results": array(ref("SearchResult"))]),
        "Attachment": object(["name": string, "contentType": string, "size": integer]),
        "StagedUpload": object(["id": string, "expiresAt": date]),
        "Change": object(["cursor": string, "kind": ["type": "string", "enum": ["note", "notebook"]], "id": uuid,
                          "op": ["type": "string", "enum": ["created", "updated", "deleted", "restored", "purged"]],
                          "at": date]),
        "ChangesPage": object(["changes": array(ref("Change")), "cursor": string, "hasMore": boolean]),
        "Client": object(["id": uuid, "name": string, "kind": clientKind, "scopes": array(scope), "origin": nullable(string),
                          "tokenHint": string, "createdAt": date, "lastUsedAt": nullable(date)],
                         optional: ["origin", "lastUsedAt"]),
        "Ping": object(["name": string, "apiVersion": integer, "appVersion": string, "capabilities": array(string)]),
        "CreateNoteRequest": object(["title": string, "body": string, "format": bodyFormat, "notebookID": uuid,
                                     "notebook": string, "tags": array(string), "pinned": boolean],
                                    optional: ["title", "format", "notebookID", "notebook", "tags", "pinned"]),
        "PatchNoteRequest": object(["title": string, "body": string, "format": bodyFormat, "notebookID": uuid,
                                    "pinned": boolean],
                                   optional: ["title", "body", "format", "notebookID", "pinned"]),
        "AppendRequest": object(["text": string, "format": bodyFormat,
                                 "position": ["type": "string", "enum": ["end", "start"]], "timestamp": boolean,
                                 "ifRevision": uuid],
                                optional: ["format", "position", "timestamp", "ifRevision"]),
        "DailyAppendRequest": object(["text": string, "timestamp": boolean, "date": ["type": "string", "format": "date"],
                                      "format": ["type": "string", "enum": ["plain", "markdown"]]],
                                     optional: ["timestamp", "date", "format"]),
        "NotebookRequest": object(["name": string, "symbol": string, "color": string],
                                  optional: ["name", "symbol", "color"]),
        "PairStartRequest": object(["clientName": string, "kind": clientKind, "scopes": array(scope)]),
        "PairStartResponse": object(["pairingID": uuid, "expiresAt": date]),
        "PairCompleteRequest": object(["pairingID": uuid, "code": string]),
        "PairCompleteResponse": object(["token": string, "clientID": uuid, "scopes": array(scope)]),
    ]

    private static let noteSummary = object([
        "id": uuid, "title": string, "notebookID": nullable(uuid), "notebookName": nullable(string), "tags": array(string),
        "pinned": boolean, "createdAt": date, "updatedAt": date, "revision": nullable(uuid), "deletedAt": nullable(date),
        "preview": string, "conflict": boolean, "locked": boolean,
        "url": ["type": "string", "description": "noteit://note/<UUID>"],
    ], optional: ["notebookID", "notebookName", "deletedAt"])

    private static let string: [String: Any] = ["type": "string"]
    private static let integer: [String: Any] = ["type": "integer"]
    private static let boolean: [String: Any] = ["type": "boolean"]
    private static let uuid: [String: Any] = ["type": "string", "format": "uuid"]
    private static let date: [String: Any] = ["type": "string", "format": "date-time"]
    private static let bodyFormat: [String: Any] = ["type": "string", "enum": ["markdown", "text", "html", "noteit-doc"]]
    private static let clientKind: [String: Any] = ["type": "string", "enum": ClientKind.allCases.map(\.rawValue)]
    private static let scope: [String: Any] = ["type": "string", "enum": APIScope.allCases.map(\.rawValue)]
    private static let limit = parameter("limit", schema: ["type": "integer", "minimum": 1, "maximum": 500, "default": 50])

    private static func ref(_ name: String) -> [String: Any] { ["$ref": "#/components/schemas/\(name)"] }

    private static func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }

    private static func nullable(_ schema: [String: Any]) -> [String: Any] { ["oneOf": [schema, ["type": "null"]]] }

    private static func object(_ properties: [String: [String: Any]], optional: Set<String> = []) -> [String: Any] {
        ["type": "object", "properties": properties,
         "required": properties.keys.filter { !optional.contains($0) }.sorted()]
    }

    private static func parameter(_ name: String, in location: String = "query", required: Bool = false,
                                  schema: [String: Any] = ["type": "string"], description: String? = nil) -> [String: Any] {
        var parameter: [String: Any] = ["name": name, "in": location, "required": required, "schema": schema]
        if let description { parameter["description"] = description }
        return parameter
    }
}
