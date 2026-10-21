import Foundation
import NoteItCore
import NoteItDoc
import NoteItMarkdown
import XCTest
@testable import NoteIt

final class MarkdownPathIndexTests: XCTestCase {
    private var root: URL!
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-path-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNamesAreSanitizedAndUniqueCaseInsensitively() {
        let index = MarkdownPathIndex(dataDir: root)
        let first = index.uniquePath(stem: MarkdownPathIndex.stem(forTitle: "Plan"), inFolder: "", contentRoot: content)
        index.set(MarkdownFileEntry(path: first), for: UUID())
        let second = index.uniquePath(stem: MarkdownPathIndex.stem(forTitle: "plan"), inFolder: "", contentRoot: content)
        XCTAssertEqual(first, "Plan.md")
        XCTAssertEqual(second, "plan 2.md")
        XCTAssertEqual(MarkdownPathIndex.stem(forTitle: "a/b: c?"), "ab c")
        XCTAssertEqual(MarkdownPathIndex.stem(forTitle: "   "), "Untitled")
        XCTAssertEqual(index.uniquePath(stem: "Plan", inFolder: "Work/Meetings", contentRoot: content), "Work/Meetings/Plan.md")
    }

    func testStemsAreCutTo100CharactersOnAGraphemeBoundary() {
        let title = String(repeating: "e\u{301}", count: 120)
        let stem = MarkdownPathIndex.stem(forTitle: title)
        XCTAssertEqual(stem.count, 100)
        XCTAssertEqual(stem.unicodeScalars.count, 200, "no accent cut off its letter")
    }

    func testANameTakenOnDiskIsAvoided() throws {
        try Data("x".utf8).write(to: content.appendingPathComponent("PLAN.md"))
        let index = MarkdownPathIndex(dataDir: root)
        XCTAssertEqual(index.uniquePath(stem: "Plan", inFolder: "", contentRoot: content), "Plan 2.md")
    }

    func testMoveKeepsFormerPathsAndPersists() throws {
        let index = MarkdownPathIndex(dataDir: root)
        let id = UUID()
        index.set(MarkdownFileEntry(path: "Work/Old plan.md", sha256: "abc", size: 3), for: id)
        index.move(id, to: "Work/Plan.md")
        index.setNotebookFolder("Work", for: UUID())
        let reloaded = MarkdownPathIndex(dataDir: root)
        XCTAssertEqual(reloaded.entry(id)?.path, "Work/Plan.md")
        XCTAssertEqual(reloaded.entry(id)?.formerPaths, ["Work/Old plan.md"])
        XCTAssertEqual(reloaded.id(forPath: "work/plan.MD"), id)
        XCTAssertNil(reloaded.id(forPath: "Work/Old plan.md"))
        XCTAssertEqual(reloaded.allNotebookFolders.count, 1)
    }

    func testMoveFolderRewritesNestedPaths() {
        let index = MarkdownPathIndex(dataDir: root)
        let note = UUID(), inner = UUID(), outer = UUID()
        index.set(MarkdownFileEntry(path: "Work/Meetings/Mon.md"), for: note)
        index.setNotebookFolder("Work", for: outer)
        index.setNotebookFolder("Work/Meetings", for: inner)
        index.moveFolder("Work", to: "Jobs")
        XCTAssertEqual(index.entry(note)?.path, "Jobs/Meetings/Mon.md")
        XCTAssertEqual(index.entry(note)?.formerPaths, ["Work/Meetings/Mon.md"])
        XCTAssertEqual(index.notebookFolder(inner), "Jobs/Meetings")
        XCTAssertEqual(index.notebookFolder(outer), "Jobs")
    }
}

final class NotebookFoldersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-nb-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRoundTripKeepsUnknownKeysAndDropsForbiddenOnes() throws {
        let folder = root.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let parent = UUID(), template = UUID(), id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Ignored","symbol":"book","colorHex":"#FF0000","sortIndex":3,
         "parent":"\(parent.uuidString)","defaultTemplateID":"\(template.uuidString)","spaceID":"S","futureKey":{"a":1}}
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent(NotebookFolders.fileName))
        let (notebook, raw) = try NotebookFolders.read(folder)
        XCTAssertEqual(notebook.id, id)
        XCTAssertEqual(notebook.name, "Work")
        XCTAssertEqual(notebook.symbol, "book")
        XCTAssertEqual(notebook.sortIndex, 3)
        XCTAssertEqual(notebook.parent, parent)
        XCTAssertEqual(notebook.defaultTemplateID, template)
        XCTAssertNil(raw["spaceID"])

        var moved = notebook
        moved.parent = nil
        try NotebookFolders.write(moved, raw: raw, to: folder)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(NotebookFolders.fileName))) as? [String: Any])
        XCTAssertNil(written["name"])
        XCTAssertNil(written["spaceID"])
        XCTAssertNotNil(written["futureKey"])
        XCTAssertTrue(written["parent"] is NSNull)
        XCTAssertEqual(written["defaultTemplateID"] as? String, template.uuidString)
        XCTAssertEqual(try NotebookFolders.read(folder).notebook.defaultTemplateID, template)
    }

    func testAFolderWithoutTheFileGetsDefaults() throws {
        let folder = root.appendingPathComponent("Fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (notebook, raw) = try NotebookFolders.read(folder)
        XCTAssertEqual(notebook.name, "Fresh")
        XCTAssertTrue(raw.isEmpty)
        XCTAssertNil(notebook.parent)
    }

    func testFolderNamesThatAreNotNotebooks() {
        XCTAssertFalse(NotebookFolders.isNotebookFolderName(".git"))
        XCTAssertFalse(NotebookFolders.isNotebookFolderName("_attachments"))
        XCTAssertFalse(NotebookFolders.isNotebookFolderName("node_modules"))
        XCTAssertTrue(NotebookFolders.isNotebookFolderName("Work"))
    }

    func testLayoutNestsUpToDepthFourAndNeverDeeper() {
        var chain: [Notebook] = []
        for level in 0..<5 {
            chain.append(Notebook(name: "L\(level)", symbol: "folder", colorHex: "#000000", sortIndex: 0, parent: chain.last?.id))
        }
        let layout = NotebookFolders.layout(chain, existing: [:])
        XCTAssertEqual(layout[chain[0].id], "L0")
        XCTAssertEqual(layout[chain[3].id], "L0/L1/L2/L3")
        XCTAssertEqual(layout[chain[4].id], "L0/L1/L2/L3", "a depth-5 notebook shares its depth-4 ancestor's folder")
    }

    func testLayoutMakesSiblingNamesUniqueAndKeepsRecordedFolders() {
        let a = Notebook(name: "Work", symbol: "folder", colorHex: "#000000", sortIndex: 0)
        let b = Notebook(name: "work", symbol: "folder", colorHex: "#000000", sortIndex: 1)
        let fresh = NotebookFolders.layout([a, b], existing: [:])
        XCTAssertEqual(fresh[a.id], "Work")
        XCTAssertEqual(fresh[b.id], "work 2")
        let kept = NotebookFolders.layout([a, b], existing: [b.id: "work", a.id: "Work 2"])
        XCTAssertEqual(kept[b.id], "work")
        XCTAssertEqual(kept[a.id], "Work 2")
    }
}

final class AttachmentStoreTests: XCTestCase {
    private var root: URL!
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func attachment(_ text: String, name: String = "photo.png") -> (Attachment, String) {
        let data = Data(text.utf8)
        return (Attachment(mime: "image/png", name: name, data: data), AttachmentStore.sha256(data))
    }

    func testIdenticalBytesAreStoredOnce() throws {
        let store = AttachmentStore(contentRoot: content, index: MarkdownPathIndex(dataDir: root))
        let (a, sha) = attachment("bytes")
        let first = try store.store(a, sha: sha)
        let second = try store.store(Attachment(mime: a.mime, name: "other.png", data: a.data), sha: sha)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, String(sha.prefix(12)) + "-photo.png")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folderURL.path), [first])
    }

    func testRelativePathsFromNestedNotes() {
        XCTAssertEqual(AttachmentPaths.relativePath(fromNoteAt: "Note.md", fileName: "x.png"), "_attachments/x.png")
        XCTAssertEqual(AttachmentPaths.relativePath(fromNoteAt: "Work/Note.md", fileName: "x.png"), "../_attachments/x.png")
        XCTAssertEqual(AttachmentPaths.relativePath(fromNoteAt: "A/B/C/D/Note.md", fileName: "x.png"),
                       "../../../../_attachments/x.png")
    }

    func testOversizedFilesAreRefused() {
        let store = AttachmentStore(contentRoot: content, index: MarkdownPathIndex(dataDir: root))
        let big = Attachment(mime: "image/png", name: "big.png", data: Data(count: AttachmentLimit.maxBytes + 1))
        XCTAssertThrowsError(try store.store(big, sha: AttachmentStore.sha256(big.data)))
    }

    func testUnreferencedFilesGoToTheTrashOnlyAfter24HoursAndOnlyIfSeenReferenced() throws {
        let index = MarkdownPathIndex(dataDir: root)
        let store = AttachmentStore(contentRoot: content, index: index)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var trashed: [String] = []
        store.now = { clock }
        store.trash = { trashed.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }
        let (a, sha) = attachment("shared")
        let name = try store.store(a, sha: sha)
        let (never, neverSHA) = attachment("never", name: "never.png")
        _ = try store.store(never, sha: neverSHA)
        let one = UUID(), two = UUID()
        index.set(MarkdownFileEntry(path: "One.md", attachments: [name]), for: one)
        index.set(MarkdownFileEntry(path: "Two.md", attachments: [name]), for: two)
        XCTAssertEqual(store.referenceCounts()[name.lowercased()], 2)
        store.sweep()
        index.remove(one)
        store.sweep()
        index.remove(two)
        store.sweep()
        clock.addTimeInterval(AttachmentStore.graceInterval - 1)
        XCTAssertEqual(store.sweep(), [])
        clock.addTimeInterval(2)
        XCTAssertEqual(store.sweep(), [name])
        XCTAssertEqual(trashed, [name], "a file never seen referenced stays")
    }
}
