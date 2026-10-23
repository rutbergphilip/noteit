import Foundation
import NoteItDoc
@testable import NoteItMarkdown

/// The `.md` + `.json` pairs in `Fixtures/`. Names starting with `read-` are parse-only (not in canonical form).
struct MarkdownFixture {
    var name: String
    var markdown: String
    var body: BodyContainer

    var isCanonical: Bool { !name.hasPrefix("read-") }

    static let planID = UUID(uuidString: "8F14E45F-CEEA-467A-9575-5E4F0C6B7A21")!
    static let workPlanID = UUID(uuidString: "1C2B3A49-5D6E-4F70-8192-A3B4C5D6E7F8")!

    /// The wiki-link table the fixtures are written against.
    static func resolveNoteLink(_ target: String) -> UUID? {
        switch target {
        case "Plan": planID
        case "Work/Plan": workPlanID
        default: nil
        }
    }

    static func noteLinkName(_ id: UUID) -> String? {
        switch id {
        case planID: "Plan"
        case workPlanID: "Work/Plan"
        default: nil
        }
    }

    static func load(_ folder: String? = nil) throws -> [MarkdownFixture] {
        var directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
        if let folder { directory.appendPathComponent(folder, isDirectory: true) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .sorted()
        return try names.map { name in
            let markdown = try String(contentsOf: directory.appendingPathComponent(name + ".md"), encoding: .utf8)
            let body = try BodyContainer.decode(Data(contentsOf: directory.appendingPathComponent(name + ".json")))
            return MarkdownFixture(name: name, markdown: markdown, body: body)
        }
    }
}
