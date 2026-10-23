import Foundation
import NoteItDocTestSupport
import XCTest
@testable import NoteItSync

/// foundations Task 3.5: the prefix registry, key grammar and rekey scope.
final class RemoteLayoutRegistryTests: XCTestCase {
    struct KeyCase: Codable {
        var key: String
        var valid: Bool
        var prefix: String?
        var action: String
    }

    struct ListCase: Codable {
        var prefix: String
        var allowed: Bool
    }

    struct LayoutFile: Codable {
        var generator: String
        var version: Int
        var keys: [KeyCase]
        var listPrefixes: [ListCase]
    }

    private func vectors() throws -> LayoutFile {
        let file = try GoldenFixtures.load("layout-keys.json", as: LayoutFile.self)
        XCTAssertEqual(file.generator, "spec")
        XCTAssertEqual(file.version, 1)
        return file
    }

    private func name(_ action: RekeyScope.Action) -> String {
        switch action {
        case .reseal: "reseal"
        case .skip: "skip"
        case .block: "block"
        }
    }

    func testEveryListedPrefixIsRegistered() {
        let id = UUID()
        let keys = [RemoteLayout.meta(.notebook, id), RemoteLayout.meta(.note, id), RemoteLayout.body(id),
                    RemoteLayout.tombstone(id), RemoteLayout.device(UUID().uuidString), RemoteLayout.meta(.smartFolder, id),
                    RemoteLayout.reminderClaim(id), RemoteLayout.docBody(id, version: UUID(), tag: RemoteLayout.newTag),
                    RemoteLayout.docBody(id, version: UUID(), tag: RemoteLayout.baseTag("\"etag\""), locked: true)]
        for key in keys {
            XCTAssertNotNil(RemoteLayout.prefix(for: key), key)
            XCTAssertTrue(RemoteLayout.isValidKey(key), key)
            XCTAssertEqual(RekeyScope.action(for: key), .reseal, key)
        }
        XCTAssertTrue(RemoteLayout.isValidKey(RemoteLayout.manifestKey))
        XCTAssertEqual(RemoteLayout.manifestKey, RemoteLayout.manifest())
        XCTAssertTrue(RemoteLayout.isValidKey(RemoteLayout.canaryPrefix + id.uuidString))
        XCTAssertEqual(RemoteLayout.prefixes.map(\.path).sorted(), RemoteLayout.prefixes.map(\.path).sorted().uniqued())
        for row in RemoteLayout.prefixes {
            XCTAssertEqual(row.depth, 1)
            XCTAssertEqual(row.sealing, .storeKey)
            XCTAssertTrue(["core", "organise", "web-app"].contains(row.owner), row.path)
            XCTAssertTrue(RemoteLayout.isListablePrefix(row.path))
        }
    }

    func testKeyGrammar() throws {
        let file = try vectors()
        XCTAssertFalse(file.keys.isEmpty)
        for c in file.keys {
            XCTAssertEqual(RemoteLayout.isValidKey(c.key), c.valid, c.key)
            XCTAssertEqual(RemoteLayout.prefix(for: c.key)?.path, c.prefix, c.key)
            XCTAssertEqual(name(RekeyScope.action(for: c.key)), c.action, c.key)
        }
    }

    func testListPrefixes() throws {
        let file = try vectors()
        XCTAssertFalse(file.listPrefixes.isEmpty)
        for c in file.listPrefixes {
            XCTAssertEqual(RemoteLayout.isListablePrefix(c.prefix), c.allowed, c.prefix)
        }
    }

    func testRekeyScope() {
        let id = UUID().uuidString
        XCTAssertEqual(RekeyScope.action(for: RemoteLayout.root + "attachments/\(id).bin"), .block)
        XCTAssertEqual(RekeyScope.action(for: "elsewhere/\(id).json"), .block)
        XCTAssertEqual(RekeyScope.action(for: RemoteLayout.manifestKey), .skip)
        XCTAssertEqual(RekeyScope.action(for: RemoteLayout.canaryPrefix + id), .skip)

        let space = RemotePrefix(path: RemoteLayout.root + "spaces/", depth: 1, sealing: .spaceKey, owner: "sharing")
        let log = RemotePrefix(path: RemoteLayout.root + "log/", depth: 1, sealing: .unsealed, owner: "sync-security")
        let rows = RemoteLayout.prefixes + [space, log]
        let spaceKey = space.path + "\(id).json"
        let logKey = log.path + "\(id).json"
        XCTAssertEqual(RekeyScope.action(for: spaceKey, rekeying: .storeKey, prefixes: rows), .skip)
        XCTAssertEqual(RekeyScope.action(for: spaceKey, rekeying: .spaceKey, prefixes: rows), .reseal)
        XCTAssertEqual(RekeyScope.action(for: logKey, rekeying: .storeKey, prefixes: rows), .skip)
        XCTAssertEqual(RekeyScope.action(for: logKey, rekeying: .spaceKey, prefixes: rows), .skip)
        XCTAssertEqual(RekeyScope.action(for: RemoteLayout.body(UUID()), rekeying: .spaceKey, prefixes: rows), .skip)
        XCTAssertEqual(RekeyScope.action(for: spaceKey), .block, "not registered by default")
    }

    func testSamePathDifferentDepthRows() {
        let wave0 = RemoteLayout.prefixes.first { $0.path == RemoteLayout.root + "devices/" }!
        let sharing = RemotePrefix(path: RemoteLayout.root + "devices/", depth: 2, sealing: .storeKey, owner: "sharing")
        let rows = RemoteLayout.prefixes + [sharing]
        let personal = RemoteLayout.device(UUID().uuidString)
        let member = RemoteLayout.device("M1/\(UUID().uuidString)")
        XCTAssertTrue(RemoteLayout.isValidKey(personal, prefixes: rows))
        XCTAssertTrue(RemoteLayout.isValidKey(member, prefixes: rows))
        XCTAssertEqual(RemoteLayout.prefix(for: personal, prefixes: rows), wave0)
        XCTAssertEqual(RemoteLayout.prefix(for: member, prefixes: rows), sharing)
        XCTAssertFalse(RemoteLayout.isValidKey(member), "wave 0 has no depth-2 devices row")
    }

    func testLegacyListRootsAllowed() {
        XCTAssertTrue(RemoteLayout.isListablePrefix(RemoteLayout.legacyRoot), "RemoteMigration lists it")
        XCTAssertTrue(RemoteLayout.isListablePrefix("inkwell/"))
        XCTAssertFalse(RemoteLayout.isValidKey(RemoteLayout.legacyRoot + "manifest.json"))
        XCTAssertTrue(RemoteLayout.isListablePrefix(RemoteLayout.root))
        XCTAssertTrue(RemoteLayout.isListablePrefix("noteit/"))
        XCTAssertFalse(RemoteLayout.isListablePrefix(""))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
