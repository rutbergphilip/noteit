import Foundation

/// An attachment stored inside a body container, keyed by the lowercase hex SHA-256 of `data`. Shape owned by the
/// web-app plan (`@noteit/doc`); built in foundations Task 2.1. `data` is base64 in JSON.
public struct Attachment: Codable, Equatable, Sendable {
    public var mime: String
    public var name: String
    public var data: Data

    public init(mime: String, name: String, data: Data) {
        self.mime = mime
        self.name = name
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    init(json: JSONValue) throws {
        let fields = try JSONFields(json, context: "attachment")
        guard let data = Data(base64Encoded: try fields.string("data")) else {
            throw DocDecodingError("attachment: data is not base64")
        }
        self.init(mime: try fields.string("mime"), name: try fields.string("name"), data: data)
    }

    var json: JSONValue {
        .object(["mime": .string(mime), "name": .string(name), "data": .string(data.base64EncodedString())])
    }
}
