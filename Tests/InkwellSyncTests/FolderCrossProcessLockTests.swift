import XCTest
@testable import InkwellSync

final class FolderCrossProcessLockTests: XCTestCase {
    func testConditionalPutsFromSeparateInstancesHaveOneWinner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-xlock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for round in 0..<40 {
            let key = "notes/\(round).meta"
            let seed = FolderBackend(root: root)
            let base = try await seed.put(key, data: Data("base".utf8), ifMatch: nil, ifNoneMatch: true)
            let instances = (0..<6).map { _ in FolderBackend(root: root) }
            let wins = await withTaskGroup(of: Bool.self) { group in
                for (i, backend) in instances.enumerated() {
                    group.addTask {
                        (try? await backend.put(key, data: Data("writer-\(i)-\(round)".utf8), ifMatch: base, ifNoneMatch: false)) != nil
                    }
                }
                var count = 0
                for await won in group where won { count += 1 }
                return count
            }
            XCTAssertEqual(wins, 1, "round \(round)")
        }
    }
}
