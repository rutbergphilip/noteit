import CryptoKit
import XCTest
@testable import NoteIt
import NoteItSync

/// The sync folder is checked off the main thread and for a bounded time, so a NAS that went away can't freeze NoteIt.
@MainActor
final class SyncFolderReachabilityTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-nas-\(UUID().uuidString)/Shared Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    private var config: SyncConfiguration {
        SyncConfiguration(provider: .folder, folderPath: folder.path, encrypted: false, deviceID: "test", deviceName: "Test")
    }

    private func assertUnreachable(_ work: () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("expected folderUnavailable", file: file, line: line)
        } catch SyncSetupError.folderUnavailable(let name) {
            XCTAssertEqual(name, "Shared Notes", file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testReachableFolderResolves() async throws {
        let resolved = try await SyncController.checkFolder(config, access: BoundedFileAccess(), timeout: 5)
        XCTAssertEqual(resolved.url.standardizedFileURL.path, folder.standardizedFileURL.path)
    }

    func testMissingFolderIsUnavailable() async throws {
        try FileManager.default.removeItem(at: folder)
        await assertUnreachable { try await SyncController.checkFolder(self.config, access: BoundedFileAccess(), timeout: 5) }
    }

    func testHangingFolderDoesNotBlockTheMainActor() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let access = BoundedFileAccess()
        let probedOnMain = LockedFlag()
        let hang: @Sendable (URL) -> Bool = { _ in
            if Thread.isMainThread { probedOnMain.set() }
            release.wait()
            return true
        }

        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { ticks += 1 } }
        defer { timer.invalidate() }
        let started = Date()
        await assertUnreachable { try await SyncController.checkFolder(self.config, access: access, timeout: 0.3, isDirectory: hang) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertGreaterThan(ticks, 3, "the main run loop stalled while the folder hung")
        XCTAssertFalse(probedOnMain.value)

        // Still stuck: the next check gives up at once instead of queueing behind it.
        let again = Date()
        await assertUnreachable { try await SyncController.checkFolder(self.config, access: access, timeout: 5, isDirectory: hang) }
        XCTAssertLessThan(Date().timeIntervalSince(again), 1)

        release.signal()
        while access.isRunning("sync-folder:\(config.storeKey)") { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await SyncController.checkFolder(config, access: access, timeout: 5)
    }

    func testBlockedFolderStallsNeitherTheMainActorNorDisconnect() async throws {
        _ = NSApplication.shared
        let library = folder.deletingLastPathComponent().appendingPathComponent("library", isDirectory: true)
        let store = NoteStore(location: LibraryLocation(url: library, seedsFreshLibrary: false))
        let controller = SyncController(store: store, keepsSecretsInMemory: true)
        let gate = FolderGate()
        controller.folderAccess = BoundedFileAccess()
        controller.folderCheckTimeout = 0.3
        controller.folderIsDirectory = { gate.check($0) }
        try await controller.connect(config, accessKey: nil, secret: nil, passphrase: nil)
        defer { gate.open() }

        gate.close()
        controller.syncNow()
        let offline = SyncStatus.offline(SyncController.unreachable("Shared Notes"))
        let deadline = Date().addingTimeInterval(5)
        while controller.status != offline, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(controller.status, offline)

        let calls = gate.calls
        let started = Date()
        await controller.disconnect()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(controller.status, .notConfigured)
        XCTAssertEqual(gate.calls, calls, "disconnect looked at the folder")
        XCTAssertFalse(gate.calledOnMain, "the folder was checked on the main thread")
        XCTAssertGreaterThan(calls, 0)
    }

    /// State files are named by `storeKey`; it must not change for folders already syncing.
    func testStoreKeyMatchesTheKeyOfEarlierBuilds() throws {
        let base = folder.deletingLastPathComponent()
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let decomposed = base.appendingPathComponent("Anteckningar a\u{30A}")
        try FileManager.default.createDirectory(at: decomposed, withIntermediateDirectories: false)
        let paths = [folder.path, folder.path + "/", base.path + "/./Shared Notes//", base.path + "/Gone/../Shared Notes",
                     base.path + "/Gone", link.path, link.path + "/", decomposed.path, "/"]
        for path in paths {
            XCTAssertEqual(storeKey(path), Self.earlierStoreKey(path), path)
        }
        XCTAssertEqual(storeKey("/Volumes/Notes"), "9adab28813b3672c")
        XCTAssertEqual(storeKey("/Volumes/Notes/"), "9adab28813b3672c")
        XCTAssertEqual(storeKey("/Volumes/Notes/./Sync//"), "9bcab7e14270b977")
        XCTAssertEqual(storeKey("/Volumes/Notes/Old/../Sync"), "9bcab7e14270b977")
        XCTAssertEqual(storeKey("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/My Notes"), "34596a40166f0089")
        XCTAssertEqual(SyncConfiguration(provider: .folder, folderPath: folder.path + "/", deviceID: "test").folderName, "Shared Notes")
    }

    private func storeKey(_ path: String) -> String {
        SyncConfiguration(provider: .folder, folderPath: path, encrypted: false, deviceID: "test", deviceName: "Test").storeKey
    }

    /// How earlier builds computed `storeKey`, looking the path up on disk.
    private static func earlierStoreKey(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(["folder", standardized].joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func testOfflineMessageNamesTheFolderCalmly() {
        XCTAssertEqual(SyncController.unreachable("Shared Notes"),
                       "Can't reach “Shared Notes”. NoteIt will try again when it's available.")
        XCTAssertEqual(SyncController.describe(StorageError.unavailable("Operation timed out")),
                       "Can't reach the sync folder. NoteIt will try again when it's available.")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

/// A folder check that hangs while closed, like a NAS that stopped answering.
private final class FolderGate: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var closed = false
    private var _calls = 0
    private var _calledOnMain = false
    var calls: Int { lock.withLock { _calls } }
    var calledOnMain: Bool { lock.withLock { _calledOnMain } }

    func close() { lock.withLock { closed = true } }

    func open() {
        let wasClosed = lock.withLock { () -> Bool in
            defer { closed = false }
            return closed
        }
        if wasClosed { released.signal() }
    }

    func check(_ url: URL) -> Bool {
        let blocks = lock.withLock { () -> Bool in
            _calls += 1
            if Thread.isMainThread { _calledOnMain = true }
            return closed
        }
        if blocks {
            released.wait()
            released.signal()
        }
        return SyncController.isDirectory(url)
    }
}
