import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItSync

/// Reports `.markdown` so NoteStore leaves the sidecar off, returns fixed extras from every read and records the
/// extras of every write.
final class ExtrasSpyStorage: NoteBodyStorage, @unchecked Sendable {
    let base: RTFDBodyStorage
    var readExtras: ContainerExtras
    private(set) var writtenExtras: [ContainerExtras] = []

    init(rootURL: URL, readExtras: ContainerExtras) {
        base = RTFDBodyStorage(rootURL: rootURL)
        self.readExtras = readExtras
    }

    var kind: LibraryFormatKind { .markdown }
    var contentRootURL: URL { base.contentRootURL }
    func idsOnDisk() -> [UUID] { base.idsOnDisk() }
    func read(_ id: UUID) throws -> StoredBody {
        var stored = try base.read(id)
        stored.extras = readExtras
        return stored
    }
    func write(_ text: NSAttributedString, extras: ContainerExtras, for note: NoteMeta, notebook: Notebook?) throws {
        writtenExtras.append(extras)
        try base.write(text, extras: extras, for: note, notebook: notebook)
    }
    func writeMetadataOnly(for note: NoteMeta, notebook: Notebook?) throws {
        try base.writeMetadataOnly(for: note, notebook: notebook)
    }
    func prepareTemp(_ text: NSAttributedString, extras: ContainerExtras, meta: NoteMeta) throws -> URL {
        writtenExtras.append(extras)
        return try base.prepareTemp(text, extras: extras, meta: meta)
    }
    func installTemp(_ temp: URL, for note: NoteMeta, notebook: Notebook?) throws {
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

/// A minimal Markdown store: one `<id>.md` file per note, written with `BodyCodec.markdown`.
final class MarkdownTestStorage: NoteBodyStorage, @unchecked Sendable {
    let contentRootURL: URL
    private(set) var preparedTemps = 0

    init(rootURL: URL) {
        contentRootURL = rootURL.appendingPathComponent("markdown", isDirectory: true)
    }

    var kind: LibraryFormatKind { .markdown }
    func idsOnDisk() -> [UUID] {
        ((try? FileManager.default.contentsOfDirectory(at: contentRootURL, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { $0.pathExtension == "md" ? UUID(uuidString: $0.deletingPathExtension().lastPathComponent) : nil }
    }
    func read(_ id: UUID) throws -> StoredBody {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        return try BodyCodec.markdown.read(at: url)
    }
    func write(_ text: NSAttributedString, extras: ContainerExtras, for note: NoteMeta, notebook: Notebook?) throws {
        try installTemp(try prepareTemp(text, extras: extras, meta: note), for: note, notebook: notebook)
    }
    func writeMetadataOnly(for note: NoteMeta, notebook: Notebook?) throws {}
    func prepareTemp(_ text: NSAttributedString, extras: ContainerExtras, meta: NoteMeta) throws -> URL {
        preparedTemps += 1
        try FileManager.default.createDirectory(at: contentRootURL, withIntermediateDirectories: true)
        let temp = contentRootURL.appendingPathComponent(".\(UUID().uuidString).md.tmp")
        try BodyCodec.markdown.write(text, extras: extras, meta: meta, to: temp)
        return temp
    }
    func installTemp(_ temp: URL, for note: NoteMeta, notebook: Notebook?) throws {
        guard rename(temp.path, fileURL(for: note.id).path) == 0 else { throw POSIXError(.EIO) }
    }
    func moveToTrash(_ id: UUID) throws { try? FileManager.default.removeItem(at: fileURL(for: id)) }
    func recover(_ id: UUID) throws -> StoredBody? { nil }
    func removePermanently(_ id: UUID) throws { try? FileManager.default.removeItem(at: fileURL(for: id)) }
    func revisionInputURL(for id: UUID) -> URL? { fileURL(for: id) }
    func fileURL(for id: UUID) -> URL { contentRootURL.appendingPathComponent("\(id.uuidString).md") }
    func recoveryCopy(_ text: NSAttributedString, for id: UUID, in directory: URL) throws -> URL {
        throw CocoaError(.featureUnsupported)
    }
    func renameNotebook(_ notebook: Notebook, from oldName: String) throws {}
    func removeNotebook(_ notebook: Notebook) throws {}
}

/// foundations Task 4.1: `bodyExtras` and the body-extras sidecar of RTFD stores.
@MainActor
final class BodyExtrasTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private typealias S = RawMetaSupport

    private let extrasA = ContainerExtras(frontMatter: "title: A", extra: ["futureA": .string("a")])
    private let extrasB = ContainerExtras(frontMatter: "title: B", extra: ["futureB": .number("2")])

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-body-extras-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: Spy storage (sidecar off)

    func testExtrasPassedThroughEveryWrite() throws {
        let extras = ContainerExtras(frontMatter: "title: x", extra: ["future": .object(["k": .bool(true)])])
        let first = makeStore(storage: ExtrasSpyStorage(rootURL: root, readExtras: .empty))
        let id = first.createNote(in: nil, initial: NSAttributedString(string: "Title\nbody")).id
        first.flush()

        let spy = ExtrasSpyStorage(rootURL: root, readExtras: extras)
        let store = makeStore(storage: spy)
        XCTAssertEqual(store.body(for: id).string, "Title\nbody")
        XCTAssertEqual(store.bodyExtras[id], extras)

        store.stageEditorCommit(id, NSAttributedString(string: "Title\nedited in the editor"))
        XCTAssertTrue(store.commitStagedEditorBody(id))
        store.flush()
        store.updateBody(id, NSAttributedString(string: "Title\nupdated"))
        store.flush()
        store.updateBody(id, NSAttributedString())
        store.flush()
        XCTAssertEqual(spy.writtenExtras, [extras, extras, extras])
        XCTAssertFalse(fm.fileExists(atPath: store.bodyExtrasDirectoryURL.path), "no sidecar for a non-RTFD store")
        XCTAssertEqual(store.bodyExtras[id], extras)

        S.purge(store, id)
        XCTAssertNil(store.note(with: id))
        XCTAssertNil(store.bodyExtras[id])
    }

    // MARK: RTFD sidecar

    func testRTFDSidecarKeepsExtrasAcrossRelaunch() throws {
        let id = UUID()
        let extras = ContainerExtras(frontMatter: "title: Remote\ntags: [a]",
                                     extra: ["futureKey": .number("9007199254740993")])
        let store = makeStore()
        try apply(store, id, "Remote\nbody", extras: extras)
        XCTAssertEqual(store.bodyExtras[id], extras)
        let json = try String(contentsOf: store.bodyExtrasFileURL(id), encoding: .utf8)
        XCTAssertTrue(json.contains("9007199254740993"), json)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.body(for: id).string, "Remote\nbody")
        XCTAssertEqual(relaunched.bodyExtras[id], extras)
        relaunched.stageEditorCommit(id, NSAttributedString(string: "Remote\nedited"))
        relaunched.commitStagedEditorBody(id)
        relaunched.flush()
        XCTAssertFalse(relaunched.isBodyDirty(id))
        let sidecar = try readSidecar(relaunched, id)
        XCTAssertEqual(sidecar.current.extras, extras)
        XCTAssertNil(sidecar.previous)
        XCTAssertEqual(sidecar.current.bodySHA256, try RTFDBodyStorage.packageDigest(at: relaunched.bodyURL(for: id)))
        XCTAssertEqual(makeStore().bodyExtras(loading: id), extras)
    }

    func testRTFDSidecarKeepsUnknownLanguage() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: try codeText(["zig-nightly", "swift"])).id
        store.flush()
        XCTAssertEqual(try readSidecar(store, id).current.codeLanguageIDs, ["zig-nightly", "swift"])
        XCTAssertEqual(try languages(makeStore(), id), ["zig-nightly", "swift"])
    }

    func testSidecarCountMismatchDropsIDs() throws {
        let store = makeStore()
        let id = try saveNote(store, try codeText(["zig-nightly"]), extras: extrasA)
        try rewriteOutside(store, id, try codeText(["zig-nightly", "odin"]))

        var notices: [BodyExtrasNotice] = []
        let relaunched = makeStore()
        relaunched.bodyExtrasNoticeHandler = { _, notice in notices.append(notice) }
        let text = relaunched.body(for: id)
        XCTAssertFalse(hasLanguageID(text))
        XCTAssertEqual(relaunched.bodyExtras[id], extrasA)
        XCTAssertTrue(notices.contains(.codeCountMismatch(text: 2, entry: 1)), "\(notices)")
    }

    func testUnmatchedSidecarUsesCurrent() throws {
        let store = makeStore()
        let id = try saveNote(store, try codeText(["zig-nightly"]), extras: extrasA)
        try rewriteOutside(store, id, try codeText(["zig-nightly"], title: "Changed elsewhere"))

        var notices: [BodyExtrasNotice] = []
        let relaunched = makeStore()
        relaunched.bodyExtrasNoticeHandler = { _, notice in notices.append(notice) }
        XCTAssertTrue(relaunched.body(for: id).string.hasPrefix("Changed elsewhere"))
        XCTAssertEqual(relaunched.bodyExtras[id], extrasA)
        XCTAssertEqual(notices, [.digestMismatch])
        XCTAssertEqual(try languages(relaunched, id), ["zig-nightly"])

        try rewriteOutside(relaunched, id, try codeText(["zig-nightly", "odin"]))
        notices = []
        let again = makeStore()
        again.bodyExtrasNoticeHandler = { _, notice in notices.append(notice) }
        XCTAssertFalse(hasLanguageID(again.body(for: id)))
        XCTAssertEqual(again.bodyExtras[id], extrasA)
        XCTAssertEqual(notices, [.digestMismatch, .codeCountMismatch(text: 2, entry: 1)])
    }

    func testSidecarRemovedOnPurge() throws {
        let store = makeStore()
        let id = try saveNote(store, NSAttributedString(string: "Purged\nbody"), extras: extrasA)
        let sidecarURL = store.bodyExtrasFileURL(id)
        XCTAssertNil(try readSidecar(store, id).previous, "a successful save leaves no previous")
        store.moveToRecentlyDeleted([id])
        store.flush()
        XCTAssertTrue(fm.fileExists(atPath: sidecarURL.path), "Recently Deleted keeps the sidecar")

        let saved = try Data(contentsOf: store.libraryURL)
        try fm.removeItem(at: store.libraryURL)
        try fm.createDirectory(at: store.libraryURL, withIntermediateDirectories: false)
        store.deleteNow([id])
        store.flush()
        XCTAssertTrue(store.hasUnsavedLibrary)
        XCTAssertTrue(fm.fileExists(atPath: sidecarURL.path), "not before the library save lands")
        try fm.removeItem(at: store.libraryURL)
        try saved.write(to: store.libraryURL)
        store.flush()
        XCTAssertFalse(store.hasUnsavedLibrary)
        XCTAssertFalse(fm.fileExists(atPath: sidecarURL.path))

        let other = try saveNote(store, try codeText(["zig-nightly"]), extras: extrasA)
        XCTAssertTrue(fm.fileExists(atPath: store.bodyExtrasFileURL(other).path))
        store.setBodyExtras(.empty, for: other)
        store.updateBody(other, NSAttributedString(string: "No extras left"))
        store.flush()
        XCTAssertFalse(store.isBodyDirty(other))
        XCTAssertFalse(fm.fileExists(atPath: store.bodyExtrasFileURL(other).path))
    }

    func testSidecarWriteFailureLeavesBodyUntouched() throws {
        let store = makeStore()
        let id = try saveNote(store, NSAttributedString(string: "Saved\nbody"), extras: extrasA)
        let before = try packageFiles(store.bodyURL(for: id))
        try fm.removeItem(at: store.bodyExtrasDirectoryURL)
        try Data("not a folder".utf8).write(to: store.bodyExtrasDirectoryURL)

        let unsaved = NSAttributedString(string: "Saved\nbody, then edited")
        store.updateBody(id, unsaved)
        XCTAssertThrowsError(try store.persistNow(id)) { XCTAssertEqual($0 as? PersistNowError, .bodyNotSaved) }
        store.flush()
        XCTAssertEqual(try packageFiles(store.bodyURL(for: id)), before)
        XCTAssertTrue(store.isBodyDirty(id))
        XCTAssertTrue(store.body(for: id).isEqual(to: unsaved))
        XCTAssertTrue(try leftoverTemps(store).isEmpty)
    }

    func testUnreadableSidecarBlocksWrites() throws {
        let store = makeStore()
        let id = try saveNote(store, NSAttributedString(string: "Saved\nbody"), extras: extrasA)
        let sidecarURL = store.bodyExtrasFileURL(id)
        try Data("{ not json".utf8).write(to: sidecarURL)
        let sidecarBefore = try Data(contentsOf: sidecarURL)
        let packageBefore = try packageFiles(store.bodyURL(for: id))

        let relaunched = makeStore()
        XCTAssertEqual(try relaunched.readStoredBody(id).readOnlyReason, StoredBody.bodyExtrasUnreadable)
        XCTAssertEqual(relaunched.body(for: id).string, "Saved\nbody")
        XCTAssertTrue(relaunched.isBodyWriteBlocked(id))
        XCTAssertEqual(relaunched.loadError(for: id), StoredBody.bodyExtrasUnreadable)
        XCTAssertFalse(relaunched.hasUnreadableBody(id))
        relaunched.updateBody(id, NSAttributedString(string: "Saved\nbody, edited"))
        relaunched.flush()
        XCTAssertEqual(try Data(contentsOf: sidecarURL), sidecarBefore)
        XCTAssertEqual(try packageFiles(relaunched.bodyURL(for: id)), packageBefore)
        XCTAssertThrowsError(try relaunched.persistNow(id)) { XCTAssertEqual($0 as? PersistNowError, .writeBlocked) }
    }

    func testCrashAfterSidecarStageKeepsOldExtras() throws {
        let store = makeStore()
        let id = try saveNote(store, try codeText(["zig-nightly"]), extras: extrasA)
        store.setBodyExtras(extrasB, for: id)
        store.updateBody(id, try codeText(["zig-nightly", "odin"], title: "New"))
        store.bodyWriteInterruption = .afterSidecarStage
        store.flush()
        XCTAssertTrue(store.isBodyDirty(id))

        let sidecar = try readSidecar(store, id)
        XCTAssertEqual(sidecar.current.extras, extrasB)
        XCTAssertEqual(sidecar.previous?.extras, extrasA)
        let relaunched = makeStore()
        XCTAssertTrue(relaunched.body(for: id).string.hasPrefix("Title"))
        XCTAssertEqual(relaunched.bodyExtras[id], extrasA)
        XCTAssertEqual(try languages(relaunched, id), ["zig-nightly"])
        XCTAssertTrue(try leftoverTemps(store).isEmpty)
    }

    func testCrashAfterBodyInstallKeepsNewExtras() throws {
        let store = makeStore()
        let id = try saveNote(store, try codeText(["zig-nightly"]), extras: extrasA)
        store.setBodyExtras(extrasB, for: id)
        store.updateBody(id, try codeText(["zig-nightly", "odin"], title: "New"))
        store.bodyWriteInterruption = .afterBodyInstall
        store.flush()
        XCTAssertNotNil(try readSidecar(store, id).previous)

        let relaunched = makeStore()
        XCTAssertTrue(relaunched.body(for: id).string.hasPrefix("New"))
        XCTAssertEqual(relaunched.bodyExtras[id], extrasB)
        XCTAssertEqual(try languages(relaunched, id), ["zig-nightly", "odin"])
        relaunched.updateBody(id, try codeText(["zig-nightly", "odin"], title: "Newer"))
        relaunched.flush()
        let sidecar = try readSidecar(relaunched, id)
        XCTAssertNil(sidecar.previous)
        XCTAssertEqual(sidecar.current.extras, extrasB)
    }

    func testEmptyExtrasNeverDeleteBeforeInstall() throws {
        let store = makeStore()
        let id = try saveNote(store, NSAttributedString(string: "Old\nbody"), extras: extrasA)
        let sidecarURL = store.bodyExtrasFileURL(id)
        store.setBodyExtras(.empty, for: id)
        store.updateBody(id, NSAttributedString(string: "New\nbody"))

        store.bodyWriteInterruption = .afterSidecarStage
        store.flush()
        XCTAssertTrue(fm.fileExists(atPath: sidecarURL.path))
        var relaunched = makeStore()
        XCTAssertEqual(relaunched.body(for: id).string, "Old\nbody")
        XCTAssertEqual(relaunched.bodyExtras[id], extrasA)

        store.bodyWriteInterruption = .afterBodyInstall
        store.flush()
        XCTAssertTrue(fm.fileExists(atPath: sidecarURL.path))
        relaunched = makeStore()
        XCTAssertEqual(relaunched.body(for: id).string, "New\nbody")
        XCTAssertEqual(relaunched.bodyExtras[id], .empty)

        store.bodyWriteInterruption = nil
        store.flush()
        XCTAssertFalse(store.isBodyDirty(id))
        XCTAssertFalse(fm.fileExists(atPath: sidecarURL.path))
    }

    func testCrashWithoutPriorSidecarKeepsEmptyExtras() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Old\nbody")).id
        store.flush()
        XCTAssertFalse(fm.fileExists(atPath: store.bodyExtrasFileURL(id).path))
        let oldDigest = try RTFDBodyStorage.packageDigest(at: store.bodyURL(for: id))

        store.setBodyExtras(extrasB, for: id)
        store.updateBody(id, NSAttributedString(string: "New\nbody"))
        store.bodyWriteInterruption = .afterSidecarStage
        store.flush()
        let sidecar = try readSidecar(store, id)
        XCTAssertEqual(sidecar.previous, BodyExtrasEntry(bodySHA256: oldDigest, extras: .empty, codeLanguageIDs: []))
        XCTAssertEqual(sidecar.current.extras, extrasB)
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.body(for: id).string, "Old\nbody")
        XCTAssertEqual(relaunched.bodyExtras[id], .empty)
    }

    func testSidecarFinishFailureKeepsWrite() throws {
        let store = makeStore()
        let id = try saveNote(store, NSAttributedString(string: "Old\nbody"), extras: extrasA)
        store.failsBodyExtrasFinish = true
        store.setBodyExtras(extrasB, for: id)
        store.updateBody(id, NSAttributedString(string: "New\nbody"))
        store.flush()
        XCTAssertFalse(store.isBodyDirty(id))
        XCTAssertNotNil(try readSidecar(store, id).previous, "step 3 didn't run")
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.body(for: id).string, "New\nbody")
        XCTAssertEqual(relaunched.bodyExtras[id], extrasB)
    }

    func testFailedSyncApplyKeepsExtras() throws {
        let id = UUID()
        let store = makeStore()
        try apply(store, id, "Remote\nfirst", extras: extrasA)
        store.bodyWriteInterruption = .afterSidecarStage
        XCTAssertThrowsError(try apply(store, id, "Remote\nsecond", extras: extrasB))
        XCTAssertEqual(store.bodyExtras[id], extrasA)
        XCTAssertEqual(store.body(for: id).string, "Remote\nfirst")
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.body(for: id).string, "Remote\nfirst")
        XCTAssertEqual(relaunched.bodyExtras[id], extrasA)

        store.bodyWriteInterruption = nil
        try apply(store, id, "Remote\nsecond", extras: extrasB)
        XCTAssertEqual(store.bodyExtras[id], extrasB)
        XCTAssertNil(try readSidecar(store, id).previous)
        XCTAssertTrue(try leftoverTemps(store).isEmpty)
    }

    func testSyncApplyKeepsTheLocalUnknownKeysOnlyForAnRTFDBody() throws {
        let id = UUID()
        let store = makeStore()
        try apply(store, id, "Remote\nfirst", extras: extrasA)
        try apply(store, id, "Remote\nsecond", extras: .empty, rtfd: true)
        XCTAssertEqual(store.bodyExtras[id], ContainerExtras(frontMatter: extrasA.frontMatter))

        let relaunched = makeStore()
        XCTAssertNil(relaunched.bodyExtras[id])
        try apply(relaunched, id, "Remote\nthird", extras: .empty, rtfd: true)
        XCTAssertEqual(relaunched.bodyExtras[id], ContainerExtras(frontMatter: extrasA.frontMatter))
        XCTAssertEqual(try readSidecar(relaunched, id).current.extras, ContainerExtras(frontMatter: extrasA.frontMatter))

        let noKeys = ContainerExtras(extra: ["futureB": .number("2")])
        try apply(relaunched, id, "Remote\nfourth", extras: noKeys)
        XCTAssertEqual(relaunched.bodyExtras[id], noKeys)
        XCTAssertEqual(try readSidecar(relaunched, id).current.extras, noKeys)
        XCTAssertNil(makeStore().storedFrontMatter(id))
    }

    func testMarkdownStoreWritesOwnedAndKeptKeys() throws {
        let aliases = ContainerExtras(frontMatter: "aliases: [Local]")
        let store = makeStore(storage: MarkdownTestStorage(rootURL: root))
        let id = try saveNote(store, NSAttributedString(string: "Title\nbody"), extras: aliases)
        let file = { (try? String(contentsOf: store.bodyStorage.fileURL(for: id), encoding: .utf8)) ?? "" }
        XCTAssertTrue(file().hasPrefix("---\nid: \(id.uuidString)\ncreated: "), file())
        XCTAssertTrue(file().contains("\naliases: [Local]\n---\n"), file())

        try apply(store, id, "Remote\nfirst", extras: .empty, rtfd: true)
        XCTAssertTrue(file().hasPrefix("---\nid: \(id.uuidString)\ncreated: 2026-01-01T00:00:00Z\n"), file())
        XCTAssertTrue(file().contains("\naliases: [Local]\n---\n"), file())
        XCTAssertEqual(store.bodyExtras[id], aliases)

        let relaunched = makeStore(storage: MarkdownTestStorage(rootURL: root))
        XCTAssertNil(relaunched.bodyExtras[id])
        XCTAssertEqual(relaunched.storedFrontMatter(id), "aliases: [Local]")
        try apply(relaunched, id, "Remote\nsecond", extras: .empty, rtfd: true)
        XCTAssertTrue(file().contains("\naliases: [Local]\n---\n"), file())

        try apply(relaunched, id, "Remote\nthird", extras: .empty)
        XCTAssertTrue(file().hasPrefix("---\nid: \(id.uuidString)\n"), file())
        XCTAssertFalse(file().contains("aliases"), file())
        XCTAssertEqual(try relaunched.bodyStorage.read(id).text.string.trimmingCharacters(in: .newlines), "Remote\nthird")
    }

    func testMarkdownSyncApplyWritesTheIncomingFrontMatterOnce() throws {
        let id = UUID()
        let storage = MarkdownTestStorage(rootURL: root)
        let store = makeStore(storage: storage)
        let incoming = ContainerExtras(frontMatter: "aliases: [Remote]\ntags: [a]")
        try apply(store, id, "Remote\nfirst", extras: incoming)
        let file = try String(contentsOf: storage.fileURL(for: id), encoding: .utf8)
        XCTAssertTrue(file.contains("\naliases: [Remote]\ntags: [a]\n---\n"), file)
        XCTAssertEqual(store.bodyExtras[id], incoming)
        XCTAssertEqual(storage.preparedTemps, 1)

        try apply(store, id, "Remote\nsecond", extras: .empty, rtfd: true)
        XCTAssertTrue(try String(contentsOf: storage.fileURL(for: id), encoding: .utf8).contains("\naliases: [Remote]\ntags: [a]\n"))
        XCTAssertEqual(storage.preparedTemps, 2)
        XCTAssertTrue(try markdownTemps(storage).isEmpty)
    }

    func testMarkdownSyncApplyRebuildsWhenTheKeysChangeAfterPrepare() throws {
        let storage = MarkdownTestStorage(rootURL: root)
        let store = makeStore(storage: storage)
        let id = try saveNote(store, NSAttributedString(string: "Title\nbody"), extras: ContainerExtras(frontMatter: "aliases: [Old]"))
        let prepared = try prepare(store, id, "Remote\nbody")
        store.setBodyExtras(ContainerExtras(frontMatter: "aliases: [New]"), for: id)
        let before = storage.preparedTemps
        try store.applyPreparedRemoteNote(prepared)
        XCTAssertEqual(storage.preparedTemps, before + 1)
        XCTAssertTrue(try String(contentsOf: storage.fileURL(for: id), encoding: .utf8).contains("\naliases: [New]\n---\n"))
        XCTAssertTrue(try markdownTemps(storage).isEmpty)
    }

    // MARK: Helpers

    private func markdownTemps(_ storage: MarkdownTestStorage) throws -> [String] {
        try fm.contentsOfDirectory(atPath: storage.contentRootURL.path).filter { $0.hasSuffix(".tmp") }
    }

    private func makeStore(storage: NoteBodyStorage? = nil) -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false), bodyStorage: storage)
    }

    /// Sync apply of a noteit-doc body with `extras`, or of an RTFD body (which has none).
    private func apply(_ store: NoteStore, _ id: UUID, _ text: String, extras: ContainerExtras, rtfd: Bool = false) throws {
        try store.applyPreparedRemoteNote(prepare(store, id, text, extras: extras, rtfd: rtfd))
    }

    private func prepare(_ store: NoteStore, _ id: UUID, _ text: String, extras: ContainerExtras = .empty,
                         rtfd: Bool = true) throws -> NoteStore.PreparedRemoteNote {
        try NoteStore.prepareRemoteNote(S.notePayload(id, revision: UUID(), text: text), storage: store.bodyStorage,
                                        extras: rtfd ? .empty : extras, bodyIsRTFD: rtfd)
    }

    /// A note saved with `extras`, through the regular editor path.
    private func saveNote(_ store: NoteStore, _ text: NSAttributedString, extras: ContainerExtras) throws -> UUID {
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "placeholder")).id
        store.flush()
        store.setBodyExtras(extras, for: id)
        store.updateBody(id, text)
        store.flush()
        XCTAssertFalse(store.isBodyDirty(id))
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

    private func languages(_ store: NoteStore, _ id: UUID) throws -> [String?] {
        guard case .doc(let blocks) = try DocConverter.export(store.body(for: id), styles: AppDocStyleProvider.shared).doc
        else { return [] }
        return blocks.compactMap { if case .codeBlock(_, let language, _) = $0 { language } else { nil } }
    }

    private func hasLanguageID(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.noteItCodeLanguageID, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { found = true }
        }
        return found
    }

    private func rewriteOutside(_ store: NoteStore, _ id: UUID, _ text: NSAttributedString) throws {
        let url = store.bodyURL(for: id)
        try RTFDBodyStorage.installBody(RTFDBodyStorage.writeTempBody(text, in: url.deletingLastPathComponent()), at: url)
    }

    private func readSidecar(_ store: NoteStore, _ id: UUID) throws -> BodyExtrasSidecar {
        try BodyExtrasSidecar.decode(Data(contentsOf: store.bodyExtrasFileURL(id)))
    }

    private func leftoverTemps(_ store: NoteStore) throws -> [String] {
        let dirs = [store.notesURL, store.bodyExtrasDirectoryURL]
        return dirs.flatMap { (try? fm.contentsOfDirectory(atPath: $0.path)) ?? [] }.filter { $0.hasSuffix(".tmp") }
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
}

private extension NoteStore {
    func bodyExtras(loading id: UUID) -> ContainerExtras? {
        _ = body(for: id)
        return bodyExtras[id]
    }
}
