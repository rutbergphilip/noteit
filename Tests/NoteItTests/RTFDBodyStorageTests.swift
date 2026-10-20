import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

/// foundations Task 4.1: RTFDBodyStorage against the body storage contract, and byte compatibility with the
/// pre-refactor body code.
@MainActor
final class RTFDBodyStorageTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-rtfd-storage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func testContract() {
        BodyStorageContract.runAll(make: { RTFDBodyStorage(rootURL: $0) })
    }

    func testKind() {
        XCTAssertEqual(RTFDBodyStorage(rootURL: root).kind, .rtfd)
    }

    func testExtrasIgnored() throws {
        let storage = RTFDBodyStorage(rootURL: root)
        let text = NSAttributedString(string: "Title\nbody")
        let plain = BodyStorageContract.noteMeta(notebook: nil), rich = BodyStorageContract.noteMeta(notebook: nil)
        let extras = ContainerExtras(frontMatter: "title: x", extra: ["future": .number("1")])
        try storage.write(text, extras: .empty, for: plain, notebook: nil)
        try storage.write(text, extras: extras, for: rich, notebook: nil)
        XCTAssertEqual(try storage.read(rich.id).extras, .empty)
        XCTAssertEqual(try packageFiles(storage.fileURL(for: rich.id)), try packageFiles(storage.fileURL(for: plain.id)))
    }

    func testLayoutUnchanged() throws {
        let storage = RTFDBodyStorage(rootURL: root)
        let meta = BodyStorageContract.noteMeta(notebook: nil)
        try storage.write(NSAttributedString(string: "Body"), extras: .empty, for: meta, notebook: nil)
        XCTAssertEqual(storage.contentRootURL.standardizedFileURL, root.appendingPathComponent("notes").standardizedFileURL)
        XCTAssertEqual(storage.fileURL(for: meta.id).lastPathComponent, "\(meta.id.uuidString).rtfd")
        try storage.moveToTrash(meta.id)
        let trashed = try fm.contentsOfDirectory(atPath: root.appendingPathComponent(".trash").path)
        XCTAssertEqual(trashed.count, 1)
        XCTAssertTrue(trashed[0].hasPrefix("\(meta.id.uuidString)-") && trashed[0].hasSuffix(".rtfd"), trashed[0])
    }

    /// The fixture was written by the pre-refactor code: a library with a plain note and a note with an image
    /// attachment, and the content revisions that code derived for them.
    func testContentRevisionsMatchPreRefactorFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/golden/rtfd-content-revisions.json")
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let cases = try XCTUnwrap(golden["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for (index, testCase) in cases.enumerated() {
            let library = root.appendingPathComponent("case-\(index)", isDirectory: true)
            try fm.createDirectory(at: library, withIntermediateDirectories: true)
            let libraryData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(testCase["library"] as? String)))
            try libraryData.write(to: library.appendingPathComponent("library.json"))
            for (path, base64) in try XCTUnwrap(testCase["files"] as? [String: String]) {
                let url = library.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
            }
            let expected = try XCTUnwrap(testCase["revisions"] as? [String: String])
            let store = NoteStore(location: LibraryLocation(url: library, seedsFreshLibrary: false))
            let revisions = NoteStore.contentRevisions(for: store.missingRevisionInputs())
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: revisions.map { ($0.key.uuidString, $0.value.uuidString) }),
                           expected)
            XCTAssertTrue(store.notes.contains { fm.fileExists(atPath: store.bodyURL(for: $0.id).appendingPathComponent("image.png").path) },
                          "the fixture has a note with an image attachment")
        }
    }

    private func packageFiles(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try fm.subpathsOfDirectory(atPath: url.path) {
            var isDir: ObjCBool = false
            let item = url.appendingPathComponent(path)
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue {
                result[path] = try Data(contentsOf: item)
            }
        }
        return result
    }
}
