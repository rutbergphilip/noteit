import Foundation
import XCTest
@testable import NoteItCore

final class QueryRewriterTests: XCTestCase {
    func testRenamesTagAndNestedTags() {
        XCTAssertEqual(QueryRewriter.renamingTag("work", to: "job", in: "tag:work -tag:work/acme tag:workshop work"),
                       "tag:job -tag:job/acme tag:workshop work")
        XCTAssertEqual(QueryRewriter.renamingTag("work", to: "job", in: "TAG:#Work"), "TAG:#job")
    }

    func testRenamesNotebookKeepingQuotes() {
        XCTAssertEqual(QueryRewriter.renamingNotebook("Work", to: "Client Work", in: "in:work notebook:\"Work/Acme\" x"),
                       "in:\"Client Work\" notebook:\"Client Work/Acme\" x")
        XCTAssertEqual(QueryRewriter.renamingNotebook("Client Work", to: "Office", in: "notebook:\"Client Work\""),
                       "notebook:\"Office\"")
        XCTAssertEqual(QueryRewriter.renamingNotebook("Work", to: "Job", in: "notebook:Workshop"), "notebook:Workshop")
    }
}
