import NoteItCore
import XCTest

final class ModelCodingTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let fullNote = """
    {"id":"6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","notebookID":"0B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F",
     "title":"Groceries","preview":"Milk","isPinned":true,"createdAt":"2026-01-02T03:04:05Z",
     "updatedAt":"2026-01-03T03:04:05Z","tags":["home"],"revision":"1B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F",
     "conflictSource":"Laptop","conflictOriginalID":"2B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F",
     "deletedAt":"2026-01-04T03:04:05Z",
     "lock":{"keyID":"key-1","sealedID":"3B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F"}}
    """

    private let minimalNote = """
    {"id":"6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","title":"","preview":"","isPinned":false,
     "createdAt":"2026-01-02T03:04:05Z","updatedAt":"2026-01-03T03:04:05Z","tags":[]}
    """

    private let fullNotebook = """
    {"id":"0B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","name":"Inbox","symbol":"tray","colorHex":"#0A84FF",
     "sortIndex":2,"revision":"1B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","modifiedAt":"2026-01-02T03:04:05Z",
     "defaultTemplateID":"2B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","parent":"3B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F"}
    """

    private let minimalNotebook = """
    {"id":"0B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","name":"Inbox","symbol":"tray","colorHex":"#0A84FF","sortIndex":0,"parent":null}
    """

    func testNoteMetaDecodesAndKeepsKeys() throws {
        let full = try decoder.decode(NoteMeta.self, from: Data(fullNote.utf8))
        XCTAssertEqual(full.title, "Groceries")
        XCTAssertEqual(full.conflictSource, "Laptop")
        XCTAssertNotNil(full.deletedAt)
        XCTAssertTrue(full.isLocked)
        try assertSameKeys(fullNote, try encoder.encode(full))

        let minimal = try decoder.decode(NoteMeta.self, from: Data(minimalNote.utf8))
        XCTAssertNil(minimal.notebookID)
        XCTAssertNil(minimal.revision)
        XCTAssertNil(minimal.deletedAt)
        try assertSameKeys(minimalNote, try encoder.encode(minimal))
    }

    func testNotebookDecodesAndKeepsKeys() throws {
        let full = try decoder.decode(Notebook.self, from: Data(fullNotebook.utf8))
        XCTAssertEqual(full.sortIndex, 2)
        XCTAssertNotNil(full.modifiedAt)
        try assertSameKeys(fullNotebook, try encoder.encode(full))

        let minimal = try decoder.decode(Notebook.self, from: Data(minimalNotebook.utf8))
        XCTAssertNil(minimal.revision)
        XCTAssertNil(minimal.modifiedAt)
        try assertSameKeys(minimalNotebook, try encoder.encode(minimal))
    }

    func testNotebookWithoutParentKeyIsTopLevelAndGainsTheKey() throws {
        let legacy = Data(##"{"id":"0B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","name":"A","symbol":"tray","colorHex":"#0A84FF","sortIndex":0}"##.utf8)
        XCTAssertFalse(Notebook.recordHasParentKey(legacy))
        let notebook = try decoder.decode(Notebook.self, from: legacy)
        XCTAssertNil(notebook.parent)
        let encoded = try encoder.encode(notebook)
        XCTAssertTrue(Notebook.recordHasParentKey(encoded))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""parent":null"#))
    }

    func testDisplayTitleOfEmptyTitle() {
        let now = Date()
        var note = NoteMeta(id: UUID(), notebookID: nil, title: "", preview: "", isPinned: false,
                            createdAt: now, updatedAt: now, tags: [])
        XCTAssertEqual(note.displayTitle, "New Note")
        note.title = "Plan"
        XCTAssertEqual(note.displayTitle, "Plan")
    }

    func testOwnedCodingKeysMatchEncodedKeys() throws {
        let note = try decoder.decode(NoteMeta.self, from: Data(fullNote.utf8))
        XCTAssertNotNil(note.notebookID)
        XCTAssertNotNil(note.revision)
        XCTAssertNotNil(note.conflictOriginalID)
        let noteKeys = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(note)) as? [String: Any]).keys
        XCTAssertEqual(Set(noteKeys), NoteMeta.ownedCodingKeys)

        let notebook = try decoder.decode(Notebook.self, from: Data(fullNotebook.utf8))
        XCTAssertNotNil(notebook.revision)
        XCTAssertNotNil(notebook.modifiedAt)
        let notebookKeys = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(notebook)) as? [String: Any]).keys
        XCTAssertEqual(Set(notebookKeys), Notebook.ownedCodingKeys)
    }

    private func assertSameKeys(_ json: String, _ encoded: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let roundTripped = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(original.keys), Set(roundTripped.keys), file: file, line: line)
    }
}
