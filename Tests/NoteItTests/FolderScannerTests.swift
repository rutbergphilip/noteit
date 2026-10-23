import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class FolderScannerTests: XCTestCase {
    private var root: URL!
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }
    private let fm = FileManager.default
    private var storage: MarkdownBodyStorage!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-scanner-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        storage = MarkdownBodyStorageTests.make(root)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func note(_ title: String, notebook: Notebook? = nil) throws -> UUID {
        let meta = NoteMeta(id: UUID(), notebookID: notebook?.id, title: title, preview: "", isPinned: false,
                            createdAt: Date(timeIntervalSince1970: 1_767_225_600),
                            updatedAt: Date(timeIntervalSince1970: 1_767_229_200), tags: [])
        try storage.write(EditorStyle.paragraph(title, kind: .title), extras: .empty, for: meta, notebook: notebook)
        return meta.id
    }

    private func scan(threshold: Int = FolderScanner.largeLibraryThreshold, maxSize: Int64 = FolderScanner.maxFileSize) -> FolderScanResult {
        FolderScanner.scan(contentRoot: content, index: storage.index, largeLibraryThreshold: threshold, maxFileSize: maxSize)
    }

    private func url(_ path: String) -> URL { content.appendingPathComponent(path) }

    private func setMTime(_ path: String, _ seconds: TimeInterval) throws {
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url(path).path)
    }

    func testUnchangedFolderGivesAnEmptyResult() throws {
        _ = try note("One")
        _ = try note("Two")
        let result = scan()
        XCTAssertFalse(result.hasNoteChanges)
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertFalse(result.largeLibrary)
    }

    func testSameSizeEditIsFoundAndATouchOnlyRefreshesTheIndex() throws {
        let id = try note("Plan")
        let text = try String(contentsOf: url("Plan.md"), encoding: .utf8)
        try text.replacingOccurrences(of: "# Plan", with: "# Plam").write(to: url("Plan.md"), atomically: false, encoding: .utf8)
        try setMTime("Plan.md", 1_800_000_000)
        XCTAssertEqual(scan().changed, [id: "Plan.md"])

        let other = try note("Other")
        try setMTime("Other.md", 1_800_000_100)
        let touched = scan()
        XCTAssertNil(touched.changed[other])
        let stat = try XCTUnwrap(MarkdownFileStat.of(url("Other.md")))
        XCTAssertEqual(storage.index.entry(other)?.mtimeNs, stat.mtimeNs, "a touch records the new mtime")
    }

    func testNewFilesRenamesMovesAndDeletions() throws {
        let renamed = try note("Old")
        let moved = try note("Wander")
        let deleted = try note("Gone")
        try "plain\n".write(to: url("Fresh.md"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: url("Old.md"), to: url("New.md"))
        try fm.createDirectory(at: url("Work"), withIntermediateDirectories: true)
        try fm.moveItem(at: url("Wander.md"), to: url("Work/Wander.md"))
        try fm.removeItem(at: url("Gone.md"))

        let result = scan()
        XCTAssertEqual(result.added, ["Fresh.md"])
        XCTAssertEqual(result.moved, [renamed: "New.md", moved: "Work/Wander.md"])
        XCTAssertEqual(result.removed, [deleted])
        XCTAssertTrue(result.changed.isEmpty)

        storage.index.move(renamed, to: "New.md")
        XCTAssertEqual(storage.index.entry(renamed)?.formerPaths, ["Old.md"])
    }

    func testARenameWithoutFrontMatterIsMatchedByInode() throws {
        try "no id\n".write(to: url("Bare.md"), atomically: true, encoding: .utf8)
        let id = UUID()
        let stat = try XCTUnwrap(MarkdownFileStat.of(url("Bare.md")))
        storage.index.set(MarkdownFileEntry(path: "Bare.md", sha256: AttachmentStore.sha256(Data("no id\n".utf8)),
                                            size: stat.size, mtimeNs: stat.mtimeNs, inode: stat.inode), for: id)
        try fm.moveItem(at: url("Bare.md"), to: url("Renamed.md"))
        let result = scan()
        XCTAssertEqual(result.moved, [id: "Renamed.md"])
        XCTAssertTrue(result.added.isEmpty)
    }

    func testCaseOnlyRenameIsAMove() throws {
        let id = try note("plan")
        try fm.moveItem(at: url("plan.md"), to: url("Plan.md"))
        let result = scan()
        XCTAssertEqual(result.moved, [id: "Plan.md"])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(result.added.isEmpty)
    }

    func testNotebookFoldersUpToFourLevels() throws {
        let work = Notebook(id: UUID(), name: "Work", symbol: "tray", colorHex: "#0A84FF", sortIndex: 0)
        let plans = Notebook(id: UUID(), name: "Plans", symbol: "tray", colorHex: "#0A84FF", sortIndex: 0, parent: work.id)
        storage.setNotebooks([work, plans])
        try storage.reconcileNotebooks()
        _ = try note("Deep", notebook: plans)
        try fm.createDirectory(at: url("Work/Plans/A/B/C"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url("_attachments"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url("node_modules/x"), withIntermediateDirectories: true)

        var result = scan()
        XCTAssertEqual(result.notebookFolders["Work"], NotebookFolderInfo(id: work.id, depth: 1))
        XCTAssertEqual(result.notebookFolders["Work/Plans"], NotebookFolderInfo(id: plans.id, depth: 2))
        XCTAssertEqual(result.notebookFolders["Work/Plans/A/B"], NotebookFolderInfo(id: nil, depth: 4))
        XCTAssertNil(result.notebookFolders["Work/Plans/A/B/C"])
        XCTAssertEqual(Set(result.notebookFolders.keys), ["Work", "Work/Plans", "Work/Plans/A", "Work/Plans/A/B"])

        try fm.createDirectory(at: url("Home"), withIntermediateDirectories: true)
        try fm.moveItem(at: url("Work/Plans"), to: url("Home/Plans"))
        result = scan()
        XCTAssertEqual(result.notebookFolders["Home/Plans"]?.id, plans.id, "a folder moved into another notebook folder keeps its id")
        XCTAssertEqual(result.moved.values.first, "Home/Plans/Deep.md")
    }

    func testACopyWithTheSameIDIsADuplicate() throws {
        let id = try note("Plan")
        try fm.copyItem(at: url("Plan.md"), to: url("Plan copy.md"))
        let result = scan()
        XCTAssertEqual(result.duplicateIDs, ["Plan copy.md"])
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertNil(result.changed[id])
    }

    func testSkippedFilesAndFolders() throws {
        for path in [".hidden.md", ".trash/Old.md", "_attachments/x.md", "node_modules/pkg/readme.md", "Work/.Note.md.icloud", "Big.md"] {
            try fm.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x\n".write(to: url(path), atomically: true, encoding: .utf8)
        }
        try Data(repeating: 0x61, count: 2_000).write(to: url("Big.md"))
        try fm.createSymbolicLink(at: url("Link.md"), withDestinationURL: url("Big.md"))
        let result = scan(maxSize: 1_000)
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.skipped, ["Big.md", "Link.md"])
        XCTAssertEqual(result.fileCount, 0)
    }

    func testAFileICloudEvictedIsNotRemoved() throws {
        let id = try note("Cloud")
        try fm.removeItem(at: url("Cloud.md"))
        try Data().write(to: url(".Cloud.md.icloud"))
        let result = scan()
        XCTAssertFalse(result.removed.contains(id))
        XCTAssertEqual(result.skipped, ["Cloud.md"])
    }

    func testLargeLibraryStillScans() throws {
        for index in 0..<4 { try "n\(index)\n".write(to: url("N\(index).md"), atomically: true, encoding: .utf8) }
        let result = scan(threshold: 3)
        XCTAssertTrue(result.largeLibrary)
        XCTAssertEqual(result.added.count, 4)
    }
}
