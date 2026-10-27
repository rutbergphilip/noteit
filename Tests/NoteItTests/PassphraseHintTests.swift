@testable import NoteIt
import XCTest

final class PassphraseHintTests: XCTestCase {
    func testTheHintIsTheSpecText() {
        // Copied from web-app spec §7; the web app shows the same words under its passphrase fields.
        XCTAssertEqual(PassphraseHint.text,
                       "Type it exactly as on your other devices. Letters with accents can differ between keyboards.")
    }
}
