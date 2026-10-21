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
