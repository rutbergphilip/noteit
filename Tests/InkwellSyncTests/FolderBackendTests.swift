import XCTest
@testable import InkwellSync

final class FolderBackendTests: XCTestCase {
    private var root: URL!
    private var backend: FolderBackend!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        backend = FolderBackend(root: root)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        backend = nil
    }

    func testPutGetRoundTrip() async throws {
        let data = Data("hello".utf8)
        let etag = try await backend.put("a/b", data: data, ifMatch: nil, ifNoneMatch: false)
        let got = try await backend.get("a/b")
        XCTAssertEqual(got.data, data)
        XCTAssertEqual(got.etag, etag)

        let etag2 = try await backend.put("a/b", data: Data("bye".utf8), ifMatch: nil, ifNoneMatch: false)
        XCTAssertNotEqual(etag, etag2)
        let again = try await backend.get("a/b")
        XCTAssertEqual(again.data, Data("bye".utf8))
        XCTAssertEqual(again.etag, etag2)
    }

    func testIfNoneMatchFailsWhenExists() async throws {
        try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: true)
        do {
            try await backend.put("k", data: Data([2]), ifMatch: nil, ifNoneMatch: true)
            XCTFail("Expected preconditionFailed")
        } catch let error as StorageError {
            XCTAssertEqual(error, .preconditionFailed("k"))
        }
        let got = try await backend.get("k")
        XCTAssertEqual(got.data, Data([1]))
        XCTAssertEqual(try tempFiles(), [])
    }

    func testIfMatchFailsOnStaleETag() async throws {
        let first = try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: false)
        let second = try await backend.put("k", data: Data([2]), ifMatch: first, ifNoneMatch: false)
        do {
            try await backend.put("k", data: Data([3]), ifMatch: first, ifNoneMatch: false)
            XCTFail("Expected preconditionFailed")
        } catch let error as StorageError {
            XCTAssertEqual(error, .preconditionFailed("k"))
        }
        do {
            try await backend.put("absent", data: Data([3]), ifMatch: first, ifNoneMatch: false)
            XCTFail("Expected preconditionFailed")
        } catch let error as StorageError {
            XCTAssertEqual(error, .preconditionFailed("absent"))
        }
        let got = try await backend.get("k")
        XCTAssertEqual(got.data, Data([2]))
        XCTAssertEqual(got.etag, second)
    }

    func testListPrefix() async throws {
        try await backend.put("inkwell/v1/notes/1.meta", data: Data([1, 2]), ifMatch: nil, ifNoneMatch: false)
        try await backend.put("inkwell/v1/notes/2.meta", data: Data([1]), ifMatch: nil, ifNoneMatch: false)
        try await backend.put("other/x", data: Data(), ifMatch: nil, ifNoneMatch: false)

        let objects = try await backend.list(prefix: "inkwell/v1/")
        XCTAssertEqual(objects.map(\.key), ["inkwell/v1/notes/1.meta", "inkwell/v1/notes/2.meta"])
        XCTAssertEqual(objects.map(\.size), [2, 1])
        let got = try await backend.get("inkwell/v1/notes/1.meta")
        XCTAssertEqual(objects.first?.etag, got.etag)
    }

    func testDeleteMissingThrowsNotFound() async throws {
        do {
            try await backend.delete("missing")
            XCTFail("Expected notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound("missing"))
        }
        do {
            _ = try await backend.get("missing")
            XCTFail("Expected notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound("missing"))
        }
        try await backend.put("k", data: Data(), ifMatch: nil, ifNoneMatch: false)
        try await backend.delete("k")
        do {
            _ = try await backend.get("k")
            XCTFail("Expected notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound("k"))
        }
    }

    func testEtagChangesOnRewrite() async throws {
        var previous = try await backend.put("k", data: Data([1, 2, 3]), ifMatch: nil, ifNoneMatch: false)
        for i in 0..<50 {
            let next = try await backend.put("k", data: Data([UInt8(i), 2, 3]), ifMatch: previous, ifNoneMatch: false)
            XCTAssertNotEqual(next, previous)
            previous = next
        }
    }

    func testListSkipsTempAndHiddenFiles() async throws {
        try await backend.put("inkwell/v1/notes/a.meta", data: Data([1]), ifMatch: nil, ifNoneMatch: false)
        let dir = root.appendingPathComponent("inkwell/v1/notes")
        try Data([1]).write(to: dir.appendingPathComponent(".a.meta.tmp-\(UUID().uuidString)"))
        try Data([1]).write(to: dir.appendingPathComponent("b.meta.tmp-123"))
        try Data([1]).write(to: dir.appendingPathComponent(".hidden"))
        try Data([1]).write(to: dir.appendingPathComponent("c.meta.icloud"))
        let hiddenDir = root.appendingPathComponent("inkwell/.Trash")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try Data([1]).write(to: hiddenDir.appendingPathComponent("x"))

        let objects = try await backend.list(prefix: "")
        XCTAssertEqual(objects.map(\.key), ["inkwell/v1/notes/a.meta"])
    }

    func testProbeFailsOnReadOnlyDir() async throws {
        try await backend.probe()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        do {
            try await backend.probe()
            XCTFail("Expected io error")
        } catch let error as StorageError {
            guard case .io = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testProbeFailsOnMissingRoot() async throws {
        let missing = FolderBackend(root: root.appendingPathComponent("nope"))
        do {
            try await missing.probe()
            XCTFail("Expected notFound")
        } catch let error as StorageError {
            guard case .notFound = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testNestedKeysCreateDirectories() async throws {
        let key = "inkwell/v1/devices/deep/er/mac-1.json"
        try await backend.put(key, data: Data("x".utf8), ifMatch: nil, ifNoneMatch: true)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("inkwell/v1/devices/deep/er").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        let got = try await backend.get(key)
        XCTAssertEqual(got.data, Data("x".utf8))
        XCTAssertEqual(try tempFiles(), [])
    }

    private func tempFiles() throws -> [String] {
        let paths = FileManager.default.subpaths(atPath: root.path) ?? []
        return paths.filter { $0.contains(".tmp-") }
    }
}
