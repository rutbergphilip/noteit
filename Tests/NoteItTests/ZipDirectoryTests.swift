import Foundation
import XCTest
@testable import NoteIt

/// Builds stored (uncompressed) ZIP archives byte by byte.
private struct ZipFixture {
    struct File {
        var name: [UInt8]
        var data: Data
        var utf8Flag = false
        /// A Zip64 size written in the central directory instead of the real one.
        var statedZip64Size: UInt64?
    }

    /// 0 = MS-DOS/FAT, 3 = Unix.
    var host: UInt8 = 3
    var files: [File]
    var zip64 = false

    func data() -> Data {
        typealias Z = ZipFixture
        var out = Data()
        var central = Data()
        for file in files {
            let flags = file.utf8Flag ? 0x0800 : 0
            let crc = Z.crc32(file.data)
            let size = UInt32(file.data.count)
            let offset = UInt32(out.count)
            let local: [Data] = [Z.le32(0x0403_4B50), Z.le16(20), Z.le16(flags), Z.le16(0), Z.le16(0), Z.le16(0),
                                 Z.le32(crc), Z.le32(size), Z.le32(size), Z.le16(file.name.count), Z.le16(0),
                                 Data(file.name), file.data]
            out += local.reduce(Data(), +)
            let extra = file.statedZip64Size.map { [Z.le16(1), Z.le16(8), Z.le64($0)].reduce(Data(), +) } ?? Data()
            let attributes: UInt32 = host == 0 ? 0x20 : 0o100644 << 16
            let stated: UInt32 = file.statedZip64Size == nil ? size : 0xFFFF_FFFF
            let header: [Data] = [Z.le32(0x0201_4B50), Z.le16(Int(host) << 8 | 20), Z.le16(20), Z.le16(flags),
                                  Z.le16(0), Z.le16(0), Z.le16(0), Z.le32(crc), Z.le32(size), Z.le32(stated),
                                  Z.le16(file.name.count), Z.le16(extra.count), Z.le16(0), Z.le16(0), Z.le16(0),
                                  Z.le32(attributes), Z.le32(offset), Data(file.name), extra]
            central += header.reduce(Data(), +)
        }
        let centralOffset = UInt64(out.count)
        out += central
        var end: [Data]
        if zip64 {
            let recordOffset = UInt64(out.count)
            end = [Z.le32(0x0606_4B50), Z.le64(44), Z.le16(45), Z.le16(45), Z.le32(0), Z.le32(0),
                   Z.le64(UInt64(files.count)), Z.le64(UInt64(files.count)),
                   Z.le64(UInt64(central.count)), Z.le64(centralOffset)]
            end += [Z.le32(0x0706_4B50), Z.le32(0), Z.le64(recordOffset), Z.le32(1)]
            end += [Z.le32(0x0605_4B50), Z.le16(0), Z.le16(0), Z.le16(0xFFFF), Z.le16(0xFFFF),
                    Z.le32(0xFFFF_FFFF), Z.le32(0xFFFF_FFFF), Z.le16(0)]
        } else {
            end = [Z.le32(0x0605_4B50), Z.le16(0), Z.le16(0), Z.le16(files.count), Z.le16(files.count),
                   Z.le32(UInt32(central.count)), Z.le32(UInt32(centralOffset)), Z.le16(0)]
        }
        return out + end.reduce(Data(), +)
    }

    static func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

@MainActor
final class ZipDirectoryTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private let pageID = "0123456789abcdef0123456789abcdef"

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-zipdir-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: base.appendingPathComponent("Library", isDirectory: true), seedsFreshLibrary: false))
    }

    private func save(_ fixture: ZipFixture, as name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try fixture.data().write(to: url)
        return url
    }

    /// A compressed part archive holding one page and filler, so it unpacks to much more than its own size.
    private func part() throws -> Data {
        let folder = base.appendingPathComponent("Part-\(UUID().uuidString)/Export", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Plan\nNext steps.".utf8).write(to: folder.appendingPathComponent("Plan \(pageID).md"))
        try Data(repeating: 65, count: 2_000_000).write(to: folder.appendingPathComponent("Filler.bin"))
        let zip = folder.deletingLastPathComponent().appendingPathComponent("part.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = try Data(contentsOf: zip)
        try fm.removeItem(at: folder.deletingLastPathComponent())
        return data
    }

    private func importExport(_ outer: URL, into store: NoteStore, parts: [Data]) async throws -> ImportReport {
        let limits = try exactLimit(outer: outer, parts: parts)
        do {
            return try await NotionImporter.importExport(outer, into: store, limits: limits)
        } catch {
            XCTFail("\(error) with \(limits)")
            throw error
        }
    }

    private func exactLimit(outer: URL, parts: [Data]) throws -> ZipLimits {
        let outerTotals = try XCTUnwrap(MarkdownImporter.zipTotals(outer))
        var bytes = outerTotals.bytes
        var entries = outerTotals.entries
        for part in parts {
            let url = base.appendingPathComponent("measure-\(UUID().uuidString).zip")
            try part.write(to: url)
            let totals = try XCTUnwrap(MarkdownImporter.zipTotals(url))
            bytes += totals.bytes - Int64(part.count)
            entries += totals.entries
            try fm.removeItem(at: url)
        }
        return ZipLimits(maxEntries: entries, maxBytes: bytes)
    }

    func testPartsFromAnMSDOSHostAreChargedOnce() async throws {
        let inner = try part()
        let outer = try save(ZipFixture(host: 0, files: [.init(name: Array("Export-Part-1.zip".utf8), data: inner)]),
                             as: "Notion.zip")
        XCTAssertEqual(MarkdownImporter.topLevelZipSizes(outer), ["Export-Part-1.zip": Int64(inner.count)])
        let report = try await importExport(outer, into: makeStore(), parts: [inner])
        XCTAssertEqual(report.notesImported, 1)
    }

    func testNonASCIINamesUnderAUTF8Locale() async throws {
        let previous = ProcessInfo.processInfo.environment["LC_ALL"]
        setenv("LC_ALL", "en_US.UTF-8", 1)
        defer { if let previous { setenv("LC_ALL", previous, 1) } else { unsetenv("LC_ALL") } }

        let inner = try part()
        let partName = "Del 😀 Ö—Ä.zip".decomposedStringWithCanonicalMapping
        let outer = try save(ZipFixture(files: [
            .init(name: Array("Möte Ü/Sida ä \(pageID.replacingOccurrences(of: "0", with: "9")).md".utf8),
                  data: Data("# Sida ä\nHej då — É".utf8), utf8Flag: true),
            .init(name: Array(partName.utf8), data: inner, utf8Flag: true),
        ]), as: "Notion.zip")
        let names = try XCTUnwrap(MarkdownImporter.zipEntries(outer))
        XCTAssertTrue(names.contains { $0.precomposedStringWithCanonicalMapping.hasPrefix("Möte Ü/Sida ä") }, "\(names)")

        let store = makeStore()
        let report = try await importExport(outer, into: store, parts: [inner])
        XCTAssertEqual(report.notesImported, 2)
        XCTAssertTrue(report.archivesSkipped.isEmpty)
        XCTAssertNotNil(store.notes.first { $0.title.precomposedStringWithCanonicalMapping == "Sida ä" })
        XCTAssertNotNil(store.notes.first { $0.title == "Plan" })
    }

    func testUnflaggedNamesAreReadAsCP437UnlessTheyAreUTF8() throws {
        let outer = try save(ZipFixture(files: [
            .init(name: [0x8E, 0x2E, 0x6D, 0x64], data: Data("x".utf8)),
            .init(name: Array("Möte.md".utf8), data: Data("y".utf8)),
        ]), as: "Old.zip")
        XCTAssertEqual(MarkdownImporter.zipEntries(outer), ["Ä.md", "Möte.md"])
    }

    func testZip64SizesAreRead() async throws {
        let outer = try save(ZipFixture(files: [
            .init(name: Array("Big \(pageID).md".utf8), data: Data("x".utf8), statedZip64Size: 9_000_000_000),
            .init(name: Array("Small.md".utf8), data: Data("yy".utf8)),
        ], zip64: true), as: "Huge.zip")
        let totals = try XCTUnwrap(MarkdownImporter.zipTotals(outer))
        XCTAssertEqual(totals.entries, 2)
        XCTAssertEqual(totals.bytes, 9_000_000_002)
        do {
            _ = try await NotionImporter.importExport(outer, into: makeStore())
            XCTFail("No error thrown")
        } catch {
            XCTAssertEqual(error as? ImportError, .archiveTooLarge("Huge.zip"))
        }
    }

    func testCorruptDirectoryIsUnreadable() async throws {
        let good = ZipFixture(files: [.init(name: Array("Page \(pageID).md".utf8), data: Data("# Page".utf8))]).data()
        var badSignature = good
        let central = try XCTUnwrap(good.range(of: ZipFixture.le32(0x0201_4B50)))
        badSignature[central.lowerBound] = 0
        var pastEnd = good
        pastEnd.replaceSubrange((good.count - 6)..<(good.count - 2), with: ZipFixture.le32(0x7FFF_FFFF))
        let cases: [(String, Data)] = [
            ("Truncated.zip", good.prefix(good.count - 30)),
            ("Signature.zip", badSignature),
            ("PastEnd.zip", pastEnd),
            ("Tiny.zip", Data("PK".utf8)),
        ]
        for (name, data) in cases {
            let url = base.appendingPathComponent(name)
            try data.write(to: url)
            XCTAssertNil(MarkdownImporter.zipTotals(url), name)
            do {
                _ = try await NotionImporter.importExport(url, into: makeStore())
                XCTFail("No error thrown for \(name)")
            } catch {
                XCTAssertEqual(error as? ImportError, .unreadableArchive(name))
            }
        }
    }
}
