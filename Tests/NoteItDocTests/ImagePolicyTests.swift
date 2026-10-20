import NoteItDoc
import XCTest

final class ImagePolicyTests: XCTestCase {
    func testRoundTripsByRawValue() throws {
        for policy in [ImagePolicy.normalize, .keepOriginal] {
            let data = try JSONEncoder().encode([policy])
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"\(policy.rawValue)\"]")
            XCTAssertEqual(try JSONDecoder().decode([ImagePolicy].self, from: data), [policy])
        }
        XCTAssertEqual(ImagePolicy.normalize.rawValue, "normalize")
        XCTAssertEqual(ImagePolicy.keepOriginal.rawValue, "keepOriginal")
    }
}
