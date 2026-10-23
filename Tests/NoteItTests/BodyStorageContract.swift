import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

/// Checks every `NoteBodyStorage` must pass (foundations Task 4.1). A plain helper, not an `XCTestCase`: each
/// concrete storage's test case calls it with its own `make`. Each check names the members it asserts.
enum BodyStorageContract {
    typealias Make = (URL) -> NoteBodyStorage

    static func runAll(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        assertKind(make: make, file: file, line: line)
        assertContentRoot(make: make, file: file, line: line)
        assertWriteRead(make: make, file: file, line: line)
        assertMissingReadThrows(make: make, file: file, line: line)
        assertWriteMetadataOnly(make: make, file: file, line: line)
        assertIDsOnDisk(make: make, file: file, line: line)
        assertTempInstall(make: make, file: file, line: line)
        assertTrashRecover(make: make, file: file, line: line)
        assertRemovePermanently(make: make, file: file, line: line)
        assertRevisionInput(make: make, file: file, line: line)
        assertFileURL(make: make, file: file, line: line)
        assertRecoveryCopy(make: make, file: file, line: line)
        assertNotebookRename(make: make, file: file, line: line)
        assertNotebookRemove(make: make, file: file, line: line)
    }

    // MARK: Checks

    /// `kind`: the same for two storages on one root, and unchanged by writes.
    static func assertKind(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let kind = storage.kind
            XCTAssertEqual(make(root).kind, kind, "kind", file: file, line: line)
            try write(storage, "Kind\nbody")
            XCTAssertEqual(storage.kind, kind, "kind after write", file: file, line: line)
        }
    }

    /// `contentRootURL`, `fileURL(for:)`, `write`.
    static func assertContentRoot(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            XCTAssertTrue(isInside(storage.contentRootURL, root), "contentRootURL inside root", file: file, line: line)
            let meta = try write(storage, "Root\nbody")
            XCTAssertTrue(isInside(storage.fileURL(for: meta.id), storage.contentRootURL), "fileURL inside contentRootURL",
                          file: file, line: line)
        }
    }

    /// `write`, `read`.
    static func assertWriteRead(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let meta = try write(storage, "Hello\nworld")
            let stored = try storage.read(meta.id)
            XCTAssertEqual(stored.text.string.withoutFinalNewline, "Hello\nworld", file: file, line: line)
            XCTAssertNil(stored.readOnlyReason, file: file, line: line)
        }
    }

    /// `read`.
    static func assertMissingReadThrows(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            assertNoSuchFile(try make(root).read(UUID()), file: file, line: line)
        }
    }

    /// `writeMetadataOnly`, `read`, `idsOnDisk`.
    static func assertWriteMetadataOnly(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let book = notebook("Book")
            var meta = try write(storage, "Meta\nbody", notebook: book)
            let ids = Set(storage.idsOnDisk())
            let other = notebook("Other")
            meta.title = "Renamed"
            meta.notebookID = other.id
            try storage.writeMetadataOnly(for: meta, notebook: other)
            XCTAssertEqual(try storage.read(meta.id).text.string.withoutFinalNewline, "Meta\nbody", file: file, line: line)
            XCTAssertEqual(Set(storage.idsOnDisk()), ids, file: file, line: line)

            let never = noteMeta(notebook: nil)
            XCTAssertNoThrow(try storage.writeMetadataOnly(for: never, notebook: nil), file: file, line: line)
            XCTAssertFalse(storage.idsOnDisk().contains(never.id), file: file, line: line)
            if let stored = try? storage.read(never.id) {
                XCTAssertEqual(stored.text.length, 0, "writeMetadataOnly created a body", file: file, line: line)
            }
        }
    }

    /// `idsOnDisk`, `write`, `removePermanently`.
    static func assertIDsOnDisk(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let meta = try write(storage, "Listed")
            XCTAssertTrue(storage.idsOnDisk().contains(meta.id), file: file, line: line)
            try storage.removePermanently(meta.id)
            XCTAssertFalse(storage.idsOnDisk().contains(meta.id), file: file, line: line)
        }
    }

    /// `prepareTemp`, `installTemp`, `read`.
    static func assertTempInstall(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let written = try write(storage, "Same\ntext")
            let installed = noteMeta(notebook: nil)
            let temp = try storage.prepareTemp(NSAttributedString(string: "Same\ntext"), extras: .empty, meta: installed)
            try storage.installTemp(temp, for: installed, notebook: nil)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "temp left behind", file: file, line: line)
            let a = try storage.read(written.id), b = try storage.read(installed.id)
            XCTAssertTrue(a.text.isEqual(to: b.text), file: file, line: line)
            XCTAssertEqual(a.extras, b.extras, file: file, line: line)
            XCTAssertEqual(a.readOnlyReason, b.readOnlyReason, file: file, line: line)
        }
    }

    /// `moveToTrash`, `idsOnDisk`, `read`, `recover`.
    static func assertTrashRecover(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let meta = try write(storage, "First")
            try storage.moveToTrash(meta.id)
            try write(storage, "Second", meta: meta)
            try storage.moveToTrash(meta.id)
            XCTAssertFalse(storage.idsOnDisk().contains(meta.id), file: file, line: line)
            assertNoSuchFile(try storage.read(meta.id), file: file, line: line)
            XCTAssertEqual(try storage.recover(meta.id)?.text.string.withoutFinalNewline, "Second", "newest trashed copy", file: file, line: line)
            XCTAssertNil(try storage.recover(UUID()), file: file, line: line)
        }
    }

    /// `removePermanently`, `read`, `fileURL(for:)`.
    static func assertRemovePermanently(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let meta = try write(storage, "Gone")
            try storage.removePermanently(meta.id)
            assertNoSuchFile(try storage.read(meta.id), file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.fileURL(for: meta.id).path), file: file, line: line)
        }
    }

    /// `revisionInputURL(for:)`, `write`.
    static func assertRevisionInput(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let meta = try write(storage, "Revision")
            let url = try XCTUnwrap(storage.revisionInputURL(for: meta.id), file: file, line: line)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
            try write(storage, "Revision", meta: meta)
            XCTAssertEqual(storage.revisionInputURL(for: meta.id), url, file: file, line: line)
            if let unknown = storage.revisionInputURL(for: UUID()) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: unknown.path), file: file, line: line)
            }
        }
    }

    /// `fileURL(for:)`, `write`.
    static func assertFileURL(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let a = UUID(), b = UUID()
            XCTAssertEqual(storage.fileURL(for: a), storage.fileURL(for: a), file: file, line: line)
            XCTAssertNotEqual(storage.fileURL(for: a), storage.fileURL(for: b), file: file, line: line)
            let meta = try write(storage, "File")
            XCTAssertTrue(FileManager.default.fileExists(atPath: storage.fileURL(for: meta.id).path), file: file, line: line)
        }
    }

    /// `recoveryCopy(_:for:in:)`.
    static func assertRecoveryCopy(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let directory = root.appendingPathComponent("recovery", isDirectory: true)
            let id = UUID()
            let url = try storage.recoveryCopy(NSAttributedString(string: "Rescued\ntext"), for: id, in: directory)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL,
                           file: file, line: line)
            let codec: BodyCodec = storage.kind == .rtfd ? .rtfd : .markdown
            XCTAssertEqual(url.pathExtension, codec.fileExtension, file: file, line: line)
            XCTAssertEqual(try codec.read(at: url).text.string.withoutFinalNewline, "Rescued\ntext", file: file, line: line)
        }
    }

    /// `renameNotebook(_:from:)`, `read`, `idsOnDisk`, `fileURL(for:)`.
    static func assertNotebookRename(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            var book = notebook("Before")
            let meta = try write(storage, "In a book", notebook: book)
            let snapshot = storage.kind == .rtfd ? try listing(storage.contentRootURL) : [:]
            book.name = "After"
            XCTAssertNoThrow(try storage.renameNotebook(book, from: "Before"), file: file, line: line)
            XCTAssertEqual(try storage.read(meta.id).text.string.withoutFinalNewline, "In a book", file: file, line: line)
            XCTAssertTrue(storage.idsOnDisk().contains(meta.id), file: file, line: line)
            XCTAssertTrue(FileManager.default.fileExists(atPath: storage.fileURL(for: meta.id).path), file: file, line: line)
            if storage.kind == .rtfd {
                XCTAssertEqual(try listing(storage.contentRootURL), snapshot, "RTFD rename is a no-op", file: file, line: line)
            }
        }
    }

    /// `removeNotebook(_:)`, `removePermanently`, `read`.
    static func assertNotebookRemove(make: Make, file: StaticString = #filePath, line: UInt = #line) {
        run(file: file, line: line) { root in
            let storage = make(root)
            let gone = notebook("Gone"), kept = notebook("Kept")
            let removed = try write(storage, "Removed", notebook: gone)
            let other = try write(storage, "Still here", notebook: kept)
            try storage.removePermanently(removed.id)
            let snapshot = storage.kind == .rtfd ? try listing(storage.contentRootURL) : [:]
            XCTAssertNoThrow(try storage.removeNotebook(gone), file: file, line: line)
            XCTAssertEqual(try storage.read(other.id).text.string.withoutFinalNewline, "Still here", file: file, line: line)
            if storage.kind == .rtfd {
                XCTAssertEqual(try listing(storage.contentRootURL), snapshot, "RTFD remove is a no-op", file: file, line: line)
            }
        }
    }

    // MARK: Helpers

    private static func run(file: StaticString, line: UInt, _ body: (URL) throws -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noteit-storage-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try body(root)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    static func notebook(_ name: String) -> Notebook {
        Notebook(id: UUID(), name: name, symbol: "tray", colorHex: "#0A84FF", sortIndex: 0)
    }

    static func noteMeta(notebook: Notebook?) -> NoteMeta {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        return NoteMeta(id: UUID(), notebookID: notebook?.id, title: "Note", preview: "", isPinned: false,
                        createdAt: date, updatedAt: date, tags: [])
    }

    @discardableResult
    private static func write(_ storage: NoteBodyStorage, _ text: String, notebook: Notebook? = nil,
                              meta: NoteMeta? = nil) throws -> NoteMeta {
        let meta = meta ?? noteMeta(notebook: notebook)
        try storage.write(NSAttributedString(string: text), extras: .empty, for: meta, notebook: notebook)
        return meta
    }

    private static func assertNoSuchFile<T>(_ expression: @autoclosure () throws -> T, file: StaticString, line: UInt) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile, "\(error)", file: file, line: line)
        }
    }

    private static func isInside(_ url: URL, _ directory: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    /// Relative path → contents (nil for directories) of everything under `url`.
    private static func listing(_ url: URL) throws -> [String: Data?] {
        let fm = FileManager.default
        var result: [String: Data?] = [:]
        for path in try fm.subpathsOfDirectory(atPath: url.path) {
            var isDir: ObjCBool = false
            let item = url.appendingPathComponent(path)
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            result[path] = isDir.boolValue ? .some(nil) : try Data(contentsOf: item)
        }
        return result
    }
}

extension String {
    /// Imported documents end their last paragraph with a newline; the text typed into the editor may not.
    var withoutFinalNewline: String { hasSuffix("\n") ? String(dropLast()) : self }
}
