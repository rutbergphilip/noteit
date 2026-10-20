import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItSync

/// An RTFD store's storage that counts body installs, so tests can see a change go out in one write.
final class CountingRTFDStorage: NoteBodyStorage, @unchecked Sendable {
    let base: RTFDBodyStorage
    private(set) var installs = 0

    init(rootURL: URL) {
        base = RTFDBodyStorage(rootURL: rootURL)
    }

    var kind: LibraryFormatKind { base.kind }
    var contentRootURL: URL { base.contentRootURL }
    func idsOnDisk() -> [UUID] { base.idsOnDisk() }
    func read(_ id: UUID) throws -> StoredBody { try base.read(id) }
    func write(_ text: NSAttributedString, extras: ContainerExtras, for note: NoteMeta, notebook: Notebook?) throws {
        installs += 1
        try base.write(text, extras: extras, for: note, notebook: notebook)
    }
    func writeMetadataOnly(for note: NoteMeta, notebook: Notebook?) throws {
        try base.writeMetadataOnly(for: note, notebook: notebook)
    }
    func prepareTemp(_ text: NSAttributedString, extras: ContainerExtras, for id: UUID) throws -> URL {
        try base.prepareTemp(text, extras: extras, for: id)
    }
    func installTemp(_ temp: URL, for note: NoteMeta, notebook: Notebook?) throws {
        installs += 1
        try base.installTemp(temp, for: note, notebook: notebook)
    }
    func moveToTrash(_ id: UUID) throws { try base.moveToTrash(id) }
    func recover(_ id: UUID) throws -> StoredBody? { try base.recover(id) }
    func removePermanently(_ id: UUID) throws { try base.removePermanently(id) }
    func revisionInputURL(for id: UUID) -> URL? { base.revisionInputURL(for: id) }
    func fileURL(for id: UUID) -> URL { base.fileURL(for: id) }
    func recoveryCopy(_ text: NSAttributedString, for id: UUID, in directory: URL) throws -> URL {
        try base.recoveryCopy(text, for: id, in: directory)
    }
    func renameNotebook(_ notebook: Notebook, from oldName: String) throws {}
    func removeNotebook(_ notebook: Notebook) throws {}
}

/// Offscreen editors wired like `RichTextEditor` does, against a test store.
@MainActor
final class EditorHarness {
    struct Editor {
        let view: NoteItTextView
        let coordinator: RichTextEditor.Coordinator
        let window: NSWindow
    }

    private(set) var editors: [Editor] = []

    func open(_ store: NoteStore, _ id: UUID) -> Editor {
        let (scrollView, view) = NoteItTextView.make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        let coordinator = RichTextEditor.Coordinator(noteID: id, controller: EditorController(), store: store)
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.controller.textView = view
        coordinator.load()
        coordinator.observeLifecycle()
        OpenEditorRegistry.shared.register(view, for: id)
        let editor = Editor(view: view, coordinator: coordinator, window: window)
        editors.append(editor)
        return editor
    }

    func close() {
        for editor in editors {
            editor.coordinator.stopObserving()
            OpenEditorRegistry.shared.unregister(editor.view)
            editor.view.delegate = nil
            editor.window.close()
        }
        editors = []
    }

    /// Types `text` at the end, as the user would; the edit stays unsaved until the editor commits.
    static func type(_ text: String, in view: NoteItTextView) {
        let end = NSRange(location: view.storage.length, length: 0)
        view.setSelectedRange(end)
        view.insertText(text, replacementRange: end)
    }

    /// Ends the event undo group the run loop would close, so the next undo() sees the finished step.
    static func settle(_ undo: UndoManager?) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        guard let undo else { return }
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
    }
}

/// foundations Task 4.5: `editBody`, Restore Version through it, and versions that keep extras.
@MainActor
final class BodyEditTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let harness = EditorHarness()
    private let extrasA = ContainerExtras(frontMatter: "title: A", extra: ["futureA": .string("a")])
    private let extrasB = ContainerExtras(frontMatter: "title: B", extra: ["futureB": .number("2")])

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-bodyedit-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        harness.close()
        try? fm.removeItem(at: root)
    }

    private func makeStore(storage: NoteBodyStorage? = nil) -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false), bodyStorage: storage)
        store.history.now = { [unowned self] in self.clock }
        return store
    }

    private func makeCountingStore() -> (NoteStore, CountingRTFDStorage) {
        let storage = CountingRTFDStorage(rootURL: root)
        return (makeStore(storage: storage), storage)
    }

    private func savedNote(_ store: NoteStore, _ text: String) -> UUID {
        let id = store.createNote(in: nil, initial: NSAttributedString(string: text)).id
        store.flush()
        return id
    }

    private func saveNote(_ store: NoteStore, _ text: NSAttributedString, extras: ContainerExtras) -> UUID {
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "placeholder")).id
        store.flush()
        store.setBodyExtras(extras, for: id)
        store.updateBody(id, text)
        store.flush()
        return id
    }

    private func codeText(_ languages: [String?], title: String = "Title") throws -> NSAttributedString {
        var blocks: [DocNode] = [.paragraph(align: nil, indent: nil, content: [.text(title, marks: [])])]
        for (index, language) in languages.enumerated() {
            blocks.append(.codeBlock(align: nil, language: language, content: [.text("code \(index)", marks: [])]))
            blocks.append(.paragraph(align: nil, indent: nil, content: [.text("after \(index)", marks: [])]))
        }
        return try DocConverter.importDocument(BodyContainer(doc: .doc(blocks)), styles: AppDocStyleProvider.shared)
    }

    private func languageIDs(_ text: NSAttributedString) -> [String?] {
        NoteStore.codeLanguageIDs(of: text)
    }

    private func readSidecar(_ store: NoteStore, _ id: UUID) throws -> BodyExtrasSidecar {
        try BodyExtrasSidecar.decode(Data(contentsOf: store.bodyExtrasFileURL(id)))
    }

    private func versionTexts(_ store: NoteStore, _ id: UUID) throws -> [String] {
        try store.versions(of: id).map { try store.history.load($0).text.string }
    }

    private func appendLine(_ line: String) -> (NSMutableAttributedString) -> Void {
        { $0.append(NSAttributedString(string: "\n\(line)")) }
    }

    private func packageFiles(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try fm.subpathsOfDirectory(atPath: url.path) {
            var isDir: ObjCBool = false
            let item = url.appendingPathComponent(path)
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue {
                result[path] = try Data(contentsOf: item)
            }
        }
        return result
    }

    // MARK: Closed and open paths

    func testClosedPathChangesBodyAddsOneVersionAndAnnounces() throws {
        let store = makeStore()
        let id = savedNote(store, "Title\nbody")
        try store.editBody(id, actionName: "Append") { $0.append(NSAttributedString(string: "\nmore")) }
        XCTAssertEqual(store.body(for: id).string, "Title\nbody\nmore")
        XCTAssertEqual(try NoteStore.readBody(at: store.bodyURL(for: id)).string, "Title\nbody\nmore")
        XCTAssertFalse(store.isBodyDirty(id))
        XCTAssertEqual(try versionTexts(store, id), ["Title\nbody"])
        XCTAssertEqual(store.externallyUpdatedNoteID, id)
    }

    func testOpenPathRecordsOneVersionAsOneUndoStep() throws {
        let store = makeStore()
        let id = savedNote(store, "Title\nbody")
        let editor = harness.open(store, id)
        let undo = try XCTUnwrap(editor.view.undoManager)
        try store.editBody(id, actionName: "Append Line", appendLine("more"))
        EditorHarness.settle(undo)

        XCTAssertEqual(editor.view.string, "Title\nbody\nmore")
        XCTAssertEqual(try NoteStore.readBody(at: store.bodyURL(for: id)).string, "Title\nbody\nmore")
        XCTAssertEqual(try versionTexts(store, id), ["Title\nbody"])
        XCTAssertEqual(store.externallyUpdatedNoteID, id)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "Append Line")

        undo.undo()
        XCTAssertEqual(editor.view.string, "Title\nbody")
        XCTAssertFalse(undo.canUndo, "the edit was one undo step")
        editor.coordinator.commit()
        XCTAssertEqual(store.body(for: id).string, "Title\nbody")
    }

    func testVersioningNoneRecordsNothing() throws {
        let store = makeStore()
        // editBody itself records nothing; the save's own throttled history (unchanged) may still keep the old body.
        var recorded = 0
        store.recordVersionOverride = { _, _ in recorded += 1; return nil }
        let closed = savedNote(store, "Closed")
        try store.editBody(closed, actionName: "Edit", versioning: .none, appendLine("x"))
        XCTAssertEqual(store.body(for: closed).string, "Closed\nx")

        let open = savedNote(store, "Open")
        let editor = harness.open(store, open)
        try store.editBody(open, actionName: "Edit", versioning: .none, appendLine("y"))
        XCTAssertEqual(editor.view.string, "Open\ny")
        XCTAssertEqual(store.body(for: open).string, "Open\ny")
        XCTAssertEqual(recorded, 0)
    }

    func testUnchangedEditWritesNothing() throws {
        let store = makeStore()
        let id = savedNote(store, "Same")
        let revision = store.note(with: id)?.revision
        try store.editBody(id, actionName: "Nothing") { _ in }
        try store.editBody(id, actionName: "Nothing", extras: .empty) { _ in }
        XCTAssertTrue(store.versions(of: id).isEmpty)
        XCTAssertEqual(store.note(with: id)?.revision, revision)
        XCTAssertNil(store.externallyUpdatedNoteID)

        let editor = harness.open(store, id)
        let undo = try XCTUnwrap(editor.view.undoManager)
        try store.editBody(id, actionName: "Nothing") { $0.setAttributedString($0) }
        EditorHarness.settle(undo)
        XCTAssertTrue(store.versions(of: id).isEmpty)
        XCTAssertFalse(undo.canUndo)
        XCTAssertEqual(store.note(with: id)?.revision, revision)
    }

    func testThrowingEditLeavesBodyUnchanged() throws {
        struct Failure: Error {}
        let store = makeStore()
        let id = savedNote(store, "Kept")
        XCTAssertThrowsError(try store.editBody(id, actionName: "Fail") { text in
            text.append(NSAttributedString(string: " changed"))
            throw Failure()
        }) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(store.body(for: id).string, "Kept")
        XCTAssertTrue(store.versions(of: id).isEmpty)

        let editor = harness.open(store, id)
        XCTAssertThrowsError(try store.editBody(id, actionName: "Fail") { _ in throw Failure() })
        XCTAssertEqual(editor.view.string, "Kept")
        XCTAssertTrue(store.versions(of: id).isEmpty)
    }

    func testEachBodyEditError() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.editBody(UUID(), actionName: "Edit", appendLine("x"))) {
            XCTAssertEqual($0 as? BodyEditError, .noteMissing)
        }
        let deleted = savedNote(store, "Deleted")
        store.moveToRecentlyDeleted([deleted])
        XCTAssertThrowsError(try store.editBody(deleted, actionName: "Edit", appendLine("x"))) {
            XCTAssertEqual($0 as? BodyEditError, .inTrash)
        }
        let locked = savedNote(store, "Locked")
        store.notes[store.noteIndex(locked)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        XCTAssertThrowsError(try store.editBody(locked, actionName: "Edit", appendLine("x"))) {
            XCTAssertEqual($0 as? BodyEditError, .locked)
        }
        XCTAssertEqual(BodyEditError.versionNotSaved.localizedDescription,
                       "The current version couldn't be saved, so the note wasn't changed.")
    }

    func testEditBodyRefusesUnreadableSidecar() throws {
        let store = makeStore()
        let id = saveNote(store, NSAttributedString(string: "Saved\nbody"), extras: extrasA)
        let sidecarURL = store.bodyExtrasFileURL(id)
        try Data("{ not json".utf8).write(to: sidecarURL)
        let sidecarBefore = try Data(contentsOf: sidecarURL)
        let packageBefore = try packageFiles(store.bodyURL(for: id))
        let versionsBefore = store.versions(of: id).count

        let relaunched = makeStore()
        XCTAssertThrowsError(try relaunched.editBody(id, actionName: "Edit", appendLine("x"))) {
            XCTAssertEqual($0 as? BodyEditError, .writeBlocked)
        }
        relaunched.flush()
        XCTAssertEqual(try Data(contentsOf: sidecarURL), sidecarBefore)
        XCTAssertEqual(try packageFiles(relaunched.bodyURL(for: id)), packageBefore)
        XCTAssertEqual(relaunched.versions(of: id).count, versionsBefore)
    }

    func testFailedVersionAbortsEdit() throws {
        let store = makeStore()
        let closed = savedNote(store, "Closed")
        let version = try XCTUnwrap(store.history.record(NSAttributedString(string: "Older"), extras: .empty, of: closed))
        let closedRevision = store.note(with: closed)?.revision
        store.recordVersionOverride = { _, _ in nil }

        XCTAssertThrowsError(try store.editBody(closed, actionName: "Edit", appendLine("x"))) {
            XCTAssertEqual($0 as? BodyEditError, .versionNotSaved)
        }
        XCTAssertEqual(store.body(for: closed).string, "Closed")
        XCTAssertEqual(store.note(with: closed)?.revision, closedRevision)
        XCTAssertNil(store.externallyUpdatedNoteID)

        XCTAssertThrowsError(try store.restoreVersion(version)) {
            XCTAssertEqual($0 as? BodyEditError, .versionNotSaved)
        }
        XCTAssertEqual(store.body(for: closed).string, "Closed")
        XCTAssertEqual(try NoteStore.readBody(at: store.bodyURL(for: closed)).string, "Closed")

        let open = savedNote(store, "Open")
        let editor = harness.open(store, open)
        let undo = try XCTUnwrap(editor.view.undoManager)
        XCTAssertThrowsError(try store.editBody(open, actionName: "Edit", appendLine("y"))) {
            XCTAssertEqual($0 as? BodyEditError, .versionNotSaved)
        }
        EditorHarness.settle(undo)
        XCTAssertEqual(editor.view.string, "Open")
        XCTAssertFalse(undo.canUndo)
        XCTAssertEqual(store.body(for: open).string, "Open")
        XCTAssertNil(store.externallyUpdatedNoteID)
    }

    // MARK: Restore Version

    func testRestoreVersionClosedOpenAndInTrash() throws {
        let store = makeStore()
        let id = savedNote(store, "one")
        store.updateBody(id, NSAttributedString(string: "two"))
        store.flush()
        let first = try XCTUnwrap(store.versions(of: id).first)
        XCTAssertEqual(try versionTexts(store, id), ["one"])

        clock.addTimeInterval(60)
        try store.restoreVersion(first)
        XCTAssertEqual(store.body(for: id).string, "one")
        XCTAssertEqual(try versionTexts(store, id), ["two", "one"], "one version: the body before the restore")

        let editor = harness.open(store, id)
        let undo = try XCTUnwrap(editor.view.undoManager)
        let two = try XCTUnwrap(store.versions(of: id).first)
        clock.addTimeInterval(60)
        try store.restoreVersion(two)
        EditorHarness.settle(undo)
        XCTAssertEqual(editor.view.string, "two")
        XCTAssertEqual(store.body(for: id).string, "two")
        XCTAssertEqual(try versionTexts(store, id), ["one", "two", "one"])
        XCTAssertEqual(undo.undoActionName, "Restore Version")

        store.moveToRecentlyDeleted([id])
        clock.addTimeInterval(60)
        XCTAssertNoThrow(try store.restoreVersion(first))
        XCTAssertEqual(store.body(for: id).string, "two")
        XCTAssertEqual(store.versions(of: id).count, 3)
    }

    func testRestoreVersionRestoresExtras() throws {
        let (store, storage) = makeCountingStore()
        let original = try codeText(["zig-nightly"])
        let id = saveNote(store, original, extras: extrasA)
        try store.editBody(id, actionName: "Edit") { $0.append(NSAttributedString(string: "\nedited")) }
        let version = try XCTUnwrap(store.versions(of: id).first)
        let versionEntry = try BodyExtrasEntry(json: JSONValue.decode(Data(contentsOf: VersionHistory.extrasURL(of: version.url))))
        XCTAssertEqual(versionEntry.extras, extrasA)
        XCTAssertEqual(versionEntry.codeLanguageIDs, ["zig-nightly"])
        XCTAssertEqual(versionEntry.bodySHA256, try RTFDBodyStorage.packageDigest(at: version.url))

        store.setBodyExtras(extrasB, for: id)
        store.updateBody(id, NSAttributedString(string: "Title\nno code"))
        store.flush()
        XCTAssertEqual(try readSidecar(store, id).current.extras, extrasB)

        clock.addTimeInterval(60)
        let writes = storage.installs
        try store.restoreVersion(version)
        XCTAssertEqual(storage.installs, writes + 1, "text and extras go out in one write")
        XCTAssertEqual(store.body(for: id).string, original.string)
        XCTAssertEqual(store.bodyExtras[id], extrasA)
        XCTAssertEqual(try readSidecar(store, id).current.extras, extrasA)
        XCTAssertNil(try readSidecar(store, id).previous)
        XCTAssertEqual(languageIDs(store.body(for: id)), ["zig-nightly"])

        let relaunched = makeStore()
        XCTAssertEqual(languageIDs(relaunched.body(for: id)), ["zig-nightly"])
        XCTAssertEqual(relaunched.bodyExtras[id], extrasA)

        // The placeholder save, the edit and the restore each kept one version.
        let versions = store.versions(of: id)
        XCTAssertEqual(versions.count, 3)
        let kept = try store.history.load(versions[0])
        XCTAssertEqual(kept.text.string, "Title\nno code")
        XCTAssertEqual(kept.extras, extrasB, "the version kept before the restore holds the replaced extras")

        clock.addTimeInterval(60)
        store.history.failsExtrasWrite = true
        XCTAssertThrowsError(try store.editBody(id, actionName: "Edit", appendLine("x"))) {
            XCTAssertEqual($0 as? BodyEditError, .versionNotSaved)
        }
        XCTAssertEqual(store.versions(of: id).count, 3, "no version package is left")
        let leftovers = try fm.contentsOfDirectory(atPath: store.history.directory(for: id).path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix(".") }, [], "no temp files are left")
        XCTAssertEqual(store.body(for: id).string, original.string)
    }

    func testRestoreLegacyVersionKeepsCurrentExtras() throws {
        let store = makeStore()
        let id = saveNote(store, NSAttributedString(string: "Current\nbody"), extras: extrasA)
        let version = try XCTUnwrap(store.history.record(NSAttributedString(string: "Legacy\nbody"), extras: .empty, of: id))
        try fm.removeItem(at: VersionHistory.extrasURL(of: version.url))
        XCTAssertNil(try store.history.load(version).extras)

        clock.addTimeInterval(60)
        try store.restoreVersion(version)
        XCTAssertEqual(store.body(for: id).string, "Legacy\nbody")
        XCTAssertEqual(store.bodyExtras[id], extrasA)
        XCTAssertEqual(try readSidecar(store, id).current.extras, extrasA)
    }

    func testUnreadableVersionExtrasThrowFromLoad() throws {
        let store = makeStore()
        let id = savedNote(store, "Body")
        let version = try XCTUnwrap(store.history.record(NSAttributedString(string: "Old"), extras: extrasA, of: id))
        try Data("{ nope".utf8).write(to: VersionHistory.extrasURL(of: version.url))
        XCTAssertThrowsError(try store.history.load(version))
        XCTAssertThrowsError(try store.restoreVersion(version))
        XCTAssertEqual(store.body(for: id).string, "Body")
    }

    func testUndoRestoreVersionRestoresExtras() throws {
        let (store, storage) = makeCountingStore()
        let textA = try codeText(["zig-nightly"], title: "Version A")
        let id = saveNote(store, textA, extras: extrasA)
        let version = try XCTUnwrap(store.history.record(try codeText([nil], title: "Version B"), extras: extrasB, of: id))
        let editor = harness.open(store, id)
        let undo = try XCTUnwrap(editor.view.undoManager)

        clock.addTimeInterval(60)
        try store.restoreVersion(version)
        EditorHarness.settle(undo)
        XCTAssertTrue(editor.view.string.hasPrefix("Version B"))
        XCTAssertEqual(store.bodyExtras[id], extrasB)
        XCTAssertEqual(undo.undoActionName, "Restore Version")

        var writes = storage.installs
        undo.undo()
        XCTAssertTrue(editor.view.string.hasPrefix("Version A"))
        XCTAssertEqual(store.body(for: id).string, textA.string)
        XCTAssertEqual(store.bodyExtras[id], extrasA)
        try assertSidecar(store, id, holdsOnly: extrasA, languages: ["zig-nightly"])
        XCTAssertFalse(store.isBodyDirty(id))
        XCTAssertFalse(editor.coordinator.hasPendingChanges)
        XCTAssertEqual(storage.installs, writes + 1, "undo saves text and extras in one write")
        XCTAssertFalse(undo.canUndo)

        writes = storage.installs
        undo.redo()
        XCTAssertTrue(editor.view.string.hasPrefix("Version B"))
        XCTAssertEqual(store.bodyExtras[id], extrasB)
        try assertSidecar(store, id, holdsOnly: extrasB, languages: [nil])
        XCTAssertFalse(store.isBodyDirty(id))
        XCTAssertEqual(storage.installs, writes + 1, "redo saves text and extras in one write")

        // A restore that changes only the extras undoes and redoes the same way.
        let sameText = try XCTUnwrap(store.history.record(store.body(for: id), extras: extrasA, of: id))
        clock.addTimeInterval(60)
        try store.restoreVersion(sameText)
        EditorHarness.settle(undo)
        XCTAssertEqual(store.bodyExtras[id], extrasA)
        try assertSidecar(store, id, holdsOnly: extrasA, languages: [nil])
        writes = storage.installs
        undo.undo()
        XCTAssertEqual(store.bodyExtras[id], extrasB)
        try assertSidecar(store, id, holdsOnly: extrasB, languages: [nil])
        XCTAssertEqual(storage.installs, writes + 1)
        undo.redo()
        XCTAssertEqual(store.bodyExtras[id], extrasA)
        try assertSidecar(store, id, holdsOnly: extrasA, languages: [nil])

        // An edit with nil extras registers no extras action: undo leaves the extras alone.
        clock.addTimeInterval(60)
        try store.editBody(id, actionName: "Append Line", appendLine("plain"))
        EditorHarness.settle(undo)
        store.setBodyExtras(extrasB, for: id)
        undo.undo()
        XCTAssertEqual(store.bodyExtras[id], extrasB)
    }

    private func assertSidecar(_ store: NoteStore, _ id: UUID, holdsOnly extras: ContainerExtras, languages: [String?],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let sidecar = try readSidecar(store, id)
        XCTAssertNil(sidecar.previous, file: file, line: line)
        XCTAssertEqual(sidecar.current.extras, extras, file: file, line: line)
        XCTAssertEqual(sidecar.current.codeLanguageIDs, languages, file: file, line: line)
        XCTAssertEqual(sidecar.current.bodySHA256, try RTFDBodyStorage.packageDigest(at: store.bodyURL(for: id)),
                       file: file, line: line)
    }

    // MARK: Several editors

    func testPendingEditsHandOverActiveLast() throws {
        let store = makeStore()
        let id = savedNote(store, "Shared")
        let first = harness.open(store, id)
        let second = harness.open(store, id)
        OpenEditorRegistry.shared.markActive(first.view)
        EditorHarness.type(" first", in: first.view)
        EditorHarness.type(" second", in: second.view)
        XCTAssertTrue(first.coordinator.hasPendingChanges)
        XCTAssertTrue(second.coordinator.hasPendingChanges)

        try store.editBody(id, actionName: "Append Line", appendLine("added"))
        XCTAssertEqual(store.body(for: id).string, "Shared first\nadded")
        XCTAssertEqual(first.view.string, "Shared first\nadded")
        XCTAssertEqual(second.view.string, "Shared first\nadded")
        XCTAssertFalse(second.coordinator.hasPendingChanges)
    }

    func testTwoEditorsEditTheActiveOneAndReloadTheOther() throws {
        let store = makeStore()
        let id = savedNote(store, "Shared")
        let first = harness.open(store, id)
        let second = harness.open(store, id)
        OpenEditorRegistry.shared.markActive(second.view)
        XCTAssertTrue(OpenEditorRegistry.shared.textView(for: id) === second.view)
        XCTAssertEqual(OpenEditorRegistry.shared.textViews(for: id).map(ObjectIdentifier.init),
                       [second.view, first.view].map(ObjectIdentifier.init))

        try store.editBody(id, actionName: "Append Line", appendLine("added"))
        EditorHarness.settle(second.view.undoManager)
        EditorHarness.settle(first.view.undoManager)
        XCTAssertEqual(second.view.undoManager?.undoActionName, "Append Line")
        XCTAssertEqual(first.view.string, "Shared\nadded")
        XCTAssertFalse(first.view.undoManager?.canUndo ?? true, "the other editor has no undo entry for the edit")
        XCTAssertEqual(store.body(for: id).string, "Shared\nadded")
        XCTAssertEqual(store.versions(of: id).count, 1)
    }
}
