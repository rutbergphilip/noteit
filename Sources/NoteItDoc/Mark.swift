import Foundation

/// A character mark. Shape owned by the web-app plan (`@noteit/doc`); built in foundations Task 2.1.
public enum Mark: Codable, Hashable, Sendable {
    case bold, italic, underline, strike, code
    /// The scheme must pass `LinkPolicy.allows`.
    case link(href: String)
    /// `#RRGGBB`, the light-appearance value.
    case textColor(String)
    /// `#RRGGBB`.
    case highlight(String)
    /// Points relative to the block's base size; base + delta stays within 8–96.
    case fontSize(delta: Int)

    public init(from decoder: Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    init(json: JSONValue) throws {
        let fields = try JSONFields(json, context: "mark")
        let type = try fields.string("type")
        switch type {
        case "bold": self = .bold
        case "italic": self = .italic
        case "underline": self = .underline
        case "strike": self = .strike
        case "code": self = .code
        case "link": self = .link(href: try fields.attrs().string("href"))
        case "textColor": self = .textColor(try fields.attrs().string("color"))
        case "highlight": self = .highlight(try fields.attrs().string("color"))
        case "fontSize": self = .fontSize(delta: try fields.attrs().int("delta"))
        default: throw UnknownDocType(type: type)
        }
    }

    var json: JSONValue {
        get throws {
            func simple(_ type: String) -> JSONValue { .object(["type": .string(type)]) }
            func withAttrs(_ type: String, _ attrs: [String: JSONValue]) -> JSONValue {
                .object(["type": .string(type), "attrs": .object(attrs)])
            }
            switch self {
            case .bold: return simple("bold")
            case .italic: return simple("italic")
            case .underline: return simple("underline")
            case .strike: return simple("strike")
            case .code: return simple("code")
            case .link(let href): return withAttrs("link", ["href": .string(href)])
            case .textColor(let color): return withAttrs("textColor", ["color": .string(color)])
            case .highlight(let color): return withAttrs("highlight", ["color": .string(color)])
            case .fontSize(let delta): return withAttrs("fontSize", ["delta": .int(delta)])
            }
        }
    }
}
