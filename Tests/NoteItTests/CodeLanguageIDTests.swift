import AppKit
import XCTest
@testable import NoteIt

@MainActor
final class CodeLanguageIDTests: XCTestCase {
    private func textView(language: String) throws -> NoteItTextView {
        let doc = BodyContainer(doc: .doc([.codeBlock(align: nil, language: language, content: [.text("ab", marks: [])])]))
        let (_, textView) = NoteItTextView.make()
        textView.storage.setAttributedString(try DocConverter.importDocument(doc, styles: AppDocStyleProvider.shared))
        textView.normalizePendingEdits()
        return textView
    }

    private func exported(_ textView: NoteItTextView) throws -> DocNode {
        try DocConverter.export(textView.attributedString(), styles: AppDocStyleProvider.shared).doc
    }

    func testLanguageSurvivesTyping() throws {
        for language in ["swift", "zig-nightly"] {
            let view = try textView(language: language)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            view.insertText("x", replacementRange: view.selectedRange())
            XCTAssertEqual(try exported(view), .doc([.codeBlock(align: nil, language: language, content: [.text("axb", marks: [])])]), language)
        }
    }

    func testChoosingALanguageOverwritesTheID() throws {
        let view = try textView(language: "zig-nightly")
        view.codeStyler.setLanguage(.python, forBlockAt: 0)
        XCTAssertEqual(try exported(view), .doc([.codeBlock(align: nil, language: "python", content: [.text("ab", marks: [])])]))

        view.codeStyler.setLanguage(nil, forBlockAt: 0)
        XCTAssertEqual(try exported(view), .doc([.codeBlock(align: nil, language: nil, content: [.text("ab", marks: [])])]))
    }

    func testLeavingCodeDropsTheID() throws {
        let view = try textView(language: "zig-nightly")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.perform(.block(.body))
        guard case .doc(let blocks) = try exported(view) else { return XCTFail() }
        XCTAssertFalse(blocks.contains { if case .codeBlock = $0 { true } else { false } }, "\(blocks)")
        var found = false
        view.storage.enumerateAttribute(.noteItCodeLanguageID, in: NSRange(location: 0, length: view.storage.length)) { value, _, _ in
            if value != nil { found = true }
        }
        XCTAssertFalse(found)
    }
}
