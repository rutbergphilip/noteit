import Foundation

/// Reads and writes the cross-language golden vector files in `fixtures/golden`. Owned by the foundations plan
/// (Task 2.2); the file shape `{ "generator", "version": 1, "cases": [...] }` is the web-app plan's.
public enum GoldenFixtures {
    /// `<repo>/fixtures/golden`.
    public static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/golden", isDirectory: true)
    }

    /// Decodes a whole vector file, for example `GoldenFile<MyCase>`.
    public static func load<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url(name)))
    }

    /// Writes a vector file with sorted keys and a trailing newline. Throws unless `NOTEIT_WRITE_VECTORS=1`, so a
    /// normal test run never changes the fixtures.
    public static func write<T: Encodable>(_ value: T, to name: String) throws {
        guard ProcessInfo.processInfo.environment["NOTEIT_WRITE_VECTORS"] == "1" else { throw WritingDisabled(name: name) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(name), options: .atomic)
    }

    /// Whether this run may rewrite vector files.
    public static var isWriting: Bool {
        ProcessInfo.processInfo.environment["NOTEIT_WRITE_VECTORS"] == "1"
    }

    public struct WritingDisabled: Error, CustomStringConvertible {
        public var name: String
        public var description: String { "Set NOTEIT_WRITE_VECTORS=1 to write \(name)" }
    }

    private static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name.hasSuffix(".json") ? name : name + ".json")
    }
}

/// The common shape of every golden vector file.
public struct GoldenFile<Case: Codable>: Codable {
    public var generator: String
    public var version: Int
    public var cases: [Case]

    public init(generator: String, version: Int = 1, cases: [Case]) {
        self.generator = generator
        self.version = version
        self.cases = cases
    }
}
