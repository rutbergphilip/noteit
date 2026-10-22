import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItSync

/// markdown-storage Task 5.1: converting a library between RTFD and a Markdown folder.
@MainActor
final class LibraryConverterTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var content: URL { root.appendingPathComponent("Notes", isDirectory: true) }
    private var pauses = 0
    private var resumes = 0
    private var flushes = 0
    private var trashed: [String] = []

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-convert-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        pauses = 0
        resumes = 0
        flushes = 0
        trashed = []
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: Helpers

    private func paragraph(_ text: String, _ kind: BlockKind = .body) -> NSAttributedString {
        EditorStyle.paragraph(text, kind: kind)
    }

    private func body(_ title: String, _ lines: [String]) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: paragraph(title, .title))
        for line in lines { result.append(paragraph(line)) }
        return result
    }

    private func linking(_ title: String, to id: UUID) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: paragraph(title, .title))
        let line = NSMutableAttributedString(attributedString: paragraph("See Target"))
        line.addAttribute(.link, value: URL(string: "noteit://note/\(id.uuidString)")!, range: NSRange(location: 4, length: 6))
        result.append(line)
        return result
    }

    /// A seeded RTFD library plus nested notebooks, a pinned note, a link to a note written later, a note in
    /// Recently Deleted and a version in history.
    private func makeRTFDLibrary() throws -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: data, seedsFreshLibrary: true))
        let work = store.createNotebook(name: "Work", symbol: "folder", colorHex: "#888888")
        let projects = store.createNotebook(name: "Projects", symbol: "folder", colorHex: "#888888", parentID: work.id)
        let source = store.createNote(in: work.id, initial: body("Source", ["placeholder"]))
        let target = store.createNote(in: projects.id, initial: body("Target", ["Deep inside", "Second line"]))
        store.updateBody(source.id, linking("Source", to: target.id))
        store.togglePin(target.id)
        let gone = store.createNote(in: nil, initial: body("Gone", ["Deleted soon"]))
        _ = store.moveToRecentlyDeleted([gone.id])
        _ = store.history.record(body("Target", ["An older body"]), extras: .empty, of: target.id)
        store.flush()
        return store
    }

    private func converter(_ store: NoteStore) -> LibraryConverter {
        let converter = LibraryConverter(store: store)
        converter.pauseSync = { [unowned self] in pauses += 1 }
        converter.resumeSync = { [unowned self] in resumes += 1 }
        converter.flush = { [unowned self] store in
            flushes += 1
            store.flush()
        }
        converter.availableSpace = { _ in 1 << 40 }
        converter.trash = { [unowned self] url in try moveToTestTrash(url) }
        return converter
    }

    /// Stands in for the macOS Trash: records the path relative to `root` and moves the item under `root/Trash`.
    private func moveToTestTrash(_ url: URL) throws {
        let base = root.resolvingSymlinksInPath().path
        trashed.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
        let bin = root.appendingPathComponent("Trash/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
    }

    private func openMarkdown(renames: Bool = true) -> NoteStore {
        let store = NoteStore.opened(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                                        renameFilesOnTitleChange: renames))
        store.markdownFlushWait = 10
        store.waitForMarkdownWrites(upTo: 10)
        return store
    }

    private func openRTFD() -> NoteStore {
        NoteStore(location: LibraryLocation(url: data, seedsFreshLibrary: false))
    }

    /// Every file under `folder` (path → SHA-256), folders as "dir".
    private func tree(_ folder: URL) -> [String: String] {
        var result: [String: String] = [:]
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return result }
        let base = folder.resolvingSymlinksInPath().path
        for case let url as URL in enumerator {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result[path] = "dir"
            } else {
                result[path] = (try? Data(contentsOf: url)).map(AttachmentStore.sha256) ?? "?"
            }
        }
        return result
    }

    private func assertSameTree(_ a: [String: String], _ b: [String: String], _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        let differing = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
        XCTAssertEqual(differing, [], message, file: file, line: line)
    }

    private struct Kept: Equatable {
        var id: UUID, title: String, notebookID: UUID?, isPinned: Bool, createdAt: Int, updatedAt: Int
        var revision: UUID?, deletedAt: Int?, tags: [String]
    }

    /// Dates to the second, as the library files keep them.
    private static func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }

    private func kept(_ store: NoteStore) -> [Kept] {
        store.notes.map {
            Kept(id: $0.id, title: $0.title, notebookID: $0.notebookID, isPinned: $0.isPinned, createdAt: Self.seconds($0.createdAt),
                 updatedAt: Self.seconds($0.updatedAt), revision: $0.revision, deletedAt: $0.deletedAt.map(Self.seconds), tags: $0.tags)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func keptNotebooks(_ store: NoteStore) -> Set<Notebook> {
        Set(store.notebooks.map {
            var notebook = $0
            notebook.modifiedAt = $0.modifiedAt.map { Date(timeIntervalSince1970: TimeInterval(Self.seconds($0))) }
            return notebook
        })
    }

    /// As stored on disk, not as cached.
    private func bodies(_ store: NoteStore) -> [UUID: NSAttributedString] {
        Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, (try? store.readStoredBody($0.id).text) ?? NSAttributedString()) })
    }

    private func assertSameBodies(_ a: [UUID: NSAttributedString], _ b: [UUID: NSAttributedString],
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(a.keys), Set(b.keys), file: file, line: line)
        for (id, text) in a {
            guard let other = b[id] else { continue }
            XCTAssertTrue(BodyCodec.semanticallyEqual(text, other), "note \(id) differs", file: file, line: line)
        }
    }

    // MARK: Both ways

    func testConvertingToMarkdownAndBackKeepsTheLibrary() async throws {
        let store = try makeRTFDLibrary()
        let notes = kept(store)
        let notebooks = keptNotebooks(store)
        let texts = bodies(store)
        let target = try XCTUnwrap(store.notes.first { $0.title == "Target" })
        let versions = store.history.versions(of: target.id).count
        XCTAssertGreaterThan(versions, 0)

        let result = try await converter(store).convert(to: .markdown(content))
        XCTAssertTrue(store.isClosedForLibrarySwitch)
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(resumes, 0)

        guard case .loaded(let location) = LibraryLocationFile.load(dataDir: data) else { return XCTFail("no location file") }
        XCTAssertEqual(location.format, .markdown)
        XCTAssertEqual(location.contentRootURL.standardizedFileURL.path, content.standardizedFileURL.path)
        XCTAssertTrue(location.renameFilesOnTitleChange)
        XCTAssertEqual(LibraryConverter.libraryFileID(in: content), location.libraryID)
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("notes").path))
        let previous = try XCTUnwrap(result.previousLibrary)
        XCTAssertTrue(previous.lastPathComponent.hasPrefix("Previous Library "))
        XCTAssertTrue(fm.fileExists(atPath: previous.appendingPathComponent("notes/\(target.id.uuidString).rtfd").path))
        XCTAssertEqual(PreviousLibrary.find(dataDir: data).map(\.url.lastPathComponent), [previous.lastPathComponent])
        XCTAssertNil(LibraryConversionJournal.load(dataDir: data))
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent(".noteit/staging").path)
                       && !((try? fm.contentsOfDirectory(atPath: content.appendingPathComponent(".noteit/staging").path)) ?? []).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent("Work/Projects/Target.md").path))
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent(".trash/Gone.md").path))
        XCTAssertTrue(try String(contentsOf: content.appendingPathComponent("Work/Source.md"), encoding: .utf8)
            .contains("[[Target]]"))

        // Derived and per-Mac files stay in the data folder.
        let derived = ["search-index.json", "link-index.json", "smart-folders.json", "library-settings.json", "lock-keys.json",
                       "library.json", "markdown-files.json", "library-location.json", "history"]
        for path in tree(content).keys {
            let name = (path as NSString).lastPathComponent
            XCTAssertFalse(derived.contains(name) && !path.hasPrefix(".noteit/"), "\(path) is in the content folder")
            XCTAssertFalse(path.hasPrefix("history") || path.hasPrefix("notes"), path)
        }
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("library.json").path))
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("markdown-files.json").path))

        let markdown = openMarkdown()
        XCTAssertEqual(kept(markdown), notes)
        XCTAssertEqual(keptNotebooks(markdown), notebooks)
        assertSameBodies(texts, bodies(markdown))
        XCTAssertEqual(markdown.history.versions(of: target.id).count, versions)
        markdown.flush()
        XCTAssertEqual(kept(markdown), notes, "a format change is not an edit")

        let before = tree(content).filter { !$0.key.hasPrefix(".noteit") }
        pauses = 0
        _ = try await converter(markdown).convert(to: .rtfd)
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(tree(content), before, "the Markdown folder is unchanged except .noteit/")
        guard case .loaded(let back) = LibraryLocationFile.load(dataDir: data) else { return XCTFail("no location file") }
        XCTAssertEqual(back.format, .rtfd)
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("markdown-files.json").path))
        XCTAssertNil(LibraryConversionJournal.load(dataDir: data))

        let rtfd = openRTFD()
        XCTAssertEqual(rtfd.bodyStorage.kind, .rtfd)
        XCTAssertEqual(kept(rtfd), notes)
        assertSameBodies(texts, bodies(rtfd))
        XCTAssertEqual(rtfd.history.versions(of: target.id).count, versions)
    }

    func testAConversionForgetsRemoteNotesTheOldFormatRefusedSoSyncPullsThem() async throws {
        let store = try makeRTFDLibrary()
        let refused = UUID(), synced = UUID()
        let base = SyncState.Base(revision: UUID(), remoteMetaETag: "kept")
        let files = ["sync-state-store1.json", "sync-state-store2.json"].map { data.appendingPathComponent($0) }
        func refuse() throws {
            for url in files {
                try SyncState(bases: [synced: base], lastDeviceWrite: Date(timeIntervalSinceReferenceDate: 812_345_678.123),
                              refusedRemotes: [refused: .init(metaETag: "e1", reason: "too large")]).save(to: url)
            }
        }
        try refuse()
        _ = try await converter(store).convert(to: .markdown(content))
        for url in files {
            XCTAssertEqual(SyncState.load(from: url).refusedRemotes, [:], "\(url.lastPathComponent) after converting to Markdown")
            XCTAssertEqual(SyncState.load(from: url).bases, [synced: base])
        }

        let markdown = openMarkdown()
        try refuse()
        _ = try await converter(markdown).convert(to: .rtfd)
        for url in files {
            XCTAssertEqual(SyncState.load(from: url).refusedRemotes, [:], "\(url.lastPathComponent) after converting back")
            XCTAssertEqual(SyncState.load(from: url).bases, [synced: base], "the rest of the sync state is kept")
            XCTAssertEqual(SyncState.load(from: url).lastDeviceWrite, Date(timeIntervalSinceReferenceDate: 812_345_678.123))
        }
    }

    func testAdoptingAFolderKeepsItsFileNames() async throws {
        let store = try makeRTFDLibrary()
        let foreign = ["Shopping list.md": "# Shopping\n\n- milk\n", "Ideas/garden plans.md": "Plant tomatoes\n",
                       "Ideas/Old/2019.markdown": "## Archive\n\nText\n"]
        for (path, text) in foreign {
            let url = content.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try Data("not a note".utf8).write(to: content.appendingPathComponent("readme.txt"))
        let inspection = LibraryConverter.inspect(content, dataDir: data)
        XCTAssertEqual(inspection.markdownFileCount, 3)
        XCTAssertTrue(inspection.adopts)
        XCTAssertNil(inspection.libraryID)

        let result = try await converter(store).convert(to: .markdown(content))
        XCTAssertFalse(result.location.renameFilesOnTitleChange)
        guard case .loaded(let location) = LibraryLocationFile.load(dataDir: data) else { return XCTFail("no location file") }
        XCTAssertFalse(location.renameFilesOnTitleChange)

        let markdown = openMarkdown(renames: false)
        for (path, text) in foreign {
            let written = try String(contentsOf: content.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(written.hasPrefix("---\n"), path)
            XCTAssertTrue(written.contains("\nid: "), path)
            XCTAssertTrue(written.hasSuffix(text), "\(path): \(written)")
        }
        XCTAssertEqual(try String(contentsOf: content.appendingPathComponent("readme.txt"), encoding: .utf8), "not a note")
        let shopping = try XCTUnwrap(markdown.notes.first { $0.title == "Shopping" })
        markdown.updateBody(shopping.id, body("Groceries", ["- milk"]))
        markdown.flush()
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent("Shopping list.md").path))
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent("Groceries.md").path))
    }

    // MARK: Failures leave everything as it was

    func testANoteThatDoesNotRoundTripStopsTheConversion() async throws {
        let store = try makeRTFDLibrary()
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("# Mine\n".utf8).write(to: content.appendingPathComponent("Mine.md"))
        let dataBefore = tree(data)
        let contentBefore = tree(content)
        let bad = try XCTUnwrap(store.notes.first { $0.title == "Target" })
        let converter = converter(store)
        converter.verify = { id, a, b in id != bad.id && BodyCodec.semanticallyEqual(a, b) }

        do {
            _ = try await converter.convert(to: .markdown(content))
            XCTFail("converted")
        } catch let error as LibraryConversionError {
            XCTAssertEqual(error, .notRoundTripping([bad.id]))
        }
        assertSameTree(tree(data), dataBefore)
        assertSameTree(tree(content), contentBefore)
        XCTAssertFalse(store.isClosedForLibrarySwitch)
        XCTAssertFalse(store.libraryConversionInProgress)
        XCTAssertEqual(resumes, 1)
    }

    func testANoteWithAnAttachmentOver25MBIsReportedAsNotRoundTripping() async throws {
        let store = try makeRTFDLibrary()
        let big = store.createNote(in: nil, initial: OversizedAttachment.body("Big", attachmentNamed: "huge.mov"))
        store.flush()
        let dataBefore = tree(data)
        do {
            _ = try await converter(store).convert(to: .markdown(content))
            XCTFail("converted")
        } catch let error as LibraryConversionError {
            XCTAssertEqual(error, .notRoundTripping([big.id]))
        }
        assertSameTree(tree(data), dataBefore)
        XCTAssertFalse(store.isClosedForLibrarySwitch)
    }

    func testNotEnoughSpace() async throws {
        let store = try makeRTFDLibrary()
        let dataBefore = tree(data)
        let converter = converter(store)
        converter.availableSpace = { _ in 1000 }
        do {
            _ = try await converter.convert(to: .markdown(content))
            XCTFail("converted")
        } catch LibraryConversionError.notEnoughSpace(let needed, let available) {
            XCTAssertEqual(available, 1000)
            XCTAssertGreaterThan(needed, available)
        }
        assertSameTree(tree(data), dataBefore)
        XCTAssertEqual(tree(content), [:])
        XCTAssertFalse(store.libraryConversionInProgress)
    }

    func testAChangeDuringTheConversionStopsIt() async throws {
        let store = try makeRTFDLibrary()
        let dataBefore = tree(data)
        let converter = converter(store)
        let note = try XCTUnwrap(store.notes.first { $0.title == "Target" })
        converter.verify = { _, a, b in
            if store.body(for: note.id).string.contains("Deep inside") { store.updateBody(note.id, self.body("Target", ["Edited"])) }
            return BodyCodec.semanticallyEqual(a, b)
        }
        do {
            _ = try await converter.convert(to: .markdown(content))
            XCTFail("converted")
        } catch let error as LibraryConversionError {
            XCTAssertEqual(error, .libraryChangedDuringConversion)
        }
        XCTAssertNil(LibraryConversionJournal.load(dataDir: data))
        XCTAssertFalse(fm.fileExists(atPath: LibraryLocationFile.url(dataDir: data).path))
        XCTAssertEqual(Set(tree(data).keys.filter { $0.hasPrefix("notes/") }), Set(dataBefore.keys.filter { $0.hasPrefix("notes/") }))
        XCTAssertEqual(tree(content).keys.filter { !$0.hasPrefix(".noteit") }, [])
        XCTAssertTrue(store.body(for: note.id).string.contains("Edited"))
    }

    func testAFolderThatStopsAnsweringFailsTheConversionWithoutBlockingTheMainThread() async throws {
        _ = try await converter(try makeRTFDLibrary()).convert(to: .markdown(content))
        let store = openMarkdown()
        let storage = try XCTUnwrap(store.markdownStorage)
        let gate = DispatchSemaphore(value: 0)
        storage.readFileData = { url in
            gate.wait()
            gate.signal()
            return try Data(contentsOf: url)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { gate.signal() }
        let converter = converter(store)
        converter.ioTimeout = 0.5
        var ticks = 0
        var converting = true
        let ticker = Task { @MainActor in
            while converting {
                ticks += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let started = Date()
        do {
            _ = try await converter.convert(to: .rtfd)
            XCTFail("converted")
        } catch let error as LibraryConversionError {
            XCTAssertEqual(error, .folderNotResponding)
        }
        converting = false
        await ticker.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        XCTAssertGreaterThan(ticks, 10)
        XCTAssertFalse(store.libraryConversionInProgress)
        XCTAssertFalse(store.isClosedForLibrarySwitch)
        let deadline = Date() + 10
        while LibraryConversionJournal.load(dataDir: data) != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(LibraryConversionJournal.load(dataDir: data))
        XCTAssertEqual(tree(data).keys.filter { $0.hasPrefix("notes/") || $0.hasPrefix("backups/staging") }, [])
        guard case .loaded(let location) = LibraryLocationFile.load(dataDir: data, setsAsideDamaged: false, log: { _ in }) else {
            return XCTFail("no location file")
        }
        XCTAssertEqual(location.format, .markdown)
    }

    // MARK: Crashes

    func testAnInterruptedConversionToMarkdownIsUndoneOrFinished() async throws {
        for step in LibraryConverter.Step.allCases {
            try? fm.removeItem(at: root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try makeRTFDLibrary()
            let texts = bodies(store)
            let notesBefore = tree(data.appendingPathComponent("notes"))
            let converter = converter(store)
            converter.interruption = step
            do {
                _ = try await converter.convert(to: .markdown(content))
                XCTFail("\(step): not interrupted")
            } catch is LibraryConverter.Interrupted {}
            XCTAssertNotNil(LibraryConversionJournal.load(dataDir: data), "\(step)")

            LibraryConverter.finishInterrupted(dataDir: data)
            XCTAssertNil(LibraryConversionJournal.load(dataDir: data), "\(step)")
            XCTAssertFalse(((try? fm.contentsOfDirectory(atPath: data.appendingPathComponent("backups").path)) ?? [])
                .contains { $0.hasPrefix("staging-") }, "\(step)")
            if step == .committed {
                XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("notes").path), "\(step)")
                XCTAssertEqual(PreviousLibrary.find(dataDir: data).count, 1, "\(step)")
                assertSameBodies(texts, bodies(openMarkdown()))
            } else {
                XCTAssertFalse(fm.fileExists(atPath: LibraryLocationFile.url(dataDir: data).path), "\(step)")
                XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("markdown-files.json").path), "\(step)")
                XCTAssertEqual(tree(data.appendingPathComponent("notes")), notesBefore, "\(step)")
                XCTAssertEqual(tree(content), [:], "\(step)")
                assertSameBodies(texts, bodies(openRTFD()))
            }
        }
    }

    func testAnInterruptedConversionToRTFDIsUndoneOrFinished() async throws {
        for step in LibraryConverter.Step.allCases {
            try? fm.removeItem(at: root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try await converter(try makeRTFDLibrary()).convert(to: .markdown(content))
            let markdown = openMarkdown()
            let texts = bodies(markdown)
            let contentBefore = tree(content).filter { !$0.key.hasPrefix(".noteit") }
            let converter = converter(markdown)
            converter.interruption = step
            do {
                _ = try await converter.convert(to: .rtfd)
                XCTFail("\(step): not interrupted")
            } catch is LibraryConverter.Interrupted {}

            LibraryConverter.finishInterrupted(dataDir: data)
            XCTAssertNil(LibraryConversionJournal.load(dataDir: data), "\(step)")
            XCTAssertEqual(tree(content).filter { !$0.key.hasPrefix(".noteit") }, contentBefore, "\(step)")
            guard case .loaded(let location) = LibraryLocationFile.load(dataDir: data) else { return XCTFail("\(step)") }
            if step == .committed {
                XCTAssertEqual(location.format, .rtfd, "\(step)")
                XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent(".noteit").path), "\(step)")
                assertSameBodies(texts, bodies(openRTFD()))
            } else {
                XCTAssertEqual(location.format, .markdown, "\(step)")
                XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("notes").path), "\(step)")
                assertSameBodies(texts, bodies(openMarkdown()))
            }
        }
    }

    func testACommittedConversionIsOnlyEverFinished() async throws {
        _ = try await converter(try makeRTFDLibrary()).convert(to: .markdown(content))
        let markdown = openMarkdown()
        let texts = bodies(markdown)
        let converter = converter(markdown)
        converter.interruption = .committed
        do {
            _ = try await converter.convert(to: .rtfd)
            XCTFail("not interrupted")
        } catch is LibraryConverter.Interrupted {}
        try fm.removeItem(at: LibraryLocationFile.url(dataDir: data))

        LibraryConverter.finishInterrupted(dataDir: data)
        XCTAssertNil(LibraryConversionJournal.load(dataDir: data))
        assertSameBodies(texts, bodies(openRTFD()))
    }

    func testAnInterruptedConversionIsLeftAloneWhenTheLocationFileCantBeRead() async throws {
        let store = try makeRTFDLibrary()
        let converter = converter(store)
        converter.interruption = .moved
        do {
            _ = try await converter.convert(to: .markdown(content))
            XCTFail("not interrupted")
        } catch is LibraryConverter.Interrupted {}
        try Data(#"{"version":99,"format":"markdown"}"#.utf8).write(to: LibraryLocationFile.url(dataDir: data))
        let dataBefore = tree(data)
        let contentBefore = tree(content)

        LibraryConverter.finishInterrupted(dataDir: data)
        assertSameTree(tree(data), dataBefore)
        assertSameTree(tree(content), contentBefore)
    }

    /// Markdown files under `folder` (`.noteit` skipped) → their front-matter id.
    private func markdownIDs(_ folder: URL) -> [String: UUID?] {
        tree(folder).keys.filter { FolderScanner.isMarkdown($0) && !$0.hasPrefix(".noteit") }
            .reduce(into: [:]) { result, path in
                result[path] = (try? Data(contentsOf: folder.appendingPathComponent(path))).flatMap(FolderScanner.frontMatterID)
            }
    }

    func testConvertingBackIntoTheFolderOfAnEarlierConversionReusesItsFiles() async throws {
        _ = try await converter(try makeRTFDLibrary()).convert(to: .markdown(content))
        let firstFiles = markdownIDs(content)
        _ = try await converter(openMarkdown()).convert(to: .rtfd)
        let rtfd = openRTFD()
        let edited = try XCTUnwrap(rtfd.notes.first { $0.title == "Target" }).id
        rtfd.updateBody(edited, body("Target", ["Edited while RTFD"]))
        let moved = try XCTUnwrap(rtfd.notes.first { $0.title == "Source" }).id
        rtfd.moveNote(moved, to: nil)
        try Data("# Mine\n\nwritten by hand\n".utf8).write(to: content.appendingPathComponent("Mine.md"))
        rtfd.flush()
        let notes = kept(rtfd)
        let texts = bodies(rtfd)

        _ = try await converter(rtfd).convert(to: .markdown(content))
        let markdown = openMarkdown()
        let files = markdownIDs(content)
        let ids = files.values.compactMap { $0 }
        XCTAssertEqual(ids.count, Set(ids).count, "no id is in two files: \(files)")
        let sourcePath = try XCTUnwrap(firstFiles.first { $0.value == moved }?.key)
        XCTAssertNotEqual(sourcePath, "Source.md")
        XCTAssertEqual(Set(files.keys).subtracting(firstFiles.keys), ["Mine.md", "Source.md"], "existing files are reused, not staged beside")
        XCTAssertEqual(Set(firstFiles.keys).subtracting(files.keys), [sourcePath], "only the moved note's old file goes aside")
        XCTAssertEqual(Set(markdown.notes.map(\.id)), Set(notes.map(\.id)).union(files["Mine.md"].flatMap { $0 }.map { [$0] } ?? []))
        assertSameBodies(texts, bodies(markdown).filter { texts[$0.key] != nil })
        XCTAssertEqual(markdown.note(with: moved)?.notebookID, nil)
        XCTAssertEqual(try String(contentsOf: content.appendingPathComponent("Mine.md"), encoding: .utf8).contains("written by hand"), true)
    }

    func testAFileEditedOutsideNoteItIsKeptAsAVisibleCopyWhenConvertingBack() async throws {
        _ = try await converter(try makeRTFDLibrary()).convert(to: .markdown(content))
        _ = try await converter(openMarkdown()).convert(to: .rtfd)
        let rtfd = openRTFD()
        let target = try XCTUnwrap(rtfd.notes.first { $0.title == "Target" }).id
        let source = try XCTUnwrap(rtfd.notes.first { $0.title == "Source" }).id
        rtfd.updateBody(target, body("Target", ["Edited in NoteIt"]))
        rtfd.updateBody(source, body("Source", ["Edited in NoteIt too"]))
        rtfd.flush()
        let targetPath = try XCTUnwrap(markdownIDs(content).first { $0.value == target }?.key)
        let targetURL = content.appendingPathComponent(targetPath)
        let outside = try String(contentsOf: targetURL, encoding: .utf8).replacingOccurrences(of: "Deep inside", with: "Edited outside")
        try Data(outside.utf8).write(to: targetURL)
        try Data(outside.utf8).write(to: targetURL.deletingLastPathComponent().appendingPathComponent("Target copy.md"))

        let result = try await converter(rtfd).convert(to: .markdown(content))
        let folder = (targetPath as NSString).deletingLastPathComponent + "/"
        XCTAssertEqual(Set(result.conflictCopies), [folder + "Target (Edited Outside NoteIt).md",
                                                    folder + "Target copy (Edited Outside NoteIt).md"])
        let files = markdownIDs(content)
        XCTAssertEqual(files[targetPath], target)
        XCTAssertTrue(try String(contentsOf: targetURL, encoding: .utf8).contains("Edited in NoteIt"))
        XCTAssertNil(files[folder + "Target copy.md"], "the outside duplicate is now a copy with its own id")
        for copy in result.conflictCopies {
            XCTAssertTrue(try String(contentsOf: content.appendingPathComponent(copy), encoding: .utf8).contains("Edited outside"))
            let id = try XCTUnwrap(files[copy] ?? nil)
            XCTAssertNotEqual(id, target)
        }
        let copyIDs = result.conflictCopies.compactMap { files[$0] ?? nil }
        XCTAssertEqual(Set(copyIDs).count, 2)
        XCTAssertNil(markdownIDs(content).keys.first { $0.contains("Source (Edited") }, "a file NoteIt wrote itself is replaced quietly")
        let markdown = openMarkdown()
        for id in copyIDs { XCTAssertNotNil(markdown.note(with: id), "a copy is a note of its own") }
        XCTAssertTrue(markdown.body(for: target).string.contains("Edited in NoteIt"))
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent(".noteit").path)
                       && ((try? fm.contentsOfDirectory(atPath: content.appendingPathComponent(".noteit").path)) ?? [])
                           .contains { $0.hasPrefix("replaced-") }, "nothing is hidden in .noteit")
        XCTAssertFalse(trashed.isEmpty, "the files that were replaced went to the Trash")
    }

    func testConvertingToRTFDTrashesReplacedFilesAndLeavesOtherFilesInTheFolder() async throws {
        _ = try await converter(try makeRTFDLibrary()).convert(to: .markdown(content))
        let replaced = content.appendingPathComponent(".noteit/replaced-convert-old/Plan.md")
        try fm.createDirectory(at: replaced.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Plan\n\nmine\n".utf8).write(to: replaced)
        let other = content.appendingPathComponent(".noteit/notes-to-self.txt")
        try Data("mine".utf8).write(to: other)

        _ = try await converter(openMarkdown()).convert(to: .rtfd)
        XCTAssertEqual(trashed, ["Notes/.noteit/replaced-convert-old"])
        XCTAssertTrue(fm.fileExists(atPath: other.path), "a file NoteIt didn't write stays")
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent(".noteit/library.json").path))
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent(".noteit/staging").path))
    }

    func testRollingBackAConversionIntoAnEarlierFolderPutsTheReplacedFilesBack() async throws {
        _ = try await converter(try makeRTFDLibrary()).convert(to: .markdown(content))
        _ = try await converter(openMarkdown()).convert(to: .rtfd)
        let rtfd = openRTFD()
        let edited = try XCTUnwrap(rtfd.notes.first { $0.title == "Target" }).id
        rtfd.updateBody(edited, body("Target", ["Edited while RTFD"]))
        rtfd.flush()
        let before = tree(content)

        let converter = converter(rtfd)
        converter.interruption = .moved
        do {
            _ = try await converter.convert(to: .markdown(content))
            XCTFail("not interrupted")
        } catch is LibraryConverter.Interrupted {}
        XCTAssertNotEqual(tree(content).filter { !$0.key.hasPrefix(".noteit") }, before.filter { !$0.key.hasPrefix(".noteit") })
        LibraryConverter.finishInterrupted(dataDir: data)
        assertSameTree(tree(content), before, "the earlier files are back and nothing else is left")
    }

    /// An RTFD library converted to Markdown and back, stopped after the RTFD bodies moved into the data folder.
    private func interruptedConversionToRTFD() async throws {
        _ = try await converter(try makeRTFDLibrary()).convert(to: .markdown(content))
        let converter = converter(openMarkdown())
        converter.interruption = .moved
        do {
            _ = try await converter.convert(to: .rtfd)
            XCTFail("not interrupted")
        } catch is LibraryConverter.Interrupted {}
    }

    private func launcher() -> LibraryLauncher {
        LibraryLauncher(dataDirectoryOverride: { [data] in data.path }, baseDirectory: { [root] in root! },
                        isLegacyAppRunning: { false }, quitLegacyApp: { false }, log: { _ in })
    }

    func testADamagedLocationFileDuringAnInterruptedConversionIsNeverRolledBack() async throws {
        try await interruptedConversionToRTFD()
        try Data("{ damaged".utf8).write(to: LibraryLocationFile.url(dataDir: data))
        let dataBefore = tree(data)
        let contentBefore = tree(content)

        for _ in 0..<2 {
            guard case .open(let location) = launcher().decide() else { return XCTFail("not opened") }
            XCTAssertFalse(location.seedsFreshLibrary)
        }
        assertSameTree(tree(data), dataBefore, "nothing is set aside, rolled back or seeded")
        assertSameTree(tree(content), contentBefore)
        XCTAssertNotNil(LibraryConversionJournal.load(dataDir: data))
    }

    func testAMissingLocationFileThatExistedBeforeTheConversionLeavesItAlone() async throws {
        try await interruptedConversionToRTFD()
        try fm.removeItem(at: LibraryLocationFile.url(dataDir: data))
        let dataBefore = tree(data)

        LibraryConverter.finishInterrupted(dataDir: data)
        guard case .open(let location) = launcher().decide() else { return XCTFail("not opened") }
        XCTAssertFalse(location.seedsFreshLibrary)
        assertSameTree(tree(data), dataBefore)
    }

    func testRollingBackAConversionToRTFDKeepsBodiesChangedSince() async throws {
        try await interruptedConversionToRTFD()
        let notes = data.appendingPathComponent("notes", isDirectory: true)
        let packages = try fm.contentsOfDirectory(atPath: notes.path).filter { $0.hasSuffix(".rtfd") }.sorted()
        XCTAssertGreaterThan(packages.count, 1)
        let edited = notes.appendingPathComponent(packages[0]).appendingPathComponent("TXT.rtf")
        try Data("{\\rtf1 edited since}".utf8).write(to: edited)

        LibraryConverter.finishInterrupted(dataDir: data)
        XCTAssertNil(LibraryConversionJournal.load(dataDir: data))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: notes.path).filter { $0.hasSuffix(".rtfd") }, [packages[0]],
                       "only bodies that still hold what the conversion wrote are removed")
        XCTAssertEqual(try String(contentsOf: edited, encoding: .utf8), "{\\rtf1 edited since}")
    }

    func testAnEditInAnotherAppDuringTheConversionStopsIt() async throws {
        _ = try await converter(try makeRTFDLibrary()).convert(to: .markdown(content))
        let markdown = openMarkdown()
        let file = content.appendingPathComponent("Work/Projects/Target.md")
        let converter = converter(markdown)
        converter.verify = { _, a, b in
            if let text = try? String(contentsOf: file, encoding: .utf8), text.contains("Deep inside") {
                try? Data(text.replacingOccurrences(of: "Deep inside", with: "Edited elsewhere").utf8).write(to: file)
            }
            return BodyCodec.semanticallyEqual(a, b)
        }
        do {
            _ = try await converter.convert(to: .rtfd)
            XCTFail("converted")
        } catch let error as LibraryConversionError {
            XCTAssertEqual(error, .libraryChangedDuringConversion)
        }
        guard case .loaded(let location) = LibraryLocationFile.load(dataDir: data) else { return XCTFail("location") }
        XCTAssertEqual(location.format, .markdown)
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("notes").path))
        XCTAssertNil(LibraryConversionJournal.load(dataDir: data))
        let note = try XCTUnwrap(markdown.notes.first { $0.title == "Target" })
        XCTAssertTrue(markdown.body(for: note.id).string.contains("Edited elsewhere"))
    }

    func testAStoreClosedForTheSwitchRefusesSyncApplies() async throws {
        let store = try makeRTFDLibrary()
        let note = try XCTUnwrap(store.notes.first { $0.title == "Target" })
        let adapter = NoteStoreSyncAdapter(store: store, deviceID: "test")
        store.closeForLibrarySwitch()
        do {
            try await adapter.applyDeletion(note.id, kind: .note)
            XCTFail("applied")
        } catch {}
        XCTAssertNotNil(store.note(with: note.id))
    }

    // MARK: Folders

    func testFoldersThatOverlapTheLibraryAreRefusedBeforeAnythingHappens() async throws {
        let store = try makeRTFDLibrary()
        let link = root.appendingPathComponent("link-to-notes")
        try fm.createSymbolicLink(at: link, withDestinationURL: data.appendingPathComponent("notes"))
        let refused = [data, data.appendingPathComponent("notes"), data.appendingPathComponent("backups"),
                       data.appendingPathComponent("backups/staging-x"), data.appendingPathComponent("sync-meta-raw"),
                       data.appendingPathComponent("body-extras"), data.appendingPathComponent("history"),
                       data.appendingPathComponent("notes/sub"), root!, link,
                       URL(fileURLWithPath: data.path.uppercased(), isDirectory: true)]
        let before = tree(root)
        for folder in refused {
            XCTAssertTrue(LibraryConverter.inspect(folder, dataDir: data).overlapsLibrary, folder.path)
            do {
                _ = try await converter(store).convert(to: .markdown(folder))
                XCTFail("converted into \(folder.path)")
            } catch let error as LibraryConversionError {
                XCTAssertEqual(error, .destinationOverlapsLibrary, folder.path)
            }
        }
        assertSameTree(tree(root), before)
        XCTAssertEqual(pauses, 0)
        XCTAssertEqual(flushes, 0)
        XCTAssertFalse(store.libraryConversionInProgress)

        for folder in [root.appendingPathComponent("data-notes"), content] {
            XCTAssertFalse(LibraryConverter.inspect(folder, dataDir: data).overlapsLibrary, folder.path)
        }
    }

    func testInspectReportsCloudServicesAndAnEarlierLibrary() throws {
        func folder(_ path: String) throws -> URL {
            let url = root!.appendingPathComponent(path, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        XCTAssertEqual(LibraryConverter.inspect(try folder("Library/CloudStorage/OneDrive-Personal/Notes"), dataDir: data).cloudService,
                       .oneDrive)
        XCTAssertEqual(LibraryConverter.inspect(try folder("Library/CloudStorage/GoogleDrive-me@x.com/My Drive/N"), dataDir: data)
            .cloudService, .googleDrive)
        XCTAssertEqual(LibraryConverter.inspect(try folder("Library/CloudStorage/Box-Box/N"), dataDir: data).cloudService, .other("Box"))
        XCTAssertEqual(LibraryConverter.inspect(try folder("Library/Mobile Documents/com~apple~CloudDocs/Notes"), dataDir: data)
            .cloudService, .iCloudDrive)
        let dropbox = try folder("Dropbox")
        try Data().write(to: dropbox.appendingPathComponent(".dropbox"))
        XCTAssertEqual(LibraryConverter.inspect(try folder("Dropbox/Notes/Work"), dataDir: data).cloudService, .dropbox)
        XCTAssertNil(LibraryConverter.inspect(try folder("Documents/Dropbox/Notes"), dataDir: data).cloudService)

        let plain = try folder("Documents/NoteIt")
        var inspection = LibraryConverter.inspect(plain, dataDir: data)
        XCTAssertNil(inspection.cloudService)
        XCTAssertTrue(inspection.isEmpty)
        XCTAssertEqual(inspection.markdownFileCount, 0)
        let id = UUID()
        try fm.createDirectory(at: plain.appendingPathComponent(".noteit"), withIntermediateDirectories: true)
        try LibraryConverter.libraryFileData(libraryID: id).write(to: LibraryConverter.libraryFileURL(in: plain))
        try Data("# A\n".utf8).write(to: plain.appendingPathComponent("A.md"))
        inspection = LibraryConverter.inspect(plain, dataDir: data)
        XCTAssertEqual(inspection.libraryID, id)
        XCTAssertEqual(inspection.markdownFileCount, 1)
        XCTAssertFalse(inspection.isEmpty)
    }

    // MARK: Previous library

    func testThePreviousLibraryIsOnlyTrashedWhenTheUserChooses() throws {
        let created = Date(timeIntervalSince1970: 1_792_368_000) // 19 Oct 2026
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let url = try PreviousLibrary.create(in: data, now: created)
        XCTAssertEqual(url.lastPathComponent, "Previous Library 2026-10-19")
        XCTAssertEqual(try PreviousLibrary.create(in: data, now: created).lastPathComponent, "Previous Library 2026-10-19 2")
        try Data(count: 1000).write(to: url.appendingPathComponent("body"))

        var previous = try XCTUnwrap(PreviousLibrary.find(dataDir: data).first { $0.url.lastPathComponent == url.lastPathComponent })
        XCTAssertFalse(previous.shouldAsk(now: created.addingTimeInterval(29 * 86400)))
        XCTAssertTrue(previous.shouldAsk(now: created.addingTimeInterval(30 * 86400)))
        XCTAssertTrue(previous.title(size: 210_000_000).hasPrefix("Previous library from 19 Oct 2026 ("))
        XCTAssertEqual(previous.question(size: 210_000_000),
                       "Your previous library from 19 Oct 2026 is still on this Mac (210 MB). Move it to the Trash?")
        try previous.keepIt()
        previous = try XCTUnwrap(PreviousLibrary.find(dataDir: data).first { $0.url.lastPathComponent == url.lastPathComponent })
        XCTAssertFalse(previous.shouldAsk(now: created.addingTimeInterval(400 * 86400)))
        XCTAssertTrue(fm.fileExists(atPath: url.path))

        var trashed: [URL] = []
        try previous.moveToTrash { trashed.append($0) }
        XCTAssertEqual(trashed, [url])
    }
}
