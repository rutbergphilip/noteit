import AppKit
import XCTest
@testable import NoteIt

/// Link to Note… and the `[[` list in a real editor text view.
@MainActor
final class InlineLinkCompletionTests: XCTestCase {
    private final class Host: NoteLinkHost {
        let store: NoteStore
        let noteID: UUID
        init(store: NoteStore, noteID: UUID) {
            self.store = store
            self.noteID = noteID
        }
    }

    private var base: URL!
    private var window: NSWindow!
    private var textView: NoteItTextView!
    private var host: Host!

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-inline-\(UUID().uuidString)", isDirectory: true)
        let store = NoteStore(location: LibraryLocation(url: base.appendingPathComponent("Library", isDirectory: true), seedsFreshLibrary: false))
        host = Host(store: store, noteID: store.createNote(in: nil, initial: EditorStyle.paragraph("Hello", kind: .body)).id)
        let (scrollView, textView) = NoteItTextView.make()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        self.textView = textView
        textView.linkHost = host
        textView.allowsUndo = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: "Hello", attributes: EditorStyle.bodyAttributes))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
    }

    override func tearDown() {
        textView.inlineCompletion.end()
        window.close()
        try? FileManager.default.removeItem(at: base)
    }

    func testBackspaceIntoOpeningAtEndOfNoteDoesNotCrash() {
        textView.linkToNote(nil)
        XCTAssertEqual(textView.string, "Hello[[")
        XCTAssertTrue(textView.inlineCompletion.isActive)
        textView.deleteBackward(nil)
        textView.inlineCompletion.refresh()
        XCTAssertFalse(textView.inlineCompletion.isActive)
        XCTAssertEqual(textView.string, "Hello[")
    }

    func testUndoOfOpeningAtEndOfNoteDoesNotCrash() {
        textView.linkToNote(nil)
        textView.storage.replaceCharacters(in: NSRange(location: 5, length: 2), with: "")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.inlineCompletion.refresh()
        XCTAssertFalse(textView.inlineCompletion.isActive)
        XCTAssertEqual(textView.string, "Hello")
    }

    func testEscapeRemovesTheInsertedOpening() {
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        textView.linkToNote(nil)
        XCTAssertEqual(textView.string, "[[Hello")
        XCTAssertTrue(textView.inlineCompletion.handle(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testUndoOfOpeningKeepsTheUsersOwnBrackets() throws {
        textView.textStorage?.setAttributedString(NSAttributedString(string: "abc[[x", attributes: EditorStyle.bodyAttributes))
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let undo = try XCTUnwrap(textView.undoManager)
        undo.removeAllActions()
        textView.linkToNote(nil)
        XCTAssertEqual(textView.string, "abc[[[[x")
        EditorHarness.settle(undo)
        let token = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: nil) { [textView] _ in
            MainActor.assumeIsolated { textView?.inlineCompletion.refresh() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        undo.undo()
        XCTAssertFalse(textView.inlineCompletion.isActive)
        XCTAssertEqual(textView.string, "abc[[x")
    }

    private func openList() {
        _ = host.store.createNote(in: nil, initial: EditorStyle.paragraph("Atlas", kind: .title))
        window.makeFirstResponder(textView)
        textView.linkToNote(nil)
        XCTAssertTrue(textView.inlineCompletion.isActive)
        XCTAssertEqual(window.childWindows?.count, 1)
    }

    func testLeavingTheEditorClosesTheList() {
        openList()
        window.makeFirstResponder(nil)
        XCTAssertFalse(textView.inlineCompletion.isActive)
        XCTAssertEqual(window.childWindows?.count ?? 0, 0)
        XCTAssertEqual(textView.string, "Hello")
    }

    func testRemovingTheEditorClosesTheList() {
        openList()
        textView.enclosingScrollView?.removeFromSuperview()
        XCTAssertFalse(textView.inlineCompletion.isActive)
        XCTAssertEqual(window.childWindows?.count ?? 0, 0)
    }

    func testSwitchingNotesTakesTheOpeningBack() async throws {
        let store = host.store
        let coordinator = RichTextEditor.Coordinator(noteID: host.noteID, controller: EditorController(), store: store)
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.linkHost = coordinator
        textView.storage.append(NSAttributedString(string: " world", attributes: EditorStyle.bodyAttributes))
        textView.setSelectedRange(NSRange(location: textView.storage.length, length: 0))
        openList()
        XCTAssertEqual(textView.string, "Hello world[[")
        RichTextEditor.dismantleNSView(try XCTUnwrap(textView.enclosingScrollView), coordinator: coordinator)
        XCTAssertFalse(textView.inlineCompletion.isActive)
        XCTAssertEqual(window.childWindows?.count ?? 0, 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.body(for: host.noteID).string, "Hello world")
    }
}

