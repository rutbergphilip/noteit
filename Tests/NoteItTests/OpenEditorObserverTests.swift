import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

/// foundations Task 4.5: read-only observers in `OpenEditorRegistry` (program §6).
@MainActor
final class OpenEditorObserverTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let harness = EditorHarness()
    private var tokens: [UUID] = []

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-observer-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        for token in tokens { OpenEditorRegistry.shared.removeObserver(token) }
        harness.close()
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    private func observe(_ id: UUID, into received: @escaping (String) -> Void) -> UUID {
        let token = OpenEditorRegistry.shared.registerObserver({ received($0.string) }, for: id)
        tokens.append(token)
        return token
    }

    func testObserverIsNeverAnEditor() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Body")).id
        _ = observe(id) { _ in }
        XCTAssertNil(OpenEditorRegistry.shared.textView(for: id))
        XCTAssertTrue(OpenEditorRegistry.shared.textViews(for: id).isEmpty)
        let editor = harness.open(store, id)
        XCTAssertTrue(OpenEditorRegistry.shared.textView(for: id) === editor.view)
        XCTAssertEqual(OpenEditorRegistry.shared.textViews(for: id).count, 1)
    }

    func testTypingReachesObserverBeforeSaving() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Body")).id
        store.flush()
        let editor = harness.open(store, id)
        var received: [String] = []
        _ = observe(id) { received.append($0) }

        EditorHarness.type(" typed", in: editor.view)
        XCTAssertEqual(received.last, "Body typed")
        XCTAssertTrue(editor.coordinator.hasPendingChanges, "not saved yet")
        XCTAssertEqual(store.body(for: id).string, "Body")
    }

    func testClosedEditBodyPassesSavedBody() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Body")).id
        store.flush()
        var received: [String] = []
        _ = observe(id) { received.append($0) }
        try store.editBody(id, actionName: "Edit") { $0.append(NSAttributedString(string: "\nadded")) }
        XCTAssertEqual(received, ["Body\nadded"])
    }

    func testRemovedObserverIsNotCalled() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Body")).id
        store.flush()
        let editor = harness.open(store, id)
        var received: [String] = []
        let token = observe(id) { received.append($0) }
        OpenEditorRegistry.shared.removeObserver(token)

        EditorHarness.type(" typed", in: editor.view)
        try store.editBody(id, actionName: "Edit") { $0.append(NSAttributedString(string: "\nadded")) }
        XCTAssertTrue(received.isEmpty)
    }

    func testEditorUnregisterStopsWatching() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Body")).id
        store.flush()
        let editor = harness.open(store, id)
        var received: [String] = []
        _ = observe(id) { received.append($0) }
        OpenEditorRegistry.shared.unregister(editor.view)
        EditorHarness.type(" typed", in: editor.view)
        XCTAssertTrue(received.isEmpty)
    }
}
