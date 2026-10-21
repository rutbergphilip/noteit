import XCTest
@testable import NoteIt

final class MarkdownLibraryPerformanceTests: XCTestCase {
    func testANoChangeScanOfTenThousandFilesIsFast() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("noteit-scan-perf-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let content = root.appendingPathComponent("content", isDirectory: true)
        let index = MarkdownPathIndex(dataDir: root.appendingPathComponent("data", isDirectory: true))
        try index.batch {
            for folder in 0..<20 {
                let dir = content.appendingPathComponent("Folder \(folder)", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for number in 0..<500 {
                    let id = UUID()
                    let data = Data("---\nid: \(id.uuidString)\n---\n\nNote \(number)\n".utf8)
                    let url = dir.appendingPathComponent("Note \(number).md")
                    try data.write(to: url)
                    let stat = try XCTUnwrap(MarkdownFileStat.of(url))
                    index.set(MarkdownFileEntry(path: "Folder \(folder)/Note \(number).md", sha256: AttachmentStore.sha256(data),
                                                size: stat.size, mtimeNs: stat.mtimeNs, inode: stat.inode), for: id)
                }
            }
        }
        let start = Date()
        let result = FolderScanner.scan(contentRoot: content, index: index)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.fileCount, 10_000)
        XCTAssertFalse(result.hasNoteChanges)
        #if !DEBUG
        XCTAssertLessThan(elapsed, 1, "a no-change scan of 10,000 files")
        #endif
        print("FolderScanner: 10,000 files in \(elapsed) s")
    }
}
