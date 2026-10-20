import Foundation

/// A note body in the `noteit-doc` format: the document, its attachments and any fields this build doesn't know.
/// Shape owned by the web-app plan (`@noteit/doc`); built in foundations Task 2.1.
public struct BodyContainer: Codable, Equatable, Sendable {
    public static let format = "noteit-doc"
    public static let currentVersion = 1
    /// Standalone, self-contained container files (attachments inside).
    public static let fileExtension = "noteitdoc"

    public var format: String
    public var version: Int
    public var doc: DocNode
    /// Key: lowercase hex SHA-256 of the attachment's data.
    public var attachments: [String: Attachment]
    /// Kept, never shown (markdown-storage §3.12).
    public var frontMatter: String?
    /// Unknown top-level keys, re-encoded unchanged.
    public var extra: [String: JSONValue]

    public init(doc: DocNode, attachments: [String: Attachment] = [:], frontMatter: String? = nil) {
        format = Self.format
        version = Self.currentVersion
        self.doc = doc
        self.attachments = attachments
        self.frontMatter = frontMatter
        extra = [:]
    }

    /// `frontMatter` and `extra`, read or replaced together.
    public var extras: ContainerExtras {
        get { ContainerExtras(frontMatter: frontMatter, extra: extra) }
        set {
            frontMatter = newValue.frontMatter
            extra = newValue.extra
        }
    }

    /// Sorted keys, unescaped slashes and verbatim number tokens: the byte form golden vectors use.
    public func encoded() throws -> Data {
        try json.encoded()
    }

    public static func decode(_ data: Data) throws -> BodyContainer {
        try BodyContainer(json: JSONValue.decode(data))
    }

    public init(from decoder: Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    private static let knownKeys: Set<String> = ["format", "version", "doc", "attachments", "frontMatter"]

    init(json: JSONValue) throws {
        let fields = try JSONFields(json, context: "container")
        format = try fields.string("format")
        version = try fields.int("version")
        guard let docJSON = fields.members["doc"] else { throw DocDecodingError("container: missing doc") }
        doc = try DocNode(json: docJSON)
        switch fields.members["attachments"] {
        case nil, .null?:
            attachments = [:]
        case .object(let members)?:
            attachments = try members.mapValues(Attachment.init(json:))
        default:
            throw DocDecodingError("container: attachments must be an object")
        }
        frontMatter = try fields.optionalString("frontMatter")
        extra = fields.members.filter { !Self.knownKeys.contains($0.key) }
    }

    var json: JSONValue {
        get throws {
            var members = extra
            members["format"] = .string(format)
            members["version"] = .int(version)
            members["doc"] = try doc.json
            members["attachments"] = .object(attachments.mapValues(\.json))
            if let frontMatter { members["frontMatter"] = .string(frontMatter) }
            return .object(members)
        }
    }
}

/// The container fields that the editor's NSAttributedString can't hold. BodyCodec hands them out on read and takes
/// them back on write, so they survive read → edit → write. frontMatter has BodyContainer.frontMatter's type.
/// Owned by the foundations plan (Task 2.1).
public struct ContainerExtras: Equatable, Sendable {
    public var frontMatter: String?
    /// Unknown top-level keys.
    public var extra: [String: JSONValue]

    public static let empty = ContainerExtras()

    public init(frontMatter: String? = nil, extra: [String: JSONValue] = [:]) {
        self.frontMatter = frontMatter
        self.extra = extra
    }
}
