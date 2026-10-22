import AppKit
import Combine
import XCTest
import os
@testable import NoteIt
import NoteItCore
import NoteItMarkdown
import NoteItAPI

/// markdown-storage Task 4.2: changes made to the Markdown folder while NoteIt is open.
@MainActor
final class ExternalChangeTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }
    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-external-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func open() -> NoteStore {
        let store = NoteStore.opened(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                                        renameFilesOnTitleChange: false),
                              bodyStorage: MarkdownBodyStorageTests.make(root, renames: false))
        store.markdownClock = { Date().addingTimeInterval(10) }
        store.markdownFlushWait = 10
        store.waitForMarkdownWrites(upTo: 10)
        return store
    }

    private func put(_ path: String, _ text: String, modified: Date? = nil) throws {
        let url = content.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: content.appendingPathComponent(path), encoding: .utf8)
    }

    private func edit(_ path: String, _ old: String, _ new: String, modified: Date? = nil) throws {
        try put(path, read(path).replacingOccurrences(of: old, with: new), modified: modified)
    }

    private func note(_ store: NoteStore, titled title: String) throws -> NoteMeta {
        try XCTUnwrap(store.notes.first { $0.title == title }, "no note titled \(title)")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testAFolderThatStopsRespondingIsUnavailableNotEmptyAndNeverBlocksTheMainThread() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        let store = open()
        let kept = try note(store, titled: "Kept").id
        var reportedMissing = false
        store.onMarkdownFolderMissing = { _ in reportedMissing = true }
        store.markdownScanTimeout = 0.2
        store.markdownUnavailableRetryInterval = 0.2
        let realScan = store.markdownFolderScan
        let hung = DispatchSemaphore(value: 0)
        store.markdownFolderScan = { _, _, _ in
            _ = hung.wait(timeout: .now() + 3)
            var result = FolderScanResult()
            result.removed = [kept]
            return result
        }

        let started = Date()
        store.markdownFolderNeedsScan()
        try await waitUntil({ store.markdownFolderUnavailable }, "the hung folder is reported unavailable")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the main thread kept running while the scan hung")
        XCTAssertEqual(store.note(with: kept)?.deletedAt, nil)
        XCTAssertFalse(reportedMissing, "a folder that doesn't answer isn't a missing folder")

        store.markdownFolderScan = realScan
        hung.signal()
        try await waitUntil({ !store.markdownFolderUnavailable }, "the folder is available again once it answers")
        XCTAssertEqual(store.note(with: kept)?.deletedAt, nil, "the hung scan's late result is never applied")
        XCTAssertFalse(reportedMissing)
    }

    func testWritesToAFolderThatStopsRespondingWaitInsteadOfFreezing() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        let store = open()
        let kept = try note(store, titled: "Kept").id
        let storage = try XCTUnwrap(store.markdownStorage)
        storage.rootTimeout = 0.2
        store.markdownUnavailableRetryInterval = 0.2
        let hung = DispatchSemaphore(value: 0)
        let realCheck = storage.rootCheck
        storage.rootCheck = { url in
            _ = hung.wait(timeout: .now() + 3)
            return realCheck(url)
        }

        store.updateBody(kept, NSAttributedString(string: "Kept\n\nedited while away"))
        let started = Date()
        store.flush()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertFalse(try read("Kept.md").contains("edited while away"))
        try await waitUntil({ store.markdownFolderUnavailable }, "the hung folder is reported unavailable")

        storage.rootCheck = realCheck
        hung.signal()
        try await waitUntil({ !store.markdownFolderUnavailable }, "the folder is available again once it answers")
        store.flush()
        XCTAssertTrue(try read("Kept.md").contains("edited while away"), "the edit kept in memory is written once it answers")
    }

    func testAWriteThatHangsNeverHoldsUpTheMainThread() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        try put("Other.md", "# Other\n\nother text\n")
        let store = open()
        store.markdownFlushWait = 0
        store.markdownWriteTimeout = 0.3
        store.markdownBlockingTimeout = 0.3
        store.markdownUnavailableRetryInterval = 0.2
        let kept = try note(store, titled: "Kept").id
        let other = try note(store, titled: "Other").id
        let storage = try XCTUnwrap(store.markdownStorage)
        storage.rootTimeout = 30
        let hung = DispatchSemaphore(value: 0)
        let realCheck = storage.rootCheck
        storage.rootCheck = { url in
            _ = hung.wait(timeout: .now() + 4)
            return realCheck(url)
        }

        store.updateBody(kept, NSAttributedString(string: "Kept\n\nfirst edit"))
        var started = Date()
        store.flush()
        store.dropCachedBody(other)
        XCTAssertTrue(store.body(for: other).string.contains("other text"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "the main thread doesn't wait for the folder")
        XCTAssertTrue(store.isBodyDirty(kept))
        try await waitUntil({ store.markdownFolderUnavailable }, "a write that doesn't finish makes the folder unavailable")

        store.updateBody(kept, NSAttributedString(string: "Kept\n\nsecond edit"))
        started = Date()
        store.flush()
        store.flush()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        let recovery = { (try? self.fm.contentsOfDirectory(atPath: store.recoveryURL.path)) ?? [] }
        XCTAssertEqual(recovery().count, 1, "the waiting edit is kept in recovery/, once")

        storage.rootCheck = realCheck
        for _ in 0..<4 { hung.signal() }
        try await waitUntil({
            store.flush()
            return !store.isBodyDirty(kept)
        }, "the queued edit is written once the folder answers")
        XCTAssertTrue(try read("Kept.md").contains("second edit"))
        XCTAssertFalse(store.markdownFolderUnavailable)
        XCTAssertEqual(recovery(), [], "the waiting copy goes once the edit is written")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: content.path).filter { $0.hasSuffix(".md") }.sorted(),
                       ["Kept.md", "Other.md"], "NoteIt's own write isn't taken for an outside change")
    }

    func testALateWriteOfAnOlderEditKeepsTheWaitingCopyOfTheNewerOne() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        let store = open()
        store.markdownFlushWait = 0
        store.markdownWriteTimeout = 0.3
        store.markdownBlockingTimeout = 0.3
        store.markdownUnavailableRetryInterval = 600
        let kept = try note(store, titled: "Kept").id
        let storage = try XCTUnwrap(store.markdownStorage)
        storage.rootTimeout = 30
        let firstWrite = DispatchSemaphore(value: 0)
        let calls = Counter()
        let realCheck = storage.rootCheck
        storage.rootCheck = { url in
            if calls.increment() == 1 { _ = firstWrite.wait(timeout: .now() + 10) }
            return realCheck(url)
        }

        store.updateBody(kept, NSAttributedString(string: "Kept\n\nolder edit"))
        store.flush()
        try await waitUntil({ store.markdownFolderUnavailable }, "the hung write makes the folder unavailable")
        store.updateBody(kept, NSAttributedString(string: "Kept\n\nnewer edit"))
        store.flush()
        let recovery = { (try? self.fm.contentsOfDirectory(at: store.recoveryURL, includingPropertiesForKeys: nil)) ?? [] }
        XCTAssertEqual(recovery().filter { $0.pathExtension == "md" }.count, 1)

        firstWrite.signal()
        try await waitUntil({ store.markdownIOJobs.isEmpty }, "the late write of the older edit finishes")
        XCTAssertTrue(try read("Kept.md").contains("older edit"))
        XCTAssertTrue(store.isBodyDirty(kept), "the newer edit still waits")
        let copies = recovery().filter { $0.pathExtension == "md" }
        XCTAssertEqual(copies.count, 1, "the newer edit keeps its copy in recovery/")
        XCTAssertTrue(copies.contains { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("newer edit") })
    }

    func testARescanNeverWaitsForTheFolderOnTheMainThread() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        let store = open()
        store.markdownScanTimeout = 30
        let gate = DispatchSemaphore(value: 0)
        let realScan = store.markdownFolderScan
        store.markdownFolderScan = { root, index, ledger in
            _ = gate.wait(timeout: .now() + 5)
            return realScan(root, index, ledger)
        }
        let started = Date()
        let rescan = Task { await store.rescanMarkdownFolder() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the main thread runs while the scan waits")
        try edit("Kept.md", "first", "changed")
        gate.signal()
        let applied = await rescan.value
        XCTAssertTrue(applied)
        XCTAssertTrue(store.body(for: try note(store, titled: "Kept").id).string.contains("changed"))
    }

    func testTheWatcherStartsOnlyOnceTheFolderAnswers() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        let store = open()
        defer { store.stopWatchingMarkdownFolder() }
        store.markdownScanTimeout = 0.2
        store.markdownUnavailableRetryInterval = 0.2
        let realScan = store.markdownFolderScan
        let hung = DispatchSemaphore(value: 0)
        store.markdownFolderScan = { root, index, ledger in
            _ = hung.wait(timeout: .now() + 3)
            return realScan(root, index, ledger)
        }
        store.markdownFolderNeedsScan()
        try await waitUntil({ store.markdownFolderUnavailable }, "the hung folder is reported unavailable")

        let started = Date()
        store.startWatchingMarkdownFolder()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(store.markdownWatcher, "nothing touches a folder that doesn't answer")

        store.markdownFolderScan = realScan
        hung.signal()
        try await waitUntil({ !store.markdownFolderUnavailable }, "the folder is available again once it answers")
        try await waitUntil({ store.markdownWatcher != nil }, "the watcher starts after the first scan that succeeds")
    }

    func testWhatAScanFoundIsReadBeforeItReachesTheMainThread() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        let store = open()
        let kept = try note(store, titled: "Kept").id
        let storage = try XCTUnwrap(store.markdownStorage)
        storage.rootTimeout = 0.2
        let content = content
        let realCheck = storage.rootCheck
        let hung = DispatchSemaphore(value: 0)
        defer { hung.signal() }
        let checks = Counter()
        storage.rootCheck = { url in
            guard !Thread.isMainThread else {
                _ = hung.wait(timeout: .now() + 3)
                return realCheck(url)
            }
            if checks.increment() == 2 {
                for path in ["Kept.md", "New.md", "Folder/Inside.md"] {
                    try? Data("# Spoiled\n".utf8).write(to: content.appendingPathComponent(path))
                }
                try? Data(#"{"name":"Spoiled"}"#.utf8).write(to: content.appendingPathComponent("Folder/.noteit-notebook.json"))
            }
            return realCheck(url)
        }

        try edit("Kept.md", "first", "edited outside")
        try put("New.md", "# New\n\nadded\n")
        try put("Folder/Inside.md", "# Inside\n\nin a folder\n")
        store.markdownFolderNeedsScan()
        try await waitUntil({ store.note(with: kept)?.preview.contains("edited outside") == true },
                            "the edit is applied as the scan read it")
        XCTAssertNotNil(store.notes.first { $0.title == "New" })
        let folder = try XCTUnwrap(store.notebooks.first { $0.name == "Folder" })
        XCTAssertEqual(store.notes.first { $0.title == "Inside" }?.notebookID, folder.id)
        XCTAssertFalse(store.notes.contains { $0.title == "Spoiled" })
        XCTAssertFalse(store.markdownFolderUnavailable, "applying the scan touched nothing in the folder")
    }

    func testTheAttachmentsAScannedNoteShowsAreReadOffTheMainThread() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        let store = open()
        let storage = try XCTUnwrap(store.markdownStorage)
        let content = content
        let realCheck = storage.rootCheck
        let checks = Counter()
        storage.rootCheck = { url in
            if !Thread.isMainThread, checks.increment() == 2 {
                try? FileManager.default.removeItem(at: content.appendingPathComponent("_attachments/photo.png"))
            }
            return realCheck(url)
        }

        try put("_attachments/photo.png", "png bytes")
        try put("Pic.md", "# Pic\n\n![photo](_attachments/photo.png)\n")
        store.markdownFolderNeedsScan()
        try await waitUntil({ store.notes.contains { $0.title == "Pic" } }, "the new note is imported")
        let pic = try note(store, titled: "Pic").id
        let body = try XCTUnwrap(storage.lastKnownBody(pic))
        var attachments = 0
        body.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 1, "the picture was read by the scan, before it went away")
    }

    func testTheLibraryOpensAtOnceWhileItsFolderIsStillBeingScanned() throws {
        try put("Plan.md", "# Plan\n\nfirst\n")
        var store: NoteStore? = open()
        let plan = try note(store!, titled: "Plan").id
        store?.flush()
        store = nil
        try put("New.md", "# New\n\nadded while closed\n")
        let gate = DispatchGroup()
        gate.enter()
        var released = false
        defer { if !released { gate.leave() } }
        let storage = MarkdownBodyStorageTests.make(root, renames: false)
        storage.rootCheck = { url in
            _ = gate.wait(timeout: .now() + 10)
            return FileManager.default.fileExists(atPath: url.path)
        }

        let started = Date()
        let reopened = NoteStore(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                                           renameFilesOnTitleChange: false),
                                 bodyStorage: storage)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "opening never waits for the folder")
        XCTAssertTrue(reopened.markdownFolderChecking)
        XCTAssertTrue(reopened.markdownFolderUnavailable, "read-only until the folder answers")
        XCTAssertNotNil(reopened.note(with: plan), "the library opens from library.json")
        XCTAssertNil(reopened.notes.first { $0.title == "New" })

        gate.leave()
        released = true
        reopened.waitForLaunchScan(timeout: 10)
        XCTAssertFalse(reopened.markdownFolderChecking)
        XCTAssertFalse(reopened.markdownFolderUnavailable)
        let new = try note(reopened, titled: "New")
        reopened.waitForMarkdownWrites(upTo: 10)
        XCTAssertEqual(FolderScanner.frontMatterID(Data(try read("New.md").utf8)), new.id,
                       "a file added while NoteIt was closed takes its id at once")
        XCTAssertTrue(reopened.notesChangedBeforeDerivedIndexes.contains(new.id))
    }

    func testNothingIsBuiltOnAPlaceholderBodyWhileTheFolderIsStillBeingChecked() async throws {
        try put("Plan.md", "# Plan\n\nfirst line\nsecond line\n")
        var store: NoteStore? = open()
        let plan = try note(store!, titled: "Plan").id
        store?.flush()
        store = nil
        let original = try read("Plan.md")
        let gate = DispatchGroup()
        gate.enter()
        var released = false
        defer { if !released { gate.leave() } }
        let storage = MarkdownBodyStorageTests.make(root, renames: false)
        storage.rootCheck = { url in
            _ = gate.wait(timeout: .now() + 10)
            return FileManager.default.fileExists(atPath: url.path)
        }
        let reopened = NoteStore(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                                           renameFilesOnTitleChange: false),
                                 bodyStorage: storage)
        XCTAssertTrue(reopened.markdownFolderChecking)

        XCTAssertThrowsError(try reopened.editBody(plan, actionName: "Append") { $0.append(NSAttributedString(string: "\nadded")) }) {
            XCTAssertEqual($0 as? BodyEditError, .folderNotAvailable("content"))
        }
        reopened.updateBody(plan, NSAttributedString(string: "Plan\nreplaced"))
        XCTAssertFalse(reopened.isBodyDirty(plan))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "placeholder-\(UUID().uuidString)"))
        let service = AutomationService(store: reopened, defaults: defaults,
                                        staged: StagedUploads(directory: root.appendingPathComponent("staged")))
        do {
            _ = try await service.append(plan, text: "from the API", format: .text, position: .end, timestamp: false, ifRevision: nil)
            XCTFail("appended to a placeholder")
        } catch {
            XCTAssertEqual(error, .folderNotAvailable("content"))
            XCTAssertTrue(error.message.contains("“content”"), error.message)
            XCTAssertEqual(error.apiCode, .notReady)
        }
        XCTAssertThrowsError(try service.bodyString(of: plan, format: .text))

        gate.leave()
        released = true
        reopened.waitForLaunchScan(timeout: 10)
        reopened.flush()
        reopened.waitForMarkdownWrites(upTo: 10)
        XCTAssertEqual(try read("Plan.md"), original)
        try reopened.editBody(plan, actionName: "Append") { $0.append(NSAttributedString(string: "\nadded")) }
        reopened.flush()
        reopened.waitForMarkdownWrites(upTo: 10)
        XCTAssertTrue(try read("Plan.md").contains("second line"))
        XCTAssertTrue(try read("Plan.md").contains("added"))
    }

    func testEditsMadeWhileNoteItWasClosedReachSpotlightAtTheNextLaunch() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        try put("Gone.md", "# Gone\n\nsoon\n")
        try put("Untouched.md", "# Untouched\n\nsame\n")
        let suite = "noteit-external-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SpotlightIndexer.indexVersion, forKey: PrefKey.spotlightIndexVersion)
        var store: NoteStore? = open()
        let kept = try note(store!, titled: "Kept").id
        let gone = try note(store!, titled: "Gone").id
        store?.flush()
        store = nil

        try edit("Kept.md", "first", "edited while closed")
        try fm.removeItem(at: content.appendingPathComponent("Gone.md"))
        try put("Added.md", "# Added\n\nnew\n")
        let reopened = open()
        let added = try note(reopened, titled: "Added").id
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: reopened, defaults: defaults, index: fake, isSupported: true, flushDelay: 60)
        indexer.start()
        let deadline = Date().addingTimeInterval(5)
        while fake.items[added.uuidString] == nil || fake.items[kept.uuidString] == nil, Date() < deadline {
            indexer.flush()
            await indexer.settle()
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNotNil(fake.items[added.uuidString], "a file added while closed is indexed")
        XCTAssertTrue(fake.items[kept.uuidString]?.textContent?.contains("edited while closed") == true)
        XCTAssertTrue(fake.calls.contains(.delete([gone.uuidString])), "a file deleted while closed leaves Spotlight")
        XCTAssertFalse(fake.calls.contains(.deleteAll), "only what changed is indexed again, not the whole library")
        let untouched = try note(reopened, titled: "Untouched").id
        XCTAssertNil(fake.items[untouched.uuidString])
    }

    /// Reopens the library with its launch scan held until `release` is called.
    private func reopenWhileChecking() -> (store: NoteStore, release: () -> Void) {
        let gate = DispatchGroup()
        gate.enter()
        var released = false
        let storage = MarkdownBodyStorageTests.make(root, renames: false)
        storage.rootCheck = { url in
            _ = gate.wait(timeout: .now() + 10)
            return FileManager.default.fileExists(atPath: url.path)
        }
        let store = NoteStore(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                                        renameFilesOnTitleChange: false),
                              bodyStorage: storage)
        addTeardownBlock { if !released { gate.leave() } }
        return (store, {
            guard !released else { return }
            released = true
            gate.leave()
        })
    }

    private func settle(_ indexer: SpotlightIndexer, for seconds: TimeInterval = 5, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            indexer.flush()
            await indexer.settle()
            try await Task.sleep(nanoseconds: 5_000_000)
        } while !done() && Date() < deadline
    }

    func testASpotlightRebuildDueAtLaunchWaitsForTheFolderToAnswer() async throws {
        try put("Plan.md", "# Plan\n\nquarter goals\n")
        var store: NoteStore? = open()
        let plan = try note(store!, titled: "Plan").id
        store?.flush()
        store = nil
        let suite = "noteit-external-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PrefKey.spotlightIndexDirty)

        let (reopened, release) = reopenWhileChecking()
        XCTAssertTrue(reopened.markdownFolderChecking)
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: reopened, defaults: defaults, index: fake, isSupported: true, flushDelay: 60)
        indexer.start()
        try await settle(indexer, for: 0.3) { false }
        XCTAssertNil(fake.items[plan.uuidString], "nothing is indexed without text while the folder is checked")

        release()
        reopened.waitForLaunchScan(timeout: 10)
        try await settle(indexer) { fake.items[plan.uuidString] != nil && !defaults.bool(forKey: PrefKey.spotlightIndexDirty) }
        XCTAssertTrue(fake.items[plan.uuidString]?.textContent?.contains("quarter goals") == true)
        XCTAssertFalse(defaults.bool(forKey: PrefKey.spotlightIndexDirty), "the rebuild read every note, so the index is clean")
    }

    func testEditsMadeWhileClosedReachSpotlightWhenItStartsBeforeTheLaunchScanApplies() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        var store: NoteStore? = open()
        let kept = try note(store!, titled: "Kept").id
        store?.flush()
        store = nil
        try edit("Kept.md", "first", "edited while closed")
        let suite = "noteit-external-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SpotlightIndexer.indexVersion, forKey: PrefKey.spotlightIndexVersion)

        let (reopened, release) = reopenWhileChecking()
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: reopened, defaults: defaults, index: fake, isSupported: true, flushDelay: 60)
        indexer.start()
        release()
        reopened.waitForLaunchScan(timeout: 10)
        try await settle(indexer) { fake.items[kept.uuidString]?.textContent?.contains("edited while closed") == true }
        XCTAssertTrue(fake.items[kept.uuidString]?.textContent?.contains("edited while closed") == true)
        XCTAssertFalse(fake.calls.contains(.deleteAll))
    }

    func testANoteIndexedWithoutTextWhileTheFolderDidntAnswerGetsItsTextWhenItAnswers() async throws {
        try put("Plan.md", "# Plan\n\nquarter goals\n")
        let store = open()
        let plan = try note(store, titled: "Plan").id
        let suite = "noteit-external-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SpotlightIndexer.indexVersion, forKey: PrefKey.spotlightIndexVersion)
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: store, defaults: defaults, index: fake, isSupported: true, flushDelay: 60)
        indexer.start()
        store.dropCachedBody(plan)
        store.markdownFolderBecameUnavailable()
        indexer.noteChanged(try XCTUnwrap(store.note(with: plan)), body: NSAttributedString())
        try await settle(indexer) { fake.items[plan.uuidString] != nil }
        XCTAssertNotNil(fake.items[plan.uuidString])
        XCTAssertFalse(fake.items[plan.uuidString]?.textContent?.contains("quarter goals") == true)

        store.rescanNow()
        try await settle(indexer) { fake.items[plan.uuidString]?.textContent?.contains("quarter goals") == true }
        XCTAssertTrue(fake.items[plan.uuidString]?.textContent?.contains("quarter goals") == true)
    }

    func testOpeningANoteWhoseFileIsSlowToReadDoesntWaitAndFillsInWhenTheReadEnds() async throws {
        try put("Slow.md", "# Slow\n\nfar away text\n")
        let store = open()
        let slow = try note(store, titled: "Slow").id
        let storage = try XCTUnwrap(store.markdownStorage)
        store.dropCachedBody(slow)
        let gate = DispatchGroup()
        gate.enter()
        var released = false
        defer { if !released { gate.leave() } }
        storage.readFileData = { url in
            _ = gate.wait(timeout: .now() + 3)
            return try Data(contentsOf: url)
        }
        store.selectedNoteID = slow
        store.externallyUpdatedNoteID = nil

        let started = Date()
        _ = store.body(for: slow)
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 1.3, "the main thread waits at most about a second")
        try await waitUntil({ store.isMarkdownBodyLoading(slow) }, "the note shows as loading")
        XCTAssertFalse(store.markdownFolderUnavailable, "a slow read isn't a folder that doesn't answer")
        XCTAssertNil(store.cachedBody(slow))

        released = true
        gate.leave()
        try await waitUntil({ store.cachedBody(slow) != nil }, "the read that ended is kept")
        XCTAssertTrue(store.body(for: slow).string.contains("far away text"))
        XCTAssertEqual(store.externallyUpdatedNoteID, slow, "the editor is told to show it")
        XCTAssertFalse(store.isMarkdownBodyLoading(slow))
        XCTAssertFalse(store.markdownFolderUnavailable)
    }

    func testReadingManyNotesOnAHungFolderWaitsOnceAndHoldsAtMostTwoReaders() async throws {
        for index in 0..<20 { try put("Far \(index).md", "# Far \(index)\n\nfar text \(index)\n") }
        let store = open()
        let ids = store.notes.map(\.id)
        XCTAssertEqual(ids.count, 20)
        let storage = try XCTUnwrap(store.markdownStorage)
        for id in ids { store.dropCachedBody(id) }
        let gate = DispatchGroup()
        gate.enter()
        var released = false
        defer { if !released { gate.leave() } }
        let lock = NSLock()
        var readers = 0
        storage.readFileData = { url in
            lock.withLock { readers += 1 }
            _ = gate.wait(timeout: .now() + 10)
            return try Data(contentsOf: url)
        }

        let started = Date()
        for id in ids { _ = store.plainText(for: id) }
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 1.5, "one wait, not one per note")
        XCTAssertLessThanOrEqual(lock.withLock { readers }, 2)

        released = true
        gate.leave()
        storage.readFileData = { try Data(contentsOf: $0) }
        try await waitUntil({ !store.isMarkdownBodyLoading(ids[0]) && store.cachedBody(ids[0]) != nil }, "the first read ends")
        for id in ids { XCTAssertTrue(store.plainText(for: id).contains("far text"), "read once the folder answers") }
    }

    func testReadsPastTheWholeTimeoutMarkTheFolderUnavailableWithoutYielding() throws {
        for index in 0..<3 { try put("Far \(index).md", "# Far \(index)\n\nfar text \(index)\n") }
        let store = open()
        store.markdownBlockingTimeout = 0.5
        store.markdownBodyMainWait = 0.1
        let ids = store.notes.map(\.id)
        let storage = try XCTUnwrap(store.markdownStorage)
        for id in ids { store.dropCachedBody(id) }
        let gate = DispatchGroup()
        gate.enter()
        defer { gate.leave() }
        storage.readFileData = { url in
            _ = gate.wait(timeout: .now() + 5)
            return try Data(contentsOf: url)
        }

        _ = store.plainText(for: ids[0])
        Thread.sleep(forTimeInterval: 0.7)
        _ = store.plainText(for: ids[1])
        XCTAssertTrue(store.markdownFolderUnavailable, "seen on the next call, not only after the main thread yields")
    }

    func testSearchingManyNotesOnAHungFolderReturnsPromptly() async throws {
        for index in 0..<40 { try put("Plan \(index).md", "# Plan \(index)\n\nplan text \(index)\n") }
        let store = open()
        let storage = try XCTUnwrap(store.markdownStorage)
        for meta in store.notes { store.dropCachedBody(meta.id) }
        let gate = DispatchGroup()
        gate.enter()
        defer { gate.leave() }
        storage.readFileData = { url in
            _ = gate.wait(timeout: .now() + 10)
            return try Data(contentsOf: url)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "hung-search-\(UUID().uuidString)"))
        let service = AutomationService(store: store, defaults: defaults,
                                        staged: StagedUploads(directory: root.appendingPathComponent("staged")))

        let started = Date()
        let hits = try service.search("Plan", notebook: nil, tag: nil, limit: 500)
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(hits.count, 40)
    }

    func testANoteWaitingForAnotherReadIsReadWhenThatReadWasTakenOnTheMainThread() async throws {
        let (store, ids, allGates) = try openWithGatedReads(["Ahead", "Waiting"], gated: ["Ahead"])
        var gates = allGates
        defer { gates.values.forEach { $0.leave() } }
        let (ahead, waiting) = (ids["Ahead"]!, ids["Waiting"]!)
        _ = store.body(for: ahead)
        store.selectedNoteID = waiting
        _ = store.body(for: waiting)
        try await waitUntil({ store.isMarkdownBodyLoading(waiting) }, "waits for the other read")

        gates.removeValue(forKey: "Ahead")?.leave()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(store.body(for: ahead).string.contains("Ahead text"), "taken before its end reaches the main thread")
        store.externallyUpdatedNoteID = nil
        try await waitUntil({ store.cachedBody(waiting) != nil }, "the waiting note is read")
        XCTAssertEqual(store.externallyUpdatedNoteID, waiting)
        XCTAssertFalse(store.isMarkdownBodyLoading(waiting))
    }

    func testANoteWaitingForAnotherReadSurvivesAnEndedReadWhileAThirdRuns() async throws {
        let (store, ids, allGates) = try openWithGatedReads(["Ahead", "Waiting", "Third"], gated: ["Ahead", "Third"])
        var gates = allGates
        defer { gates.values.forEach { $0.leave() } }
        let (ahead, waiting, third) = (ids["Ahead"]!, ids["Waiting"]!, ids["Third"]!)
        _ = store.body(for: ahead)
        store.selectedNoteID = waiting
        _ = store.body(for: waiting)
        try await waitUntil({ store.isMarkdownBodyLoading(waiting) }, "waits for the other read")

        gates.removeValue(forKey: "Ahead")?.leave()
        Thread.sleep(forTimeInterval: 0.3)
        _ = store.body(for: ahead)
        _ = store.body(for: third)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(store.isMarkdownBodyLoading(waiting), "still waiting while the third read runs")
        XCTAssertTrue(store.isMarkdownBodyUnread(waiting))

        gates.removeValue(forKey: "Third")?.leave()
        try await waitUntil({ store.cachedBody(waiting) != nil }, "the waiting note is read once the third read ends")
        XCTAssertTrue(store.body(for: waiting).string.contains("Waiting text"))
        XCTAssertFalse(store.isMarkdownBodyLoading(waiting))
    }

    /// Notes titled `titles` with no cached bodies; reads of the `gated` ones wait for their gate to be left.
    private func openWithGatedReads(_ titles: [String], gated: Set<String>)
        throws -> (NoteStore, [String: UUID], [String: DispatchGroup]) {
        for title in titles { try put("\(title).md", "# \(title)\n\n\(title) text\n") }
        let store = open()
        store.markdownBodyMainWait = 0.1
        let storage = try XCTUnwrap(store.markdownStorage)
        var ids: [String: UUID] = [:]
        for title in titles { ids[title] = try note(store, titled: title).id }
        for id in ids.values { store.dropCachedBody(id) }
        var gates: [String: DispatchGroup] = [:]
        for title in gated {
            let gate = DispatchGroup()
            gate.enter()
            gates[title] = gate
        }
        let byFile = Dictionary(uniqueKeysWithValues: gates.map { ("\($0.key).md", $0.value) })
        storage.readFileData = { url in
            _ = byFile[url.lastPathComponent]?.wait(timeout: .now() + 4)
            return try Data(contentsOf: url)
        }
        return (store, ids, gates)
    }

    func testExportingNotesWhoseFilesWerentReadSkipsAndListsThem() throws {
        let (store, ids, gates) = try openWithGatedReads(["Here", "Far"], gated: ["Far"])
        defer { gates.values.forEach { $0.leave() } }
        XCTAssertNotNil(store.bodyForOutput(ids["Here"]!))
        XCTAssertNil(store.bodyForOutput(ids["Far"]!), "a placeholder is never output")
        let folder = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = try NoteExporter.exportAll(notebooks: store.sortedNotebooks, notes: store.notes, format: .markdown,
                                                to: folder, body: store.bodyForOutput)
        XCTAssertEqual(result.noteCount, 1)
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertEqual(result.skipped, ["Far"])
        let written = FileManager.default.enumerator(at: result.folder, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.hasSuffix(".md") } ?? []
        XCTAssertEqual(written, ["Here.md"])
    }

    func testAnExportWaitsForASlowReadInsteadOfSkippingTheNotesAfterIt() async throws {
        let (store, storage) = try openWithUncachedNotes(20)
        let lock = NSLock()
        var first = true
        storage.readFileData = { url in
            if lock.withLock({ defer { first = false }; return first }) { Thread.sleep(forTimeInterval: 2) }
            return try Data(contentsOf: url)
        }
        let export = try NoteExporter.prepareAll(notebooks: store.sortedNotebooks, notes: store.notes, format: .markdown,
                                                 to: exportFolder(), body: store.bodyForOutput)
        export.bodyWhenRead = { await store.bodyForOutputWhenRead($0, isCancelled: $1) }
        let result = try await export.write { _ in true }
        XCTAssertEqual(result.noteCount, 20)
        XCTAssertEqual(result.skipped, [])
    }

    func testAnExportOnASlowFolderNeverBlocksTheMainThreadWhileReading() async throws {
        let (store, storage) = try openWithUncachedNotes(5)
        storage.readFileData = { url in
            Thread.sleep(forTimeInterval: 1.2)
            return try Data(contentsOf: url)
        }
        let export = try NoteExporter.prepareAll(notebooks: store.sortedNotebooks, notes: store.notes, format: .markdown,
                                                 to: exportFolder(), body: store.bodyForOutput)
        export.bodyWhenRead = { await store.bodyForOutputWhenRead($0, isCancelled: $1) }
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        let result = try await export.write { _ in true }
        heartbeat.stop()
        XCTAssertEqual(result.noteCount, 5)
        XCTAssertLessThan(heartbeat.longestGap, 0.3, "the main thread was blocked while a note was read")
    }

    func testCancellingAnExportDoesntWaitForASlowRead() async throws {
        let (store, storage) = try openWithUncachedNotes(3)
        storage.readFileData = { url in
            Thread.sleep(forTimeInterval: 3)
            return try Data(contentsOf: url)
        }
        let export = try NoteExporter.prepareAll(notebooks: store.sortedNotebooks, notes: store.notes, format: .markdown,
                                                 to: exportFolder(), body: store.bodyForOutput)
        export.bodyWhenRead = { await store.bodyForOutputWhenRead($0, isCancelled: $1) }
        let started = Date()
        export.isCancelled = { Date().timeIntervalSince(started) > 0.3 }
        let result = try await export.write { _ in true }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(result.noteCount, 0)
        XCTAssertEqual(result.skipped, [], "a cancelled export lists nothing as skipped")
    }

    func testAnExportOnAHungFolderSkipsAndListsTheNotesPromptly() async throws {
        let (store, storage) = try openWithUncachedNotes(20)
        store.markdownBlockingTimeout = 1
        store.markdownUnavailableRetryInterval = 600
        let gate = DispatchGroup()
        gate.enter()
        defer { gate.leave() }
        storage.readFileData = { url in
            _ = gate.wait(timeout: .now() + 20)
            return try Data(contentsOf: url)
        }
        let export = try NoteExporter.prepareAll(notebooks: store.sortedNotebooks, notes: store.notes, format: .markdown,
                                                 to: exportFolder(), body: store.bodyForOutput)
        export.bodyWhenRead = { await store.bodyForOutputWhenRead($0, isCancelled: $1) }
        let started = Date()
        let result = try await export.write { _ in true }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(result.noteCount, 0)
        XCTAssertEqual(result.skipped.count, 20)
    }

    private func openWithUncachedNotes(_ count: Int) throws -> (NoteStore, MarkdownBodyStorage) {
        for index in 0..<count { try put("Note \(index).md", "# Note \(index)\n\ntext \(index)\n") }
        let store = open()
        let storage = try XCTUnwrap(store.markdownStorage)
        for meta in store.notes { store.dropCachedBody(meta.id) }
        return (store, storage)
    }

    private func exportFolder() throws -> URL {
        let folder = root.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testANoteFromATemplateThatWasntReadIsntCreated() throws {
        let (store, template, _) = try openWithUnreadTemplate()
        let count = store.notes.count
        XCTAssertThrowsError(try store.createNote(fromTemplate: template, title: "Trip", in: nil)) {
            XCTAssertEqual($0 as? BodyEditError, .folderNotAvailable("content"))
        }
        XCTAssertThrowsError(try store.createNoteFromTemplateInCurrentContext(template, title: "Trip"))
        XCTAssertThrowsError(try store.expandedTemplate(template, title: "Here", date: Date()), "Insert Template inserts nothing")
        XCTAssertEqual(store.notes.count, count)
    }

    func testANewNoteInANotebookWhoseTemplateWasntReadIsntCreated() throws {
        let (store, template, _) = try openWithUnreadTemplate()
        var notebook = store.createNotebook(name: "Trips", symbol: "folder", colorHex: NotebookPalette.colors[0])
        notebook.defaultTemplateID = template
        store.updateNotebook(notebook)
        store.selection = .notebook(notebook.id)
        var told: [String] = []
        store.onTemplateNotRead = { told.append($0) }
        let source = store.createNote(in: notebook.id).id
        let count = store.notes.count

        XCTAssertNil(store.createNoteInCurrentContext())
        XCTAssertNil(store.createNoteForLink(title: "Paris", from: source))
        XCTAssertEqual(store.notes.count, count)
        XCTAssertEqual(told.count, 2)
        XCTAssertTrue(told.first?.contains("“content”") == true, told.first ?? "")

        let captured = store.captureNote(title: "Idea", body: "keep this", in: notebook.id)
        XCTAssertTrue(store.body(for: try XCTUnwrap(captured).id).string.contains("keep this"), "a capture is never lost")
    }

    func testADailyNoteWhoseTemplateWasntReadIsntCreated() async throws {
        let (store, template, defaults) = try openWithUnreadTemplate()
        defaults.set(template.uuidString, forKey: PrefKey.dailyNoteTemplateID)
        var told: [String] = []
        store.onTemplateNotRead = { told.append($0) }
        let count = store.notes.count
        XCTAssertThrowsError(try store.dailyNote(for: Date(), createIfMissing: true)) {
            XCTAssertEqual($0 as? BodyEditError, .folderNotAvailable("content"))
        }
        store.openDailyNote(for: Date())
        XCTAssertEqual(told.count, 1)
        let service = AutomationService(store: store, defaults: defaults,
                                        staged: StagedUploads(directory: root.appendingPathComponent("staged")),
                                        dailyNotesAvailable: { true })
        XCTAssertThrowsError(try service.daily(date: Date(), create: true)) {
            XCTAssertEqual($0 as? AutomationError, .folderNotAvailable("content"))
        }
        XCTAssertThrowsError(try service.appendToDaily(text: "note", format: .plain, timestamp: false, date: Date())) {
            XCTAssertEqual($0 as? AutomationError, .folderNotAvailable("content"))
        }
        XCTAssertEqual(store.notes.count, count)
    }

    func testTheAPIDoesntCreateANoteFromATemplateThatWasntRead() throws {
        let (store, template, _) = try openWithUnreadTemplate()
        let count = store.notes.count
        let spec = try XCTUnwrap(LinkingAPIRoutes.routes.first { $0.id == "linking.createFromTemplate" })
        let request = HTTPRequest(method: spec.method.rawValue, path: spec.pattern, body: Data(#"{"title":"Trip"}"#.utf8))
        let context = LocalAPIContext(request: request, route: RouteMatch(spec: spec, params: ["id": template.uuidString]),
                                      client: nil, origin: .native)
        let response = LinkingAPIRoutes.respond("linking.createFromTemplate", context, store: store)
        XCTAssertEqual((try? APIJSON.decoder().decode(APIErrorBody.self, from: response.body))?.error.code, .notReady)
        XCTAssertEqual(store.notes.count, count)
    }

    func testAnOpenNoteWhoseSlowReadFailsIsntReadAgainAndAgain() async throws {
        try put("Plan.md", "# Plan\n\nPlan text\n")
        let store = open()
        let storage = try XCTUnwrap(store.markdownStorage)
        let plan = try note(store, titled: "Plan").id
        store.dropCachedBody(plan)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        storage.readFileData = { url in
            guard url.lastPathComponent == "Plan.md" else { return try Data(contentsOf: url) }
            reads.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 1.5)
            throw POSIXError(.ETIMEDOUT)
        }
        store.selectedNoteID = plan
        // What an open editor does when told the note changed (`reloadIfStale`).
        var shown = NSAttributedString()
        let reload = store.$externallyUpdatedNoteID.sink { id in
            if id == plan { DispatchQueue.main.async { shown = store.body(for: plan) } }
        }
        defer { reload.cancel() }
        shown = store.body(for: plan)
        XCTAssertEqual(shown.string, "Plan\nPlan text", "shown as last known while it's read")
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        try await Task.sleep(for: .seconds(6))
        heartbeat.stop()
        XCTAssertEqual(reads.withLock { $0 }, 1, "a failed read is retried only on a change, Retry or after a long pause")
        XCTAssertNotNil(store.loadError(for: plan))
        XCTAssertLessThan(heartbeat.longestGap, 0.5)
        XCTAssertEqual(shown.string, "", "the editor no longer shows the last known text as the note")
        XCTAssertTrue(store.isBodyWriteBlocked(plan), "and stays read-only")

        reads.withLock { $0 = 0 }
        storage.readFileData = { url in try Data(contentsOf: url) }
        store.retryReadingBody(plan)
        try await waitUntil({ store.cachedBody(plan) != nil }, "Retry reads the note")
        XCTAssertEqual(store.body(for: plan).string, "Plan\nPlan text")
        XCTAssertNil(store.loadError(for: plan))
    }

    /// An open editor showing Plan's last known text while a slow read runs; `finish` lets the read end with
    /// `result`, and another caller (an export, the API, sync) takes the ended read before its own end is handled.
    private func openEditorOverASlowReadTakenByAnotherCaller(_ result: @escaping () throws -> Data)
        throws -> (store: NoteStore, plan: UUID, editor: EditorHarness.Editor, harness: EditorHarness, finish: () -> Void) {
        try put("Plan.md", "# Plan\n\nPlan text\n")
        let store = open()
        let storage = try XCTUnwrap(store.markdownStorage)
        let plan = try note(store, titled: "Plan").id
        store.dropCachedBody(plan)
        let gate = DispatchSemaphore(value: 0)
        storage.readFileData = { url in
            guard url.lastPathComponent == "Plan.md" else { return try Data(contentsOf: url) }
            gate.wait()
            return try result()
        }
        store.selectedNoteID = plan
        let harness = EditorHarness()
        let editor = harness.open(store, plan)
        XCTAssertEqual(editor.view.string, "Plan\nPlan text", "the last known text while it's read")
        XCTAssertNil(store.cachedBody(plan))
        return (store, plan, editor, harness, {
            gate.signal()
            Thread.sleep(forTimeInterval: 0.3)
            _ = store.body(for: plan, wait: 0)
        })
    }

    func testAnEditorReloadsWhenAnotherCallerTakesTheReadItWaitsFor() async throws {
        let (store, plan, editor, harness, finish) = try openEditorOverASlowReadTakenByAnotherCaller {
            Data("# Plan\n\nNew text\n".utf8)
        }
        defer { harness.close() }
        finish()
        XCTAssertEqual(store.cachedBody(plan)?.string, "Plan\nNew text")
        try await waitUntil({ editor.view.string == "Plan\nNew text" }, "the editor shows the text that was read")
    }

    func testAnEditorDropsTheLastKnownTextWhenAnotherCallerTakesTheFailedReadItWaitsFor() async throws {
        let (store, plan, editor, harness, finish) = try openEditorOverASlowReadTakenByAnotherCaller {
            throw POSIXError(.EIO)
        }
        defer { harness.close() }
        finish()
        XCTAssertNotNil(store.loadError(for: plan))
        try await waitUntil({ editor.view.string == "" }, "the editor no longer shows the last known text as the note")
        XCTAssertTrue(store.isBodyWriteBlocked(plan))
    }

    func testANoteWhoseFileFailedToReadIsNeverOutputAsEmpty() async throws {
        let (store, ids, failing) = try openWithFailingRead(["Plan", "Other"], failing: "Plan")
        let plan = try XCTUnwrap(ids["Plan"])
        XCTAssertEqual(store.body(for: plan).string, "")
        XCTAssertNotNil(store.loadError(for: plan))
        XCTAssertTrue(store.isBodyWriteBlocked(plan), "the editor stays read-only")
        XCTAssertNil(store.bodyForOutput(plan))

        let export = try NoteExporter.prepareAll(notebooks: store.sortedNotebooks, notes: store.notes, format: .markdown,
                                                 to: exportFolder(), body: store.bodyForOutput)
        let folder = export.folder
        let result = try export.writeAll()
        XCTAssertEqual(result.skipped, ["Plan"])
        XCTAssertEqual(result.noteCount, 1)
        let async = try NoteExporter.prepareAll(notebooks: store.sortedNotebooks, notes: store.notes, format: .markdown,
                                                to: exportFolder(), body: store.bodyForOutput)
        async.bodyWhenRead = { await store.bodyForOutputWhenRead($0, isCancelled: $1) }
        let asyncResult = try await async.write { _ in true }
        XCTAssertEqual(asyncResult.skipped, ["Plan"])
        let written = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
        XCTAssertFalse(written.contains { $0.hasSuffix("Plan.md") }, "\(written)")

        let service = AutomationService(store: store, defaults: UserDefaults(suiteName: "failed-read-\(UUID().uuidString)")!,
                                        staged: StagedUploads(directory: root.appendingPathComponent("staged")),
                                        dailyNotesAvailable: { true })
        XCTAssertThrowsError(try service.bodyString(of: plan, format: .markdown)) {
            XCTAssertEqual($0 as? AutomationError, .noteUnreadable)
        }
        let spec = try XCTUnwrap(LinkingAPIRoutes.routes.first { $0.id == "linking.outline" })
        let context = LocalAPIContext(request: HTTPRequest(method: spec.method.rawValue, path: spec.pattern, body: Data()),
                                      route: RouteMatch(spec: spec, params: ["id": plan.uuidString]), client: nil, origin: .native)
        let response = LinkingAPIRoutes.respond("linking.outline", context, store: store)
        XCTAssertEqual((try? APIJSON.decoder().decode(APIErrorBody.self, from: response.body))?.error.code, .noteUnreadable)

        failing.withLock { $0 = false }
        XCTAssertEqual(store.body(for: plan).string, "", "not read again right away")
        store.retryReadingBody(plan)
        try await waitUntil({ _ = store.body(for: plan); return store.cachedBody(plan) != nil }, "a later read is made")
        XCTAssertEqual(store.body(for: plan).string, "Plan\nPlan text", "a later read that succeeds is used")
        XCTAssertNil(store.loadError(for: plan))
        XCTAssertFalse(store.isBodyWriteBlocked(plan))
        XCTAssertNotNil(store.bodyForOutput(plan))
    }

    func testATemplateWhoseFileFailedToReadCreatesNothing() throws {
        let (store, ids, _) = try openWithFailingRead(["Plan"], failing: "Plan")
        let template = try XCTUnwrap(ids["Plan"])
        store.moveNote(template, to: store.templatesNotebookID(createIfMissing: true))
        store.flush()
        store.dropCachedBody(template)
        XCTAssertTrue(store.isTemplate(template))
        var told: [String] = []
        store.onTemplateNotRead = { told.append($0) }
        let count = store.notes.count
        XCTAssertThrowsError(try store.createNote(fromTemplate: template, title: "Trip", in: nil))
        XCTAssertThrowsError(try store.expandedTemplate(template, title: "Here", date: Date()))
        var notebook = store.createNotebook(name: "Trips", symbol: "folder", colorHex: NotebookPalette.colors[0])
        notebook.defaultTemplateID = template
        store.updateNotebook(notebook)
        store.selection = .notebook(notebook.id)
        XCTAssertNil(store.createNoteInCurrentContext())
        XCTAssertEqual(store.notes.count, count)
        XCTAssertEqual(told.count, 1)
        XCTAssertTrue(told.first?.contains("couldn’t be read") == true, told.first ?? "")
    }

    /// Markdown notes whose files are read again (uncached); reading `failing` throws EIO while the flag is set.
    private func openWithFailingRead(_ titles: [String], failing title: String)
        throws -> (NoteStore, [String: UUID], OSAllocatedUnfairLock<Bool>) {
        for title in titles { try put("\(title).md", "# \(title)\n\n\(title) text\n") }
        let store = open()
        store.preferences = try XCTUnwrap(UserDefaults(suiteName: "failing-read-\(UUID().uuidString)"))
        let storage = try XCTUnwrap(store.markdownStorage)
        var ids: [String: UUID] = [:]
        for title in titles { ids[title] = try note(store, titled: title).id }
        for id in ids.values { store.dropCachedBody(id) }
        let failing = OSAllocatedUnfairLock(initialState: true)
        storage.readFileData = { url in
            if url.lastPathComponent == "\(title).md", failing.withLock({ $0 }) { throw POSIXError(.EIO) }
            return try Data(contentsOf: url)
        }
        return (store, ids, failing)
    }

    /// A Markdown library in its launch "checking" window, with a template whose body isn't cached.
    private func openWithUnreadTemplate() throws -> (NoteStore, UUID, UserDefaults) {
        let store = open()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "unread-template-\(UUID().uuidString)"))
        store.preferences = defaults
        let template = store.createTemplate().id
        store.updateBody(template, NSAttributedString(string: "Plan\nGoals: {{cursor}}", attributes: EditorStyle.bodyAttributes))
        store.flush()
        store.dropCachedBody(template)
        store.markdownFolderUnavailable = true
        XCTAssertNil(store.cachedBody(template))
        return (store, template, defaults)
    }

    func testTheAPIRefusesAttachmentsOfANoteWhoseFileWasntRead() throws {
        let (store, ids, gates) = try openWithGatedReads(["Far"], gated: ["Far"])
        defer { gates.values.forEach { $0.leave() } }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "unread-output-\(UUID().uuidString)"))
        let service = AutomationService(store: store, defaults: defaults,
                                        staged: StagedUploads(directory: root.appendingPathComponent("staged")))
        XCTAssertThrowsError(try service.attachments(of: ids["Far"]!)) {
            XCTAssertEqual($0 as? AutomationError, .folderNotAvailable("content"))
        }
    }

    func testReadsStuckOnBothReadersKeepTheFolderUnavailableAndTheNoteReadOnly() async throws {
        try await readsStuckOnBothReaders(hanging: ["Hang A", "Hang B"])
    }

    func testOneFileThatHangsWhileTheScanAnswersKeepsTheFolderUnavailableAndTheNoteReadOnly() async throws {
        try await readsStuckOnBothReaders(hanging: ["Hang A", "Hang A"])
    }

    /// Each name in `hanging` is read once (its read outlives the whole timeout) and followed by a scan that answers,
    /// which leaves both readers held by reads that timed out.
    private func readsStuckOnBothReaders(hanging: [String]) async throws {
        for title in Array(Set(hanging)) + ["Fine"] { try put("\(title).md", "# \(title)\n\n\(title) text\n") }
        let store = open()
        store.markdownBlockingTimeout = 0.3
        store.markdownBodyMainWait = 0.05
        store.markdownUnavailableRetryInterval = 600
        let storage = try XCTUnwrap(store.markdownStorage)
        for meta in store.notes { store.dropCachedBody(meta.id) }
        let gate = DispatchGroup()
        gate.enter()
        var released = false
        defer { if !released { gate.leave() } }
        let hangingFiles = Set(hanging.map { "\($0).md" })
        storage.readFileData = { url in
            if hangingFiles.contains(url.lastPathComponent) { _ = gate.wait(timeout: .now() + 20) }
            return try Data(contentsOf: url)
        }
        for title in hanging {
            let id = try note(store, titled: title).id
            XCTAssertNil(store.cachedBody(id))
            _ = store.body(for: id)
            try await waitUntil({ store.markdownFolderUnavailable }, "a read past the timeout")
            let answered = await store.rescanMarkdownFolder()
            XCTAssertTrue(answered)
            XCTAssertFalse(store.markdownFolderUnavailable, "the scan answers")
        }

        let fine = try note(store, titled: "Fine").id
        store.selectedNoteID = fine
        _ = store.body(for: fine)
        XCTAssertNil(store.cachedBody(fine))
        XCTAssertTrue(store.markdownFolderUnavailable, "no reader left: the folder isn't answering")
        XCTAssertTrue(store.isMarkdownBodyUnread(fine), "the editor stays read-only over the placeholder")

        released = true
        gate.leave()
        storage.readFileData = { try Data(contentsOf: $0) }
        try await Task.sleep(nanoseconds: 300_000_000)
        store.externallyUpdatedNoteID = nil
        let answered = await store.rescanMarkdownFolder()
        XCTAssertTrue(answered)
        XCTAssertEqual(store.externallyUpdatedNoteID, fine, "the open note is read again")
        XCTAssertTrue(store.body(for: fine).string.contains("Fine text"))
        XCTAssertFalse(store.isMarkdownBodyUnread(fine))
    }

    func testASpotlightRebuildNeverWaitsOnTheMainThreadForAMarkdownFolder() async throws {
        for index in 0..<3 { try put("Note \(index).md", "# Note \(index)\n\ntext \(index)\n") }
        let store = open()
        store.markdownBlockingTimeout = 3
        store.markdownScanTimeout = 30
        let storage = try XCTUnwrap(store.markdownStorage)
        for meta in store.notes { store.dropCachedBody(meta.id) }
        let gate = DispatchSemaphore(value: 0)
        storage.readFileData = { url in
            _ = gate.wait(timeout: .now() + 2)
            return try Data(contentsOf: url)
        }
        let suite = "noteit-external-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: store, defaults: defaults, index: fake, isSupported: true, flushDelay: 60)

        indexer.rebuildNow()
        let started = Date()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the main thread runs while note files are read")
        for _ in 0..<3 { gate.signal() }
        storage.readFileData = { try Data(contentsOf: $0) }
        let deadline = Date().addingTimeInterval(10)
        while fake.items.count < 3, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        await indexer.settle()
        XCTAssertEqual(fake.items.values.filter { $0.textContent?.contains("text") == true }.count, 3)
    }

    func testAnAttachmentNoNoteRefersToGoesToTheTrashADayLaterWithoutAnyCallFromTheTest() async throws {
        try put("_attachments/photo.png", "png bytes")
        try put("_attachments/kept.png", "kept bytes")
        try put("Photo.md", "# Photo\n\n![photo](_attachments/photo.png)\n")
        try put("Kept.md", "# Kept\n\n![kept](_attachments/kept.png)\n")
        let store = open()
        try await waitForSweeps(store)
        let attachments = try XCTUnwrap(store.markdownStorage?.attachments)
        var clock = Date()
        let trashed = LockedNames()
        attachments.now = { clock }
        attachments.trash = { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }

        try edit("Photo.md", "![photo](_attachments/photo.png)", "no picture now")
        _ = await store.rescanMarkdownFolder()
        try await waitForSweeps(store)
        XCTAssertEqual(trashed.names, [])

        clock.addTimeInterval(AttachmentStore.graceInterval + 1)
        _ = store.createNote(in: nil, initial: NSAttributedString(string: "Other\nwritten a day later"))
        store.flush()
        try await waitForSweeps(store)
        XCTAssertEqual(trashed.names, ["photo.png"])
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent("_attachments/kept.png").path))
    }

    func testTheDayAnAttachmentWaitsForTheTrashSpansRelaunches() async throws {
        try put("_attachments/photo.png", "png bytes")
        try put("Photo.md", "# Photo\n\n![photo](_attachments/photo.png)\n")
        var store = open()
        try await waitForSweeps(store)
        try edit("Photo.md", "![photo](_attachments/photo.png)", "no picture now")
        _ = await store.rescanMarkdownFolder()
        try await waitForSweeps(store)
        store.stopWatchingMarkdownFolder()

        store = open()
        let attachments = try XCTUnwrap(store.markdownStorage?.attachments)
        try await waitForSweeps(store)
        let trashed = LockedNames()
        attachments.now = { Date().addingTimeInterval(AttachmentStore.graceInterval + 60) }
        attachments.trash = { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        attachments.scheduleSweep()
        try await waitForSweeps(store)
        XCTAssertEqual(trashed.names, ["photo.png"], "the day started before the relaunch")
    }

    func testASweepLooksForAReferenceAgainRightBeforeTrashing() async throws {
        try put("_attachments/photo.png", "png bytes")
        try put("Photo.md", "# Photo\n\n![photo](_attachments/photo.png)\n")
        let store = open()
        try await waitForSweeps(store)
        let attachments = try XCTUnwrap(store.markdownStorage?.attachments)
        let index = try XCTUnwrap(store.markdownStorage?.index)
        let id = try XCTUnwrap(store.notes.first { $0.title == "Photo" }?.id)
        var entry = try XCTUnwrap(index.entry(id))
        entry.attachments = []
        index.set(entry, for: id)
        var clock = Date()
        attachments.now = { clock }
        attachments.sweep()
        clock.addTimeInterval(AttachmentStore.graceInterval + 1)
        let trashed = LockedNames()
        attachments.trash = { url in trashed.append(url.lastPathComponent) }
        attachments.beforeTrashing = { _ in
            entry.attachments = ["photo.png"]
            index.set(entry, for: id)
        }
        attachments.sweep()
        XCTAssertEqual(trashed.names, [], "a note referred to it again while the sweep ran")
    }

    /// Waits until the sweeps the store scheduled have run.
    private func waitForSweeps(_ store: NoteStore) async throws {
        let attachments = try XCTUnwrap(store.markdownStorage?.attachments)
        await withCheckedContinuation { continuation in attachments.afterScheduledSweeps { continuation.resume() } }
    }

    func testAnEditABackgroundReaderLoadedFirstStillReachesTheNote() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        try edit("Note.md", "# Note\n\nfirst", "# Renamed\n\nsecond")
        _ = try store.markdownStorage?.read(id)
        store.rescanNow()
        XCTAssertEqual(store.note(with: id)?.title, "Renamed")
        XCTAssertTrue(store.body(for: id).string.contains("second"))
    }

    func testACleanNoteReloadsAndKeepsItsPreviousTextInHistory() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        store.flush()
        XCTAssertTrue(store.body(for: id).string.contains("first"))
        let before = try XCTUnwrap(store.note(with: id))
        let versions = store.history.versions(of: id).count
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .noteItLocalChange, object: store, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let modified = Date(timeIntervalSince1970: 1_900_000_000)
        try edit("Note.md", "first", "second", modified: modified)
        store.rescanNow()
        store.flush()

        let after = try XCTUnwrap(store.note(with: id))
        XCTAssertTrue(store.body(for: id).string.contains("second"))
        XCTAssertNotEqual(after.revision, before.revision)
        XCTAssertEqual(after.updatedAt.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(store.history.versions(of: id).count, versions + 1, "the text before the outside edit is a version")
        XCTAssertEqual(posted, 1)
        XCTAssertTrue(try read("Note.md").contains("second"))

        store.rescanNow()
        store.flush()
        XCTAssertEqual(store.note(with: id)?.revision, after.revision, "a second scan changes nothing")
        XCTAssertEqual(store.history.versions(of: id).count, versions + 1)
    }

    func testUnsavedEditsWinAndTheFileBecomesAConflictCopy() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        store.flush()
        let mine = NSMutableAttributedString(attributedString: store.body(for: id))
        mine.mutableString.replaceOccurrences(of: "first", with: "mine", range: NSRange(location: 0, length: mine.length))
        store.updateBody(id, mine)

        try edit("Note.md", "first", "theirs")
        store.rescanNow()
        store.flush()

        XCTAssertTrue(store.body(for: id).string.contains("mine"))
        let copy = try note(store, titled: "Note (Outside NoteIt)")
        XCTAssertEqual(copy.conflictSource, NoteStore.outsideNoteItSource)
        XCTAssertEqual(copy.conflictOriginalID, id)
        XCTAssertTrue(store.body(for: copy.id).string.contains("theirs"))
        XCTAssertTrue(try read("Note.md").contains("mine"))
    }

    func testANewFileWaitsUntilItHasSettled() throws {
        let store = open()
        store.flush()
        let now = Date()
        store.markdownClock = { now }
        try put("Fresh.md", "# Fresh\n\nstill being written\n", modified: now.addingTimeInterval(-1))
        store.rescanNow()
        XCTAssertNil(store.notes.first { $0.title == "Fresh" }, "a file younger than 2 seconds isn't read yet")

        store.markdownClock = { now.addingTimeInterval(1.5) }
        store.rescanNow()
        let fresh = try note(store, titled: "Fresh")
        XCTAssertEqual(fresh.preview, "still being written")
        XCTAssertTrue(try read("Fresh.md").contains("id: \(fresh.id.uuidString)"))
    }

    func testADeletedFileMovesItsNoteToRecentlyDeletedWithACopyInTrash() throws {
        try put("Gone.md", "# Gone\n\nkeep me\n")
        try put("Stay.md", "# Stay\n")
        let store = open()
        let id = try note(store, titled: "Gone").id
        store.flush()

        try fm.removeItem(at: content.appendingPathComponent("Gone.md"))
        store.rescanNow()
        store.flush()

        XCTAssertNotNil(store.note(with: id)?.deletedAt)
        XCTAssertTrue(try read(".trash/Gone.md").contains("keep me"))
        XCTAssertTrue(store.body(for: id).string.contains("keep me"))
        XCTAssertNil(try note(store, titled: "Stay").deletedAt)
    }

    func testRenamedMovedAndDeletedFoldersFollowTheirNotebooks() throws {
        try put("Work/Plan.md", "# Plan\n")
        try put("Home/List.md", "# List\n")
        try put("Archive/Old.md", "# Old\n")
        let store = open()
        let plan = try note(store, titled: "Plan").id
        let list = try note(store, titled: "List").id
        let old = try note(store, titled: "Old").id
        let work = try XCTUnwrap(store.notebooks.first { $0.name == "Work" }).id
        let home = try XCTUnwrap(store.notebooks.first { $0.name == "Home" }).id
        let archive = try XCTUnwrap(store.notebooks.first { $0.name == "Archive" }).id
        store.flush()

        try fm.moveItem(at: content.appendingPathComponent("Work"), to: content.appendingPathComponent("Office"))
        try fm.moveItem(at: content.appendingPathComponent("Home"), to: content.appendingPathComponent("Office/Home"))
        try fm.removeItem(at: content.appendingPathComponent("Archive"))
        store.rescanNow()
        store.flush()

        XCTAssertEqual(store.notebook(with: work)?.name, "Office")
        XCTAssertEqual(store.notebook(with: home)?.parent, work)
        XCTAssertEqual(store.note(with: plan)?.notebookID, work)
        XCTAssertEqual(store.note(with: list)?.notebookID, home)
        XCTAssertNil(store.note(with: list)?.deletedAt)
        XCTAssertNil(store.notebook(with: archive))
        XCTAssertNotNil(store.note(with: old)?.deletedAt)
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent(".trash/Old.md").path))
    }

    func testNoteItsOwnWritesAreNotOutsideChanges() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        let body = NSMutableAttributedString(attributedString: store.body(for: id))
        body.append(NSAttributedString(string: "\nmore"))
        store.updateBody(id, body)
        store.flush()
        let saved = try XCTUnwrap(store.note(with: id))
        let versions = store.history.versions(of: id).count

        store.rescanNow()
        XCTAssertEqual(store.note(with: id)?.revision, saved.revision)
        XCTAssertEqual(store.history.versions(of: id).count, versions)
        XCTAssertNil(store.notes.first { $0.conflictSource != nil })
    }

    func testAFileThatIsNoLongerMarkdownIsReadOnly() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        store.flush()
        try Data([0x23, 0x20, 0xFF, 0xFE, 0x0A]).write(to: content.appendingPathComponent("Note.md"))
        store.rescanNow()
        XCTAssertEqual(store.loadError(for: id), MarkdownBodyStorage.unreadableReason)
        store.updateBody(id, NSAttributedString(string: "Note\nreplaced"))
        store.flush()
        XCTAssertEqual(try Data(contentsOf: content.appendingPathComponent("Note.md")), Data([0x23, 0x20, 0xFF, 0xFE, 0x0A]))
    }

    func testAMissingContentFolderIsReportedOnceAndNothingChanges() throws {
        try put("Note.md", "# Note\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        store.flush()
        var reported: [URL] = []
        store.onMarkdownFolderMissing = { reported.append($0) }
        try fm.moveItem(at: content, to: root.appendingPathComponent("elsewhere"))
        store.rescanNow()
        store.rescanNow()
        XCTAssertEqual(reported, [content])
        XCTAssertNil(store.note(with: id)?.deletedAt)
    }

    func testTheWatcherPicksUpANewFile() throws {
        let store = open()
        store.flush()
        store.startWatchingMarkdownFolder()
        defer { store.stopWatchingMarkdownFolder() }
        var deadline = Date().addingTimeInterval(5)
        while store.markdownWatcher == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNotNil(store.markdownWatcher)
        try put("Dropped.md", "# Dropped\n\nfrom another app\n")
        deadline = Date().addingTimeInterval(5)
        while store.notes.first(where: { $0.title == "Dropped" }) == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(store.notes.first { $0.title == "Dropped" })
    }

    func testAFileWrittenWithoutPauseDoesNotPostponeTheRescanForever() throws {
        var rescans: [Date] = []
        let watcher = MarkdownFolderWatcher(root: content, onChange: { rescans.append(Date()) },
                                            onRootChanged: {})
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let start = Date()
        try put("Settled.md", "# Settled\n")
        var tick = 0
        while Date().timeIntervalSince(start) < MarkdownFolderWatcher.maxDelay + 2 {
            tick += 1
            try put("Log.md", "# Log\n\nline \(tick)\n")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let first = try XCTUnwrap(rescans.first, "a file written every 0.1 s must not hold the rescan back")
        XCTAssertLessThan(first.timeIntervalSince(start), MarkdownFolderWatcher.maxDelay + 1)
    }

    func testTheWatcherReadsNoFileAndItsStopNeverWaits() throws {
        var rescans = 0
        let watcher = MarkdownFolderWatcher(root: content, onChange: { rescans += 1 }, onRootChanged: {})
        XCTAssertTrue(watcher.start())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try put("Edited.md", "# Edited\n")
        let deadline = Date().addingTimeInterval(3)
        while rescans == 0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(rescans, 1, "the event asks for a rescan without reading the file")
        try put("Next.md", "# Next\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let started = Date()
        watcher.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "stopping never waits for the watcher's queue")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(rescans, 1, "nothing pending is reported after the stop")
    }

    func testTheScanTellsNoteItsOwnWritesApartThroughTheLedger() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let storage = try XCTUnwrap(store.markdownStorage)
        let id = try note(store, titled: "Note").id
        let rewritten = Data("---\nid: \(id.uuidString)\n---\n# Note\n\nbeing written\n".utf8)
        storage.ledger.record(path: "Note.md", sha256: AttachmentStore.sha256(rewritten))
        try rewritten.write(to: content.appendingPathComponent("Note.md"))
        try Data("# Fresh\n".utf8).write(to: content.appendingPathComponent("Fresh.md"))
        storage.ledger.record(path: "Fresh.md", sha256: AttachmentStore.sha256(Data("# Fresh\n".utf8)))
        let result = FolderScanner.scan(contentRoot: content, index: storage.index, ledger: storage.ledger)
        XCTAssertEqual(result.changed, [:], "a file NoteIt is writing isn't an outside edit")
        XCTAssertEqual(result.added, [])
    }
}

private final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var names: [String] { lock.withLock { stored } }
    func append(_ name: String) { lock.withLock { stored.append(name) } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

/// The longest time the main thread went without running a block queued every 20 ms.
@MainActor
private final class MainThreadHeartbeat {
    private var last = Date()
    private var running = false
    private(set) var longestGap: TimeInterval = 0

    func start() {
        running = true
        last = Date()
        beat()
    }

    func stop() { running = false }

    private func beat() {
        let now = Date()
        longestGap = max(longestGap, now.timeIntervalSince(last))
        last = now
        guard running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { self.beat() } }
    }
}
