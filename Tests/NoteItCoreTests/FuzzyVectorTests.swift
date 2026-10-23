import Foundation
import XCTest
@testable import NoteItCore

/// Vectors/fuzzy-vectors.json, which the web's port (`web/packages/doc/test/fuzzy.test.ts`) reads too, so the
/// command palette matches and ranks the same on both.
final class FuzzyVectorTests: XCTestCase {
    func testSharedVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fuzzy-vectors", withExtension: "json", subdirectory: "Vectors"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            let query = try XCTUnwrap(vector["query"] as? String)
            let candidate = try XCTUnwrap(vector["candidate"] as? String)
            let result = FuzzyMatcher.evaluate(FuzzyQuery(query), in: candidate)
            if vector["match"] as? Bool == false {
                XCTAssertNil(result, "\(query) in \(candidate)")
                continue
            }
            let got = try XCTUnwrap(result, "\(query) in \(candidate)")
            XCTAssertEqual(got.match.score, vector["score"] as? Int, "\(query) in \(candidate)")
            XCTAssertEqual(got.match.matchedIndices, vector["indices"] as? [Int], "\(query) in \(candidate)")
            XCTAssertEqual(got.isExact, vector["exact"] as? Bool, "\(query) in \(candidate)")
        }
    }
}
