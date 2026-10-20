import Foundation

/// Any JSON value, used for the parts of a body container this build doesn't know. Owned by the web-app
/// plan; built in foundations Task 2.1.
///
/// Numbers are lossless: `number` holds the original token (for example "9007199254740993" or "1.50"), checked
/// against the JSON number grammar on decode and written back verbatim. Never converted through Double.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(String), string(String), array([JSONValue]), object([String: JSONValue])

    /// Plain `Codable` can't see number tokens, so a number goes through `Decimal` there (up to 38 significant
    /// digits, but not the spelling). `decode(_:)` and `encoded()` keep the token.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value.description)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let token):
            guard JSONNumberGrammar.isValid(token), let value = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")) else {
                throw EncodingError.invalidValue(token, .init(codingPath: encoder.codingPath, debugDescription: "Not a JSON number: \(token)"))
            }
            try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// The same scanner and verbatim token writer BodyContainer uses, for other JSON files (the body-extras
    /// sidecar, foundations Task 4.1). Keys are sorted, slashes aren't escaped, numbers are written as their token.
    public func encoded() throws -> Data {
        var out = ""
        try JSONWriter.write(self, to: &out)
        return Data(out.utf8)
    }

    /// Parses a whole JSON document, keeping every number's token.
    public static func decode(_ data: Data) throws -> JSONValue {
        var scanner = JSONScanner(bytes: Array(data))
        return try scanner.parseDocument()
    }
}

/// Why a JSON document or a body container could not be read.
public struct DocDecodingError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

enum JSONNumberGrammar {
    /// RFC 8259: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    static func isValid(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        var i = 0
        func digit(_ at: Int) -> Bool { at < bytes.count && bytes[at] >= 0x30 && bytes[at] <= 0x39 }
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard digit(i) else { return false }
        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else {
            while digit(i) { i += 1 }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digit(i) else { return false }
            while digit(i) { i += 1 }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digit(i) else { return false }
            while digit(i) { i += 1 }
        }
        return i == bytes.count
    }
}

/// A strict RFC 8259 parser that keeps number tokens as written.
struct JSONScanner {
    let bytes: [UInt8]
    var index = 0
    private var depth = 0
    private static let maxDepth = 512

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("Unexpected data after the JSON value") }
        return value
    }

    private func error(_ message: String) -> DocDecodingError {
        DocDecodingError("\(message) at byte \(index)")
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw error("Unexpected end of JSON") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func expect(_ literal: String) throws {
        let utf8 = Array(literal.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
            throw error("Invalid literal")
        }
        index += utf8.count
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        let allowed = Set("+-.0123456789eE".utf8)
        while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
        guard index > start, let token = String(bytes: bytes[start..<index], encoding: .utf8),
              JSONNumberGrammar.isValid(token) else {
            index = start
            throw error("Invalid number")
        }
        return token
    }

    private mutating func nested<T>(_ body: (inout JSONScanner) throws -> T) throws -> T {
        depth += 1
        guard depth <= Self.maxDepth else { throw error("JSON nested too deeply") }
        defer { depth -= 1 }
        return try body(&self)
    }

    private mutating func parseArray() throws -> JSONValue {
        try nested { s in
            s.index += 1
            var items: [JSONValue] = []
            s.skipWhitespace()
            if s.index < s.bytes.count, s.bytes[s.index] == UInt8(ascii: "]") { s.index += 1; return .array(items) }
            while true {
                s.skipWhitespace()
                items.append(try s.parseValue())
                s.skipWhitespace()
                guard s.index < s.bytes.count else { throw s.error("Unterminated array") }
                if s.bytes[s.index] == UInt8(ascii: ",") { s.index += 1; continue }
                if s.bytes[s.index] == UInt8(ascii: "]") { s.index += 1; return .array(items) }
                throw s.error("Expected , or ]")
            }
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try nested { s in
            s.index += 1
            var members: [String: JSONValue] = [:]
            s.skipWhitespace()
            if s.index < s.bytes.count, s.bytes[s.index] == UInt8(ascii: "}") { s.index += 1; return .object(members) }
            while true {
                s.skipWhitespace()
                guard s.index < s.bytes.count, s.bytes[s.index] == UInt8(ascii: "\"") else { throw s.error("Expected a key") }
                let key = try s.parseString()
                s.skipWhitespace()
                guard s.index < s.bytes.count, s.bytes[s.index] == UInt8(ascii: ":") else { throw s.error("Expected :") }
                s.index += 1
                s.skipWhitespace()
                guard members[key] == nil else { throw s.error("Duplicate key \(key)") }
                members[key] = try s.parseValue()
                s.skipWhitespace()
                guard s.index < s.bytes.count else { throw s.error("Unterminated object") }
                if s.bytes[s.index] == UInt8(ascii: ",") { s.index += 1; continue }
                if s.bytes[s.index] == UInt8(ascii: "}") { s.index += 1; return .object(members) }
                throw s.error("Expected , or }")
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard index < bytes.count else { throw error("Unterminated string") }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard let string = String(bytes: buffer, encoding: .utf8) else { throw error("Invalid UTF-8") }
                return string
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw error("Unterminated escape") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw error("Unpaired surrogate")
                        }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("Unpaired surrogate") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw error("Unpaired surrogate")
                    }
                    guard let unicode = Unicode.Scalar(scalar) else { throw error("Invalid escape") }
                    buffer.append(contentsOf: Array(String(Character(unicode)).utf8))
                default:
                    throw error("Invalid escape")
                }
            default:
                guard byte >= 0x20 else { throw error("Control character in string") }
                buffer.append(byte)
                index += 1
            }
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
              text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else {
            throw error("Invalid \\u escape")
        }
        index += 4
        return value
    }
}

/// Writes JSON the way `JSONEncoder` does with `.sortedKeys` and `.withoutEscapingSlashes`, except that numbers
/// are written as their token. Keys sort by UTF-16 code units, the order JavaScript's default sort uses.
enum JSONWriter {
    static func write(_ value: JSONValue, to out: inout String) throws {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let token):
            guard JSONNumberGrammar.isValid(token) else { throw DocDecodingError("Not a JSON number: \(token)") }
            out += token
        case .string(let string): writeString(string, to: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                try write(item, to: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, key) in sortedKeys(members.keys).enumerated() {
                if i > 0 { out += "," }
                writeString(key, to: &out)
                out += ":"
                try write(members[key]!, to: &out)
            }
            out += "}"
        }
    }

    static func sortedKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    static func writeString(_ string: String, to out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
