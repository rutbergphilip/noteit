import Foundation

/// A block node of a `noteit-doc` document. Shape owned by the web-app plan (`@noteit/doc`); built in foundations
/// Task 2.1.
public indirect enum DocNode: Codable, Equatable, Sendable {
    case doc([DocNode])
    case paragraph(align: Align?, indent: Int?, content: [Inline])
    /// 1 = Title, 2 = Heading, 3 = Subheading.
    case heading(level: Int, align: Align?, indent: Int?, content: [Inline])
    /// One native code paragraph. `language` is kept and never edited (markdown-storage §3.12).
    case codeBlock(align: Align?, language: String?, content: [Inline])
    case blockquote(indent: Int?, content: [DocNode])
    case horizontalRule
    case listItem(kind: ListKind, level: Int, number: Int?, checked: Bool?, align: Align?, content: [Inline])
    case table(columnWidths: [Double]?, rows: [[TableCell]])
    /// A node this build doesn't know, kept as its encoded JSON so it re-encodes unchanged. It makes the document
    /// read-only. A known block holding an unknown inline or mark type is kept the same way.
    case unknown(type: String, json: Data)

    public init(from decoder: Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// A table cell. Header cells are `tableHeader` in JSON, the others `tableCell`.
public struct TableCell: Codable, Equatable, Sendable {
    public var header: Bool
    public var content: [DocNode]

    public init(header: Bool, content: [DocNode]) {
        self.header = header
        self.content = content
    }

    public init(from decoder: Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    init(json: JSONValue) throws {
        let fields = try JSONFields(json, context: "table cell")
        let type = try fields.string("type")
        switch type {
        case "tableHeader": header = true
        case "tableCell": header = false
        default: throw UnknownDocType(type: type)
        }
        content = try fields.array("content").map(DocNode.init(json:))
    }

    var json: JSONValue {
        get throws {
            .object(["type": .string(header ? "tableHeader" : "tableCell"), "content": .array(try content.map { try $0.json })])
        }
    }
}

extension DocNode {
    init(json: JSONValue) throws {
        let fields = try JSONFields(json, context: "node")
        let type = try fields.string("type")
        do {
            self = try Self.known(type: type, fields: fields)
        } catch is UnknownDocType {
            self = .unknown(type: type, json: try json.encoded())
        }
    }

    private static func inlines(_ fields: JSONFields) throws -> [Inline] {
        try fields.array("content").map(Inline.init(json:))
    }

    private static func known(type: String, fields: JSONFields) throws -> DocNode {
        switch type {
        case "doc":
            return .doc(try fields.array("content").map(DocNode.init(json:)))
        case "paragraph":
            let attrs = try fields.attrs()
            return .paragraph(align: try attrs.optionalEnum("align", Align.self), indent: try attrs.optionalInt("indent"),
                              content: try inlines(fields))
        case "heading":
            let attrs = try fields.attrs()
            return .heading(level: try attrs.int("level"), align: try attrs.optionalEnum("align", Align.self),
                            indent: try attrs.optionalInt("indent"), content: try inlines(fields))
        case "codeBlock":
            let attrs = try fields.attrs()
            return .codeBlock(align: try attrs.optionalEnum("align", Align.self), language: try attrs.optionalString("language"),
                              content: try inlines(fields))
        case "blockquote":
            return .blockquote(indent: try fields.attrs().optionalInt("indent"),
                               content: try fields.array("content").map(DocNode.init(json:)))
        case "horizontalRule":
            return .horizontalRule
        case "listItem":
            let attrs = try fields.attrs()
            guard let kind = try attrs.optionalEnum("kind", ListKind.self) else { throw DocDecodingError("listItem: missing kind") }
            return .listItem(kind: kind, level: try attrs.int("level"), number: try attrs.optionalInt("number"),
                             checked: try attrs.optionalBool("checked"), align: try attrs.optionalEnum("align", Align.self),
                             content: try inlines(fields))
        case "table":
            let widths: [Double]?
            switch try fields.attrs().members["columnWidths"] {
            case nil, .null?: widths = nil
            case .array(let items)?:
                widths = try items.map { item in
                    guard case .number(let token) = item, let value = Double(token) else {
                        throw DocDecodingError("table: columnWidths must hold numbers")
                    }
                    return value
                }
            default: throw DocDecodingError("table: columnWidths must be an array")
            }
            let rows = try fields.array("content").map { row -> [TableCell] in
                let rowFields = try JSONFields(row, context: "table row")
                let rowType = try rowFields.string("type")
                guard rowType == "tableRow" else { throw UnknownDocType(type: rowType) }
                return try rowFields.array("content").map(TableCell.init(json:))
            }
            return .table(columnWidths: widths, rows: rows)
        default:
            throw UnknownDocType(type: type)
        }
    }

    var json: JSONValue {
        get throws {
            var object = JSONObjectBuilder()
            var attrs = JSONObjectBuilder()
            func inlineContent(_ content: [Inline]) throws {
                if !content.isEmpty { object.set("content", .array(try content.map { try $0.json })) }
            }
            switch self {
            case .doc(let content):
                object.set("type", .string("doc"))
                object.set("content", .array(try content.map { try $0.json }))
            case .paragraph(let align, let indent, let content):
                object.set("type", .string("paragraph"))
                attrs.set("align", align.map { .string($0.rawValue) })
                attrs.set("indent", indent.map(JSONValue.int))
                if !attrs.isEmpty { object.set("attrs", attrs.value) }
                try inlineContent(content)
            case .heading(let level, let align, let indent, let content):
                object.set("type", .string("heading"))
                attrs.set("level", .int(level))
                attrs.set("align", align.map { .string($0.rawValue) })
                attrs.set("indent", indent.map(JSONValue.int))
                object.set("attrs", attrs.value)
                try inlineContent(content)
            case .codeBlock(let align, let language, let content):
                object.set("type", .string("codeBlock"))
                attrs.set("align", align.map { .string($0.rawValue) })
                attrs.set("language", language.map(JSONValue.string))
                if !attrs.isEmpty { object.set("attrs", attrs.value) }
                try inlineContent(content)
            case .blockquote(let indent, let content):
                object.set("type", .string("blockquote"))
                attrs.set("indent", indent.map(JSONValue.int))
                if !attrs.isEmpty { object.set("attrs", attrs.value) }
                object.set("content", .array(try content.map { try $0.json }))
            case .horizontalRule:
                object.set("type", .string("horizontalRule"))
            case .listItem(let kind, let level, let number, let checked, let align, let content):
                object.set("type", .string("listItem"))
                attrs.set("kind", .string(kind.rawValue))
                attrs.set("level", .int(level))
                attrs.set("number", number.map(JSONValue.int))
                attrs.set("checked", checked.map(JSONValue.bool))
                attrs.set("align", align.map { .string($0.rawValue) })
                object.set("attrs", attrs.value)
                try inlineContent(content)
            case .table(let columnWidths, let rows):
                object.set("type", .string("table"))
                attrs.set("columnWidths", try columnWidths.map { .array(try $0.map(JSONValue.double)) })
                if !attrs.isEmpty { object.set("attrs", attrs.value) }
                object.set("content", .array(try rows.map { row in
                    .object(["type": .string("tableRow"), "content": .array(try row.map { try $0.json })])
                }))
            case .unknown(_, let json):
                return try JSONValue.decode(json)
            }
            return object.value
        }
    }
}
