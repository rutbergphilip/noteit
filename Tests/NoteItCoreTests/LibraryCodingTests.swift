import NoteItCore
import XCTest

final class LibraryCodingTests: XCTestCase {
    private let library = """
    {
      "notebooks" : [
        {
          "colorHex" : "#0A84FF",
          "id" : "0B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F",
          "name" : "Inbox",
          "revision" : "1B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F",
          "sortIndex" : 0,
          "symbol" : "tray"
        }
      ],
      "notes" : [
        {
          "createdAt" : "2026-01-02T03:04:05Z",
          "deletedAt" : "2026-01-04T03:04:05Z",
          "id" : "6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F",
          "isPinned" : true,
          "notebookID" : "0B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F",
          "preview" : "Milk and eggs",
          "tags" : [
            "home"
          ],
          "title" : "Groceries",
          "updatedAt" : "2026-01-03T03:04:05Z"
        }
      ],
      "version" : 1
    }
    """

    func testLibraryRoundTripsByteForByte() throws {
        let decoded = try LibraryCoding.decode(Data(library.utf8))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.notebooks.map(\.name), ["Inbox"])
        XCTAssertEqual(decoded.notes.map(\.title), ["Groceries"])
        let encoded = try LibraryCoding.encoder.encode(decoded)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), library)
    }

    func testTruncatedLibrarySalvagesNotebooks() throws {
        let cut = library.range(of: "\"title\" : \"Groceries\"")!.lowerBound
        let truncated = Data(library[..<cut].utf8)
        XCTAssertThrowsError(try LibraryCoding.decode(truncated))
        let partial = try XCTUnwrap(LibraryCoding.salvage(Data(salvageable.utf8)))
        XCTAssertEqual(partial.notebooks?.map(\.name), ["Inbox"])
        XCTAssertNil(partial.notes)
    }

    func testUnknownTopLevelKeysDoNotStopDecoding() throws {
        let extended = library.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 1,\n  \"future\" : {\"x\" : [1, 2]}")
        let decoded = try LibraryCoding.decode(Data(extended.utf8))
        XCTAssertEqual(decoded.notes.count, 1)
        XCTAssertEqual(LibraryCoding.salvage(Data(extended.utf8))?.notebooks?.count, 1)
    }

    // A library whose notes array no longer decodes but whose notebooks still do.
    private var salvageable: String {
        library.replacingOccurrences(of: "\"isPinned\" : true", with: "\"isPinned\" : \"yes\"")
    }
}
