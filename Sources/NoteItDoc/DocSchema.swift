import Foundation

// The `noteit-doc` v1 schema. Owned by the web-app plan (its `@noteit/doc` TypeScript types are the reference
// for the JSON of every node and mark); built in foundations Task 2.1. Every type codes through `JSONValue`, so
// `BodyContainer.encoded()` and `decode(_:)` keep number tokens and unknown nodes exactly.

/// Paragraph alignment. Absent means natural.
public enum Align: String, Codable, Sendable {
    case left, center, right, justify
}

/// The kind of a flat list item.
public enum ListKind: String, Codable, Sendable {
    case bullet, ordered, task
}

/// Inline content of a paragraph, heading, code block or list item.
public enum Inline: Codable, Hashable, Sendable {
    case text(String, marks: [Mark]), hardBreak
    case image(sha: String, name: String, mime: String, width: Double?)
    case attachment(sha: String, name: String, mime: String)

    public init(from decoder: Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// A node or mark type this build doesn't know. A block that holds one decodes as `DocNode.unknown`.
struct UnknownDocType: Error {
    var type: String
}

/// Reads typed fields out of a JSON object, with errors that name the node.
struct JSONFields {
    let members: [String: JSONValue]
    let context: String

    init(_ value: JSONValue, context: String) throws {
        guard case .object(let members) = value else { throw DocDecodingError("\(context): expected an object") }
        self.members = members
        self.context = context
    }

    func has(_ key: String) -> Bool {
        if let value = members[key], value != .null { return true }
        return false
    }

    func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw DocDecodingError("\(context): missing \(key)") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        switch members[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw DocDecodingError("\(context): \(key) must be a string")
        }
    }

    func int(_ key: String) throws -> Int {
        guard let value = try optionalInt(key) else { throw DocDecodingError("\(context): missing \(key)") }
        return value
    }

    func optionalInt(_ key: String) throws -> Int? {
        switch members[key] {
        case nil, .null?: return nil
        case .number(let token)?:
            if let value = Int(token) { return value }
            if let value = Double(token), value.rounded() == value, abs(value) < 1e15 { return Int(value) }
            throw DocDecodingError("\(context): \(key) must be an integer")
        default: throw DocDecodingError("\(context): \(key) must be a number")
        }
    }

    func optionalDouble(_ key: String) throws -> Double? {
        switch members[key] {
        case nil, .null?: return nil
        case .number(let token)?:
            guard let value = Double(token) else { throw DocDecodingError("\(context): \(key) is out of range") }
            return value
        default: throw DocDecodingError("\(context): \(key) must be a number")
        }
    }

    func optionalBool(_ key: String) throws -> Bool? {
        switch members[key] {
        case nil, .null?: return nil
        case .bool(let value)?: return value
        default: throw DocDecodingError("\(context): \(key) must be a boolean")
        }
    }

    func array(_ key: String) throws -> [JSONValue] {
        switch members[key] {
        case nil, .null?: return []
        case .array(let items)?: return items
        default: throw DocDecodingError("\(context): \(key) must be an array")
        }
    }

    func attrs() throws -> JSONFields {
        let value = members["attrs"].flatMap { $0 == .null ? nil : $0 } ?? .object([:])
        return try JSONFields(value, context: context + ".attrs")
    }

    func optionalEnum<E: RawRepresentable>(_ key: String, _ type: E.Type) throws -> E? where E.RawValue == String {
        guard let raw = try optionalString(key) else { return nil }
        guard let value = E(rawValue: raw) else { throw DocDecodingError("\(context): unknown \(key) \(raw)") }
        return value
    }
}

/// Builds JSON objects, leaving out nil values.
struct JSONObjectBuilder {
    private(set) var members: [String: JSONValue] = [:]

    mutating func set(_ key: String, _ value: JSONValue?) {
        if let value { members[key] = value }
    }

    var isEmpty: Bool { members.isEmpty }
    var value: JSONValue { .object(members) }
}

extension JSONValue {
    static func int(_ value: Int) -> JSONValue { .number(String(value)) }

    static func double(_ value: Double) throws -> JSONValue {
        guard value.isFinite else { throw DocDecodingError("Not a finite number: \(value)") }
        if value.rounded() == value, abs(value) < 1e15 { return .number(String(Int64(value))) }
        return .number("\(value)")
    }

    var typeName: String? {
        if case .object(let members) = self, case .string(let type)? = members["type"] { return type }
        return nil
    }
}

extension Inline {
    init(json: JSONValue) throws {
        let fields = try JSONFields(json, context: "inline")
        let type = try fields.string("type")
        switch type {
        case "text":
            let marks = try fields.array("marks").map(Mark.init(json:))
            self = .text(try fields.string("text"), marks: marks)
        case "hardBreak":
            self = .hardBreak
        case "image":
            let attrs = try fields.attrs()
            self = .image(sha: try attrs.string("sha"), name: try attrs.string("name"), mime: try attrs.string("mime"),
                          width: try attrs.optionalDouble("width"))
        case "attachment":
            let attrs = try fields.attrs()
            self = .attachment(sha: try attrs.string("sha"), name: try attrs.string("name"), mime: try attrs.string("mime"))
        default:
            throw UnknownDocType(type: type)
        }
    }

    var json: JSONValue {
        get throws {
            var object = JSONObjectBuilder()
            switch self {
            case .text(let text, let marks):
                object.set("type", .string("text"))
                object.set("text", .string(text))
                if !marks.isEmpty { object.set("marks", .array(try marks.map { try $0.json })) }
            case .hardBreak:
                object.set("type", .string("hardBreak"))
            case .image(let sha, let name, let mime, let width):
                var attrs = JSONObjectBuilder()
                attrs.set("sha", .string(sha))
                attrs.set("name", .string(name))
                attrs.set("mime", .string(mime))
                attrs.set("width", try width.map(JSONValue.double))
                object.set("type", .string("image"))
                object.set("attrs", attrs.value)
            case .attachment(let sha, let name, let mime):
                var attrs = JSONObjectBuilder()
                attrs.set("sha", .string(sha))
                attrs.set("name", .string(name))
                attrs.set("mime", .string(mime))
                object.set("type", .string("attachment"))
                object.set("attrs", attrs.value)
            }
            return object.value
        }
    }
}
