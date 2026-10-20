import Foundation
import XCTest
import NoteItSync

/// foundations Task 3.5: unknown meta fields survive a re-export.
final class RawMetaOverlayTests: XCTestCase {
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRawMetaOverlayKeepsUnknownFields() throws {
        let last = Data(#"{"futureField":{"a":[1,2]},"id":"X","title":"Old","zzz":true}"#.utf8)
        let encoded = Data(#"{"id":"X","title":"New"}"#.utf8)
        let merged = try RawMetaOverlay(lastDecrypted: last).merged(with: encoded, ownedKeys: ["id", "title"])
        let result = try object(merged)
        XCTAssertEqual(result["title"] as? String, "New")
        XCTAssertEqual((result["futureField"] as? [String: Any])?["a"] as? [Int], [1, 2])
        XCTAssertEqual(result["zzz"] as? Bool, true)
        XCTAssertEqual(String(decoding: merged, as: UTF8.self),
                       #"{"futureField":{"a":[1,2]},"id":"X","title":"New","zzz":true}"#, "sorted keys")
    }

    func testClearedOptionalIsRemoved() throws {
        let last = Data(#"{"conflictSource":"Laptop","futureField":1,"id":"X"}"#.utf8)
        let encoded = Data(#"{"id":"X"}"#.utf8)
        let result = try object(try RawMetaOverlay(lastDecrypted: last)
            .merged(with: encoded, ownedKeys: ["id", "conflictSource"]))
        XCTAssertNil(result["conflictSource"])
        XCTAssertEqual(result["futureField"] as? Int, 1)
    }

    func testNewRecordIsEncodedUnchanged() throws {
        let encoded = Data("{\n  \"id\" : \"X\",\n  \"title\" : \"New\"\n}".utf8)
        XCTAssertEqual(try RawMetaOverlay(lastDecrypted: nil).merged(with: encoded, ownedKeys: ["id", "title"]), encoded)
    }
}
