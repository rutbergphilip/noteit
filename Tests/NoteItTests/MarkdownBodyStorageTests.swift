import AppKit
import NoteItCore
import NoteItDoc
import NoteItMarkdown
import XCTest
@testable import NoteIt

@MainActor
final class MarkdownBodyStorageTests: XCTestCase {
    private var root: URL!
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }
    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var macTrash: URL { root.appendingPathComponent("mac-trash", isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-md-storage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    static func make(_ root: URL, contentName: String = "content", renames: Bool = true) -> MarkdownBodyStorage {
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(contentName, isDirectory: true), withIntermediateDirectories: true)
        let storage = MarkdownBodyStorage(contentRoot: root.appendingPathComponent(contentName, isDirectory: true),
                                          dataDir: root.appendingPathComponent("data", isDirectory: true),
                                          renameFilesOnTitleChange: renames)
        let macTrash = root.appendingPathComponent("mac-trash", isDirectory: true)
        storage.trash = { url in
            try FileManager.default.createDirectory(at: macTrash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: macTrash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
        return storage
    }

    private func storage(renames: Bool = true) -> MarkdownBodyStorage {
        Self.make(root, renames: renames)
    }

    private func meta(_ title: String = "Note", notebook: Notebook? = nil, pinned: Bool = false) -> NoteMeta {
        NoteMeta(id: UUID(), notebookID: notebook?.id, title: title, preview: "", isPinned: pinned,
                 createdAt: Date(timeIntervalSince1970: 1_767_225_600), updatedAt: Date(timeIntervalSince1970: 1_767_229_200), tags: [])
    }

    private func body(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            result.append(EditorStyle.paragraph(line, kind: index == 0 ? .title : .body))
        }
        return result
    }

    private func file(_ path: String) throws -> String {
        try String(contentsOf: content.appendingPathComponent(path), encoding: .utf8)
    }

    private func notebook(_ name: String, parent: UUID? = nil) -> Notebook {
        Notebook(id: UUID(), name: name, symbol: "tray", colorHex: "#0A84FF", sortIndex: 0, parent: parent)
    }

    func testBodyStorageContract() {
        BodyStorageContract.runAll { Self.make($0) }
    }

    func testReadingAndWritingAgainIsStable() throws {
        let storage = storage()
        let note = meta("Plan")
        try storage.write(body("Plan\nFirst line\n\nlast"), extras: .empty, for: note, notebook: nil)
        let first = try storage.read(note.id).text
        try storage.write(first, extras: .empty, for: note, notebook: nil)
        let file = try file("Plan.md")
        try storage.write(try storage.read(note.id).text, extras: .empty, for: note, notebook: nil)
        XCTAssertEqual(try storage.read(note.id).text.string, first.string)
        XCTAssertEqual(try self.file("Plan.md"), file)
    }

    func testFilesAreUTF8WithLFAndAFinalNewlineWrittenThroughATempFile() throws {
        let storage = storage()
        let note = meta("Plan")
        try storage.write(body("Plan\nFirst line"), extras: .empty, for: note, notebook: nil)
        let bytes = try Data(contentsOf: content.appendingPathComponent("Plan.md"))
        XCTAssertFalse(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(text.contains("\r"))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(storage.ledger.isOwnWrite(path: "Plan.md", sha256: AttachmentStore.sha256(bytes)))
        XCTAssertEqual(storage.index.entry(note.id)?.sha256, AttachmentStore.sha256(bytes))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: content.path).contains { $0.hasSuffix(".noteit-tmp") })

        let temp = content.appendingPathComponent(".Plan.md.noteit-tmp")
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        XCTAssertThrowsError(try storage.write(body("Plan\nSecond"), extras: .empty, for: note, notebook: nil),
                             "the write goes through .Plan.md.noteit-tmp")
        try fm.removeItem(at: temp)
    }

    func testFrontMatterMatchesTheNote() throws {
        let storage = storage()
        var note = meta("Pinned", pinned: true)
        note.conflictSource = "Outside NoteIt"
        note.conflictOriginalID = UUID()
        try storage.write(body("Pinned\nx"), extras: .empty, for: note, notebook: nil)
        let text = try file("Pinned.md")
        XCTAssertTrue(text.hasPrefix("---\nid: \(note.id.uuidString)\ncreated: 2026-01-01T00:00:00Z\nupdated: 2026-01-01T01:00:00Z\npinned: true\n"), text)
        XCTAssertTrue(text.contains("conflict-of: \(note.conflictOriginalID!.uuidString)\nconflict-source: \"Outside NoteIt\"\n"), text)
        let stored = try storage.read(note.id)
        XCTAssertEqual(stored.frontMatter?.id, note.id)
        XCTAssertEqual(stored.frontMatter?.pinned, true)
    }

    func testUnknownFrontMatterKeysTravelAsExtras() throws {
        let storage = storage()
        let note = meta("Keys")
        let extra = "aliases:\n  - One\ncssclasses: wide"
        try storage.write(body("Keys\nx"), extras: ContainerExtras(frontMatter: extra, extra: ["web": .string("kept elsewhere")]),
                          for: note, notebook: nil)
        let text = try file("Keys.md")
        XCTAssertTrue(text.contains(extra + "\n---\n"), text)
        XCTAssertFalse(text.contains("kept elsewhere"))
        let stored = try storage.read(note.id)
        XCTAssertEqual(stored.extras.frontMatter, extra)
        XCTAssertEqual(stored.extras.extra, [:])
        XCTAssertEqual(stored.frontMatter?.extra, "")
    }

    func testMetadataWritesPatchFrontMatterAndMoveFiles() throws {
        let storage = storage()
        var note = meta("Meta")
        let path = content.appendingPathComponent("Meta.md")
        try storage.write(body("Meta\nx"), extras: .empty, for: note, notebook: nil)
        let before = try file("Meta.md")
        let bodyPart = before.components(separatedBy: "---\n").last

        note.isPinned = true
        XCTAssertTrue(storage.needsMetadataWrite(note))
        try storage.writeMetadataOnly(for: note, notebook: nil)
        let pinned = try file("Meta.md")
        XCTAssertTrue(pinned.contains("pinned: true\n"))
        XCTAssertEqual(pinned.components(separatedBy: "---\n").last, bodyPart)
        XCTAssertFalse(storage.needsMetadataWrite(note))

        let book = notebook("Work")
        storage.setNotebooks([book])
        note.notebookID = book.id
        XCTAssertTrue(storage.needsMetadataWrite(note))
        try storage.writeMetadataOnly(for: note, notebook: book)
        XCTAssertFalse(fm.fileExists(atPath: path.path))
        XCTAssertEqual(storage.index.entry(note.id)?.path, "Work/Meta.md")
        XCTAssertEqual(storage.index.entry(note.id)?.formerPaths, ["Meta.md"])
        XCTAssertEqual(try storage.read(note.id).text.string.withoutFinalNewline, "Meta\nx")

        note.title = "Renamed"
        try storage.writeMetadataOnly(for: note, notebook: book)
        XCTAssertEqual(storage.index.entry(note.id)?.path, "Work/Meta.md", "only the idle rename renames")
        XCTAssertTrue(try storage.renameForTitle(note))
        XCTAssertEqual(storage.index.entry(note.id)?.path, "Work/Renamed.md")
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent("Work/Renamed.md").path))
        XCTAssertFalse(try storage.renameForTitle(note))
    }

    func testTitleChangeNeverRenamesWhenTheLibraryKeepsNames() throws {
        let storage = storage(renames: false)
        var note = meta("Kept")
        try storage.write(body("Kept\nx"), extras: .empty, for: note, notebook: nil)
        note.title = "Other"
        XCTAssertFalse(try storage.renameForTitle(note))
        try storage.write(body("Other\nx"), extras: .empty, for: note, notebook: nil)
        XCTAssertEqual(storage.index.entry(note.id)?.path, "Kept.md")
    }

    func testAFileChangedOnDiskIsNotOverwritten() throws {
        let storage = storage()
        let note = meta("Changed")
        try storage.write(body("Changed\nx"), extras: .empty, for: note, notebook: nil)
        let url = content.appendingPathComponent("Changed.md")
        let outside = try file("Changed.md").replacingOccurrences(of: "\nx\n", with: "\ny\n")
        try Data(outside.utf8).write(to: url)
        XCTAssertThrowsError(try storage.write(body("Changed\nz"), extras: .empty, for: note, notebook: nil)) { error in
            XCTAssertEqual(error as? MarkdownStorageError, .externallyChanged(note.id))
        }
        XCTAssertEqual(try file("Changed.md"), outside)

        let touched = storage.index.entry(note.id)!
        try Data(try Data(contentsOf: url)).write(to: url)
        XCTAssertThrowsError(try storage.writeMetadataOnly(for: note, notebook: nil))
        XCTAssertEqual(storage.index.entry(note.id)?.sha256, touched.sha256)
    }

    func testTouchedButUnchangedFileIsStillWritten() throws {
        let storage = storage()
        let note = meta("Touch")
        try storage.write(body("Touch\nx"), extras: .empty, for: note, notebook: nil)
        let url = content.appendingPathComponent("Touch.md")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
        XCTAssertNoThrow(try storage.write(body("Touch\ny"), extras: .empty, for: note, notebook: nil))
        XCTAssertTrue(try file("Touch.md").hasSuffix("y\n"))
    }

    func testTrashRecoverAndRemoval() throws {
        let storage = storage()
        var note = meta("Bin")
        try storage.write(body("Bin\nx"), extras: .empty, for: note, notebook: nil)
        note.deletedAt = Date(timeIntervalSince1970: 1_767_300_000)
        try storage.writeMetadataOnly(for: note, notebook: nil)
        XCTAssertEqual(storage.index.entry(note.id)?.path, ".trash/Bin.md")
        XCTAssertTrue(try file(".trash/Bin.md").contains("deleted: "))
        XCTAssertEqual(try storage.read(note.id).text.string.withoutFinalNewline, "Bin\nx", "Recently Deleted notes stay readable")

        note.deletedAt = nil
        try storage.writeMetadataOnly(for: note, notebook: nil)
        XCTAssertEqual(storage.index.entry(note.id)?.path, "Bin.md")
        XCTAssertFalse(try file("Bin.md").contains("deleted: "))

        try storage.moveToTrash(note.id)
        XCTAssertTrue(try file(".trash/Bin.md").contains("deleted: "))
        XCTAssertNil(storage.index.entry(note.id))
        XCTAssertEqual(try storage.recover(note.id)?.text.string.withoutFinalNewline, "Bin\nx")

        let other = meta("Other")
        try storage.write(body("Other\nx"), extras: .empty, for: other, notebook: nil)
        try storage.removePermanently(other.id)
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent("Other.md").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: macTrash.path).filter { $0.hasSuffix("Other.md") }.count, 1)
    }

    func testInvalidUTF8IsReadOnlyAndNeverRewritten() throws {
        let storage = storage()
        let note = meta("Broken")
        try storage.write(body("Broken\nx"), extras: .empty, for: note, notebook: nil)
        let url = content.appendingPathComponent("Broken.md")
        let bad = Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE, 0x0A])
        try bad.write(to: url)
        let entry = storage.index.entry(note.id)!
        let stat = MarkdownFileStat.of(url)!
        storage.index.update(note.id) {
            $0.sha256 = AttachmentStore.sha256(bad); $0.size = stat.size; $0.mtimeNs = stat.mtimeNs; $0.inode = stat.inode
        }
        XCTAssertNotEqual(entry.sha256, storage.index.entry(note.id)?.sha256)
        XCTAssertEqual(try storage.read(note.id).readOnlyReason, MarkdownBodyStorage.unreadableReason)
        XCTAssertThrowsError(try storage.write(body("Broken\ny"), extras: .empty, for: note, notebook: nil)) { error in
            XCTAssertEqual(error as? MarkdownStorageError, .unreadable(note.id))
        }
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }

    func testNotebookFoldersFollowRenamesAndMoves() throws {
        let storage = storage()
        var work = notebook("Work")
        var child = notebook("Plans", parent: work.id)
        let home = notebook("Home")
        storage.setNotebooks([work, child, home])
        let note = meta("Deep", notebook: child)
        try storage.write(body("Deep\nx"), extras: .empty, for: note, notebook: child)
        XCTAssertEqual(storage.index.entry(note.id)?.path, "Work/Plans/Deep.md")
        let json = content.appendingPathComponent("Work/Plans/.noteit-notebook.json")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        XCTAssertEqual(raw["parent"] as? String, work.id.uuidString)
        raw["custom"] = "kept"
        try JSONSerialization.data(withJSONObject: raw).write(to: json)

        work.name = "Job"
        try storage.renameNotebook(work, from: "Work")
        XCTAssertEqual(storage.index.entry(note.id)?.path, "Job/Plans/Deep.md")
        XCTAssertEqual(storage.index.notebookFolder(child.id), "Job/Plans")
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent("Work").path))

        child.parent = home.id
        storage.setNotebooks([work, child, home])
        try storage.reconcileNotebooks()
        XCTAssertEqual(storage.index.entry(note.id)?.path, "Home/Plans/Deep.md")
        XCTAssertEqual(try storage.read(note.id).text.string.withoutFinalNewline, "Deep\nx")
        raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: content.appendingPathComponent("Home/Plans/.noteit-notebook.json"))) as? [String: Any])
        XCTAssertEqual(raw["parent"] as? String, home.id.uuidString)
        XCTAssertEqual(raw["custom"] as? String, "kept")
        XCTAssertNil(raw["name"])

        work.name = "job"
        try storage.renameNotebook(work, from: "Job")
        XCTAssertEqual(storage.index.notebookFolder(work.id), "job")
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: content.path).contains("job"), "a change of case renames the folder")
    }

    func testRemovingANotebookTrashesOnlyAnEmptyFolder() throws {
        let storage = storage()
        let empty = notebook("Empty"), full = notebook("Full")
        storage.setNotebooks([empty, full])
        try storage.reconcileNotebooks()
        try Data("mine".utf8).write(to: content.appendingPathComponent("Full/own.pdf"))
        try storage.removeNotebook(empty)
        try storage.removeNotebook(full)
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent("Empty").path))
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent("Full/own.pdf").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: macTrash.path).count, 1)
    }

    func testImagesKeepTheirBytesInTheSharedAttachmentsFolder() throws {
        let storage = storage()
        let book = notebook("Pics")
        storage.setNotebooks([book])
        let png = try XCTUnwrap(NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        let attachment = NSTextAttachment(fileWrapper: FileWrapper(regularFileWithContents: png))
        attachment.fileWrapper?.preferredFilename = "dot.png"
        let text = NSMutableAttributedString(attributedString: EditorStyle.paragraph("Image:", kind: .body))
        text.insert(NSAttributedString(attachment: attachment), at: 6)
        var note = meta("Image", notebook: book)
        try storage.write(text, extras: .empty, for: note, notebook: book)
        let names = try fm.contentsOfDirectory(atPath: content.appendingPathComponent("_attachments").path)
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(try Data(contentsOf: content.appendingPathComponent("_attachments/" + names[0])), png)
        XCTAssertTrue(try file("Pics/Image.md").contains("](../_attachments/\(names[0]))"))
        XCTAssertEqual(storage.index.entry(note.id)?.attachments, names)
        XCTAssertTrue(BodyCodec.semanticallyEqual(try storage.read(note.id).text, text))

        note.notebookID = nil
        try storage.writeMetadataOnly(for: note, notebook: nil)
        XCTAssertTrue(try file("Image.md").contains("](_attachments/\(names[0]))"), "paths follow the folder depth")
        XCTAssertNil(try storage.read(note.id).readOnlyReason)

        let temp = try storage.prepareTemp(text, extras: .empty, meta: note)
        note.notebookID = book.id
        try storage.installTemp(temp, for: note, notebook: book)
        XCTAssertTrue(try file("Pics/Image.md").contains("](../_attachments/\(names[0]))"))
    }

    func testMissingImagesMakeTheNoteReadOnly() throws {
        let storage = storage()
        let note = meta("Web")
        try storage.write(body("Web\nx"), extras: .empty, for: note, notebook: nil)
        let url = content.appendingPathComponent("Web.md")
        let text = try file("Web.md") + "![remote](https://example.com/a.png)\n"
        try Data(text.utf8).write(to: url)
        let stat = MarkdownFileStat.of(url)!
        storage.index.update(note.id) {
            $0.sha256 = AttachmentStore.sha256(Data(text.utf8)); $0.size = stat.size; $0.mtimeNs = stat.mtimeNs; $0.inode = stat.inode
        }
        XCTAssertEqual(try storage.read(note.id).readOnlyReason, MarkdownBodyStorage.missingAttachmentsReason)
    }

    func testOnlyNoteItsOwnFilesAreWrittenToTheContentFolder() throws {
        let storage = storage()
        let book = notebook("Book")
        storage.setNotebooks([book])
        try storage.reconcileNotebooks()
        var note = meta("Cycle", notebook: book)
        try storage.write(body("Cycle\nx"), extras: .empty, for: note, notebook: book)
        let temp = try storage.prepareTemp(body("Cycle\ny"), extras: .empty, meta: note)
        try storage.installTemp(temp, for: note, notebook: book)
        note.deletedAt = Date()
        try storage.writeMetadataOnly(for: note, notebook: book)
        note.deletedAt = nil
        try storage.writeMetadataOnly(for: note, notebook: book)
        _ = try storage.recoveryCopy(body("R\nx"), for: note.id, in: root.appendingPathComponent("recovery"))
        try storage.moveToTrash(note.id)

        let allowed: (String) -> Bool = { path in
            let first = path.split(separator: "/").first.map(String.init) ?? path
            if [".trash", "_attachments", ".noteit"].contains(first) { return true }
            if path.hasSuffix(".md") || path.hasSuffix(NotebookFolders.fileName) { return true }
            var isDir: ObjCBool = false
            return self.fm.fileExists(atPath: self.content.appendingPathComponent(path).path, isDirectory: &isDir) && isDir.boolValue
        }
        let paths = try fm.subpathsOfDirectory(atPath: content.path)
        XCTAssertEqual(paths.filter { !allowed($0) }, [])
        let staging = (try? fm.contentsOfDirectory(atPath: storage.stagingURL.path)) ?? []
        XCTAssertEqual(staging, [])
    }
}

@MainActor
final class MarkdownLinkResolverTests: XCTestCase {
    private var root: URL!
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-md-links-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func meta(_ title: String, notebook: Notebook? = nil) -> NoteMeta {
        NoteMeta(id: UUID(), notebookID: notebook?.id, title: title, preview: "", isPinned: false,
                 createdAt: Date(timeIntervalSince1970: 1_767_225_600), updatedAt: Date(timeIntervalSince1970: 1_767_225_600), tags: [])
    }

    private func linking(_ title: String, to id: UUID?, text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: EditorStyle.paragraph(title, kind: .title))
        result.append(NSAttributedString(string: "\n"))
        let line = NSMutableAttributedString(attributedString: EditorStyle.paragraph("See " + text, kind: .body))
        let href = id.map { "noteit://note/\($0.uuidString)" } ?? "noteit://note?title=\(text)"
        line.addAttribute(.link, value: URL(string: href)!, range: NSRange(location: 4, length: (text as NSString).length))
        result.append(line)
        return result
    }

    private func linkIDs(_ text: NSAttributedString) -> [String] {
        var hrefs: [String] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { hrefs.append(url.absoluteString) } else if let string = value as? String { hrefs.append(string) }
        }
        return hrefs
    }

    private func file(_ path: String) throws -> String {
        try String(contentsOf: content.appendingPathComponent(path), encoding: .utf8)
    }

    func testLinksRoundTripToTheSameNote() throws {
        let storage = MarkdownBodyStorageTests.make(root)
        let target = meta("Target")
        try storage.write(linking("Target", to: nil, text: "x"), extras: .empty, for: target, notebook: nil)
        let source = meta("Source")
        try storage.write(linking("Source", to: target.id, text: "Target"), extras: .empty, for: source, notebook: nil)
        XCTAssertTrue(try file("Source.md").contains("[[Target]]"))
        XCTAssertEqual(linkIDs(try storage.read(source.id).text), ["noteit://note/\(target.id.uuidString)"])
    }

    func testANameThatIsNotUniqueIsWrittenAsAPath() throws {
        let storage = MarkdownBodyStorageTests.make(root)
        let work = Notebook(id: UUID(), name: "Work", symbol: "tray", colorHex: "#0A84FF", sortIndex: 0)
        storage.setNotebooks([work])
        let a = meta("Plan"), b = meta("Plan", notebook: work)
        try storage.write(linking("Plan", to: nil, text: "x"), extras: .empty, for: a, notebook: nil)
        try storage.write(linking("Plan", to: nil, text: "x"), extras: .empty, for: b, notebook: work)
        let source = meta("Source")
        try storage.write(linking("Source", to: b.id, text: "Plan"), extras: .empty, for: source, notebook: nil)
        XCTAssertTrue(try file("Source.md").contains("[[Work/Plan|Plan]]"))
        XCTAssertEqual(linkIDs(try storage.read(source.id).text), ["noteit://note/\(b.id.uuidString)"])
    }

    func testFormerNamesResolveAndAreUpdatedOnTheNextWriteOnly() throws {
        let storage = MarkdownBodyStorageTests.make(root)
        var target = meta("Old name")
        try storage.write(linking("Old name", to: nil, text: "x"), extras: .empty, for: target, notebook: nil)
        let source = meta("Source")
        let text = linking("Source", to: target.id, text: "Old name")
        try storage.write(text, extras: .empty, for: source, notebook: nil)
        let before = try file("Source.md")
        XCTAssertTrue(before.contains("[[Old name]]"))

        target.title = "New name"
        XCTAssertTrue(try storage.renameForTitle(target))
        XCTAssertEqual(try file("Source.md"), before, "files aren't rewritten only to update link names")
        XCTAssertEqual(linkIDs(try storage.read(source.id).text), ["noteit://note/\(target.id.uuidString)"])

        try storage.write(text, extras: .empty, for: source, notebook: nil)
        XCTAssertTrue(try file("Source.md").contains("[[New name|Old name]]"))
    }

    func testRenameOutsideNoteItStillResolvesThroughFormerPaths() throws {
        let storage = MarkdownBodyStorageTests.make(root)
        let target = meta("Before")
        try storage.write(linking("Before", to: nil, text: "x"), extras: .empty, for: target, notebook: nil)
        let source = meta("Source")
        try storage.write(linking("Source", to: target.id, text: "Before"), extras: .empty, for: source, notebook: nil)
        try fm.moveItem(at: content.appendingPathComponent("Before.md"), to: content.appendingPathComponent("After.md"))
        storage.index.move(target.id, to: "After.md")
        XCTAssertEqual(linkIDs(try storage.read(source.id).text), ["noteit://note/\(target.id.uuidString)"])
    }

    func testUnknownNamesEmbedsAndBareImageNames() throws {
        let storage = MarkdownBodyStorageTests.make(root)
        let target = meta("Embedded")
        try storage.write(linking("Embedded", to: nil, text: "x"), extras: .empty, for: target, notebook: nil)
        let png = try XCTUnwrap(NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        try fm.createDirectory(at: content.appendingPathComponent("_attachments"), withIntermediateDirectories: true)
        try png.write(to: content.appendingPathComponent("_attachments/photo.png"))
        let source = meta("Source")
        try storage.write(linking("Source", to: nil, text: "x"), extras: .empty, for: source, notebook: nil)
        let url = content.appendingPathComponent("Source.md")
        let text = try file("Source.md") + "[[Nobody]] ![[Embedded]] ![[photo.png]]\n"
        try Data(text.utf8).write(to: url)
        let read = try storage.read(source.id)
        XCTAssertNil(read.readOnlyReason)
        let hrefs = linkIDs(read.text)
        XCTAssertTrue(hrefs.contains("noteit://note?title=Nobody"), "\(hrefs)")
        XCTAssertTrue(hrefs.contains("noteit://note/\(target.id.uuidString)"), "\(hrefs)")
        XCTAssertEqual(try BodyCodec.noteItDoc(of: read.text).attachments.values.map(\.data), [png])
    }
}
