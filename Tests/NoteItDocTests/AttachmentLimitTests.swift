import NoteItDoc
import XCTest

final class AttachmentLimitTests: XCTestCase {
    func testLimit() {
        XCTAssertEqual(AttachmentLimit.maxBytes, 26_214_400)
        XCTAssertTrue(AttachmentLimit.allows(byteCount: 26_214_400))
        XCTAssertFalse(AttachmentLimit.allows(byteCount: 26_214_401))
        XCTAssertEqual(AttachmentLimit.tooLargeMessage(name: "Scan.tiff"),
                       "“Scan.tiff” is too large to add. Attachments can be up to 25 MB.")
    }
}
