import XCTest
@testable import NoteItMarkdown

final class AttachmentPathsTests: XCTestCase {
    func testFileNameUsesTwelveHexAndASanitizedName() {
        let sha = "3F9A1C2B7D10" + String(repeating: "0", count: 52)
        XCTAssertEqual(AttachmentPaths.fileName(sha256: sha, originalName: "photo.jpg"), "3f9a1c2b7d10-photo.jpg")
        XCTAssertEqual(AttachmentPaths.fileName(sha256: sha, originalName: "a/b:c?.pdf"), "3f9a1c2b7d10-a-b-c-.pdf")
        XCTAssertEqual(AttachmentPaths.fileName(sha256: sha, originalName: ""), "3f9a1c2b7d10-attachment")
    }

    func testRelativePathClimbsOutOfNotebookFolders() {
        XCTAssertEqual(AttachmentPaths.relativePath(fromNoteAt: "Note.md", fileName: "x.png"), "_attachments/x.png")
        XCTAssertEqual(AttachmentPaths.relativePath(fromNoteAt: "Work/Note.md", fileName: "x.png"), "../_attachments/x.png")
        XCTAssertEqual(AttachmentPaths.relativePath(fromNoteAt: "Work/2026/Note.md", fileName: "x.png"), "../../_attachments/x.png")
    }

    func testResolveStaysInsideTheContentFolder() {
        XCTAssertEqual(AttachmentPaths.resolve("../_attachments/x%20y.png", fromNoteAt: "Work/Note.md"), "_attachments/x y.png")
        XCTAssertEqual(AttachmentPaths.resolve("./img.png", fromNoteAt: "Work/Note.md"), "Work/img.png")
        XCTAssertNil(AttachmentPaths.resolve("../x.png", fromNoteAt: "Note.md"))
        XCTAssertNil(AttachmentPaths.resolve("/etc/passwd", fromNoteAt: "Note.md"))
        XCTAssertNil(AttachmentPaths.resolve("https://example.com/x.png", fromNoteAt: "Note.md"))
        XCTAssertEqual(AttachmentPaths.resolve(decoded: "../_attachments/x%20y.png", fromNoteAt: "Work/Note.md"), "_attachments/x%20y.png")
        XCTAssertNil(AttachmentPaths.resolve(decoded: "../x.png", fromNoteAt: "Note.md"))
    }
}
