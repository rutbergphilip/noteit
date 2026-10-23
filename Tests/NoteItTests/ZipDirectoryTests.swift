import Foundation
import XCTest
import NoteItDocTestSupport
import zlib
@testable import NoteIt

/// Builds ZIP archives byte by byte, stored or deflated, optionally lying in their headers.
private struct ZipFixture {
    struct File {
        var name: [UInt8]
        var data: Data
        var utf8Flag = false
        /// A Zip64 size written in the central directory instead of the real one.
        var statedZip64Size: UInt64?
        var deflate = false
        /// The method written to both headers instead of 0 or 8.
        var method: Int?
        /// A size written to the central directory instead of the real one.
        var statedSize: UInt32?
        /// A name written to the local header instead of `name`.
        var localName: [UInt8]?
        var crc: UInt32?
        var flags = 0
        /// Unix mode written to the external attributes instead of a regular file's.
        var mode: UInt32?
        /// False leaves the entry out of the central directory.
        var listed = true
    }

    /// 0 = MS-DOS/FAT, 3 = Unix.
    var host: UInt8 = 3
    var files: [File]
    var zip64 = false
    /// Sizes and offsets moved into Zip64 extra fields.
    var zip64Fields = false
    /// Entry counts written to the end record instead of the real ones (this disk, total).
    var statedCounts: (Int, Int)?

    func data() -> Data {
        typealias Z = ZipFixture
        var out = Data()
        var central = Data()
        var listed = 0
        for file in files {
            let flags = (file.utf8Flag ? 0x0800 : 0) | file.flags
            let crc = file.crc ?? Z.crc32(file.data)
            let payload = file.deflate ? try! (file.data as NSData).compressed(using: .zlib) as Data : file.data
            let method = file.method ?? (file.deflate ? 8 : 0)
            let size = UInt32(file.data.count)
            let packed = UInt32(payload.count)
            let offset = UInt32(out.count)
            let localName = file.localName ?? file.name
            let local: [Data] = [Z.le32(0x0403_4B50), Z.le16(20), Z.le16(flags), Z.le16(method), Z.le16(0), Z.le16(0),
                                 Z.le32(crc), Z.le32(packed), Z.le32(size), Z.le16(localName.count), Z.le16(0),
                                 Data(localName), payload]
            out += local.reduce(Data(), +)
            guard file.listed else { continue }
            listed += 1
            var extra = file.statedZip64Size.map { [Z.le16(1), Z.le16(8), Z.le64($0)].reduce(Data(), +) } ?? Data()
            if zip64Fields {
                extra = [Z.le16(1), Z.le16(24), Z.le64(UInt64(size)), Z.le64(UInt64(packed)), Z.le64(UInt64(offset))]
                    .reduce(Data(), +)
            }
            let attributes: UInt32 = host == 0 ? 0x20 : (file.mode ?? 0o100644) << 16
            let stated: UInt32 = zip64Fields || file.statedZip64Size != nil ? 0xFFFF_FFFF : file.statedSize ?? size
            let header: [Data] = [Z.le32(0x0201_4B50), Z.le16(Int(host) << 8 | 20), Z.le16(20), Z.le16(flags),
                                  Z.le16(method), Z.le16(0), Z.le16(0), Z.le32(crc),
                                  Z.le32(zip64Fields ? 0xFFFF_FFFF : packed), Z.le32(stated),
                                  Z.le16(file.name.count), Z.le16(extra.count), Z.le16(0), Z.le16(0), Z.le16(0),
                                  Z.le32(attributes), Z.le32(zip64Fields ? 0xFFFF_FFFF : offset), Data(file.name), extra]
            central += header.reduce(Data(), +)
        }
        let counts = statedCounts ?? (listed, listed)
        let centralOffset = UInt64(out.count)
        out += central
        var end: [Data]
        if zip64 {
            let recordOffset = UInt64(out.count)
            end = [Z.le32(0x0606_4B50), Z.le64(44), Z.le16(45), Z.le16(45), Z.le32(0), Z.le32(0),
                   Z.le64(UInt64(counts.0)), Z.le64(UInt64(counts.1)),
                   Z.le64(UInt64(central.count)), Z.le64(centralOffset)]
            end += [Z.le32(0x0706_4B50), Z.le32(0), Z.le64(recordOffset), Z.le32(1)]
            end += [Z.le32(0x0605_4B50), Z.le16(0), Z.le16(0), Z.le16(0xFFFF), Z.le16(0xFFFF),
                    Z.le32(0xFFFF_FFFF), Z.le32(0xFFFF_FFFF), Z.le16(0)]
        } else {
            end = [Z.le32(0x0605_4B50), Z.le16(0), Z.le16(0), Z.le16(counts.0), Z.le16(counts.1),
                   Z.le32(UInt32(central.count)), Z.le32(UInt32(centralOffset)), Z.le16(0)]
        }
        return out + end.reduce(Data(), +)
    }

    static func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))) }
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
        XCTAssertEqual(MarkdownImporter.zipEntries(outer), ["Export-Part-1.zip"])
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

    // MARK: Extraction follows the central directory

    private func leftovers() -> Set<String> {
        Set(((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("noteit-import-") })
    }

    /// Unpacks `fixture`, expecting it to be refused without leaving anything behind; returns the error, if one was thrown.
    @discardableResult
    private func assertRefused(_ fixture: ZipFixture, limits: ZipLimits = ZipLimits(maxEntries: 100, maxBytes: 100 << 20),
                               file: StaticString = #filePath, line: UInt = #line) throws -> Error? {
        let url = try save(fixture, as: "Refused-\(UUID().uuidString).zip")
        let before = leftovers()
        var limits = limits
        var thrown: Error?
        do {
            if let folder = try MarkdownImporter.unzip(url, within: &limits) {
                XCTFail("unpacked to \(folder.path)", file: file, line: line)
                try? fm.removeItem(at: folder)
            }
        } catch {
            thrown = error
        }
        XCTAssertEqual(leftovers().subtracting(before), [], "partial output left behind", file: file, line: line)
        return thrown
    }

    private func page(_ text: String = "# Page\nBody") -> ZipFixture.File {
        .init(name: Array("Page \(pageID).md".utf8), data: Data(text.utf8))
    }

    func testLyingCentralSizeIsRefused() throws {
        let big = ZipFixture.File(name: Array("big.bin".utf8), data: Data(count: 5_000_000), deflate: true, statedSize: 1)
        let error = try assertRefused(ZipFixture(files: [page(), big]))
        guard case .archiveTooLarge? = error as? ImportError else { return XCTFail("\(String(describing: error))") }
    }

    func testDeflateBombOverTheCapIsAbortedWithAClearError() async throws {
        let bomb = ZipFixture.File(name: Array("bomb.bin".utf8), data: Data(count: 50_000_000), deflate: true, statedSize: 1_000)
        let url = try save(ZipFixture(files: [page(), bomb]), as: "Bomb.zip")
        let before = leftovers()
        do {
            _ = try await NotionImporter.importExport(url, into: makeStore(), limits: ZipLimits(maxEntries: 10, maxBytes: 10 << 20))
            XCTFail("No error thrown")
        } catch {
            XCTAssertEqual(error as? ImportError, .archiveTooLarge("Bomb.zip"))
        }
        XCTAssertEqual(leftovers().subtracting(before), [])
    }

    func testEntryMissingFromTheDirectoryIsNotUnpacked() throws {
        let hidden = ZipFixture.File(name: Array("hidden.bin".utf8), data: Data(count: 1_000_000), listed: false)
        let url = try save(ZipFixture(files: [page(), hidden]), as: "Hidden.zip")
        var limits = ZipLimits(maxEntries: 100, maxBytes: 1_000)
        let folder = try XCTUnwrap(try MarkdownImporter.unzip(url, within: &limits))
        defer { try? fm.removeItem(at: folder) }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), ["Page \(pageID).md"])
        XCTAssertEqual(limits.maxEntries, 99)
    }

    func testEndRecordCountsMustMatchTheDirectory() throws {
        let files = [page(), .init(name: Array("extra.md".utf8), data: Data("more".utf8))]
        for counts in [(1, 1), (2, 1), (1, 2)] {
            let fixture = ZipFixture(files: files, statedCounts: counts)
            let url = try save(fixture, as: "Count.zip")
            XCTAssertNil(MarkdownImporter.zipTotals(url), "\(counts)")
            try assertRefused(fixture)
        }
    }

    func testLocalNameMustMatchTheDirectory() throws {
        let escaped = "evil-\(UUID().uuidString).txt"
        let target = fm.temporaryDirectory.appendingPathComponent(escaped)
        defer { try? fm.removeItem(at: target) }
        let evil = ZipFixture.File(name: Array("aa/\(escaped)".utf8), data: Data("oops".utf8),
                                   localName: Array("../\(escaped)".utf8))
        try assertRefused(ZipFixture(files: [page(), evil]))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    func testCRCMismatchIsRefused() throws {
        for deflate in [false, true] {
            let bad = ZipFixture.File(name: Array("bad.md".utf8), data: Data("checked".utf8), deflate: deflate, crc: 0x1234_5678)
            try assertRefused(ZipFixture(files: [page(), bad]))
        }
    }

    func testSymlinkEncryptedAndUnknownMethodEntriesAreRefusedWithAReason() throws {
        let cases: [(ZipFixture.File, String)] = [
            (.init(name: Array("link.md".utf8), data: Data("Page \(pageID).md".utf8), mode: 0o120777), "symbolic link"),
            (.init(name: Array("secret.md".utf8), data: Data("garbage".utf8), flags: 1), "encrypted"),
            (.init(name: Array("bz.md".utf8), data: Data("garbage".utf8), method: 12), "compression method"),
        ]
        for (file, reason) in cases {
            let error = try assertRefused(ZipFixture(files: [page(), file]))
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains(reason), "\(reason): \(message)")
            XCTAssertTrue(message.contains(file.name.map { String(UnicodeScalar($0)) }.joined()), message)
        }
    }

    func testTooDeepOrTooLongNamesAreRefusedWithAReason() throws {
        let deep = String(repeating: "d/", count: 299) + "x.md"
        let long = String(repeating: "漢", count: 256)
        let part = String(repeating: "e", count: 255)
        let cases = [[deep], [long], [String(repeating: "d/", count: 30_000) + "x.md"],
                     [[part, part, part, part].joined(separator: "/")], [part, part], [part, part + "/x.md"]]
        for names in cases {
            let start = Date()
            let error = try assertRefused(ZipFixture(files: [page()] + names.map { .init(name: Array($0.utf8), data: Data()) }))
            XCTAssertLessThan(Date().timeIntervalSince(start), TestTiming.scaled(2))
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("too deeply nested or too long"), message)
        }
    }

    func testNamesAreLimitedInCharactersNotBytes() throws {
        let han = String(repeating: "漢", count: 100) + ".md", accents = String(repeating: "é", count: 200)
        let longest = String(repeating: "漢", count: 255), numbered = String(repeating: "漢", count: 253)
        XCTAssertEqual(try unpackedTexts([(han, "a"), (accents, "b"), (longest + "/x.md", "c"), (numbered, "d"), (numbered, "e")]),
                       [han: "a", accents: "b", longest + "/x.md": "c", numbered: "d", numbered + " 2": "e"])
        let tooLong = String(repeating: "漢", count: 254)
        let error = try assertRefused(ZipFixture(files: [page()] + [tooLong, tooLong].map { .init(name: Array($0.utf8), data: Data()) }))
        XCTAssertTrue(((error as? LocalizedError)?.errorDescription ?? "").contains("too long"), "\(String(describing: error))")
    }

    func testPathsAreLimitedByTheirRealLengthOnDisk() throws {
        let temporary = try XCTUnwrap(realpath(fm.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let base = strlen(temporary) + "/noteit-import-".utf8.count + UUID().uuidString.utf8.count
        func name(_ bytes: Int) -> String {
            var characters = Array(repeating: Character("p"), count: bytes)
            for slash in stride(from: 200, to: bytes - 1, by: 201) { characters[slash] = "/" }
            return String(characters)
        }
        let longest = name(Int(PATH_MAX) - 1 - base - 1)
        XCTAssertEqual(longest.utf8.count, Int(PATH_MAX) - 2 - base)
        let error = try assertRefused(ZipFixture(files: [page(), .init(name: Array((longest + "x").utf8), data: Data())]))
        XCTAssertTrue(((error as? LocalizedError)?.errorDescription ?? "").contains("too long"), "\(String(describing: error))")
        let url = try save(ZipFixture(files: [.init(name: Array(longest.utf8), data: Data())]), as: "Longest.zip")
        var limits = ZipLimits.standard
        let folder = try XCTUnwrap(try MarkdownImporter.unzip(url, within: &limits))
        XCTAssertNoThrow(try fm.removeItem(at: folder))
    }

    func testDeepPathsUnpackQuickly() throws {
        let folder = (0..<99).map { "f\($0)/" }.joined()
        let longest = String(repeating: "d/", count: 255) + String(repeating: "e", count: 255)
        let url = try save(ZipFixture(files: (0..<500).map { .init(name: Array("\(folder)\($0).md".utf8), data: Data()) }
                                        + [.init(name: Array(longest.utf8), data: Data())]),
                           as: "Deep.zip")
        var limits = ZipLimits.standard
        let start = Date()
        let result = try XCTUnwrap(try MarkdownImporter.unpack(url, within: &limits))
        XCTAssertLessThan(Date().timeIntervalSince(start), TestTiming.scaled(2))
        XCTAssertEqual(result.fileSizes.count, 501)
        XCTAssertNotNil(result.fileSizes[longest])
        XCTAssertNoThrow(try fm.removeItem(at: result.folder))
    }

    func testCancelledUnpackLeavesNothing() async throws {
        let url = try save(ZipFixture(files: [page(), .init(name: Array("big.bin".utf8), data: Data(count: 5_000_000), deflate: true)]),
                           as: "Cancel.zip")
        let before = leftovers()
        let task = Task.detached { () throws -> URL? in
            while !Task.isCancelled { await Task.yield() }
            var limits = ZipLimits.standard
            return try MarkdownImporter.unzip(url, within: &limits)
        }
        task.cancel()
        do {
            let folder = try await task.value
            XCTFail("unpacked to \(folder?.path ?? "nil")")
            if let folder { try? fm.removeItem(at: folder) }
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(leftovers().subtracting(before), [])
    }

    /// Unpacks `files` and returns each written file's path inside the folder with its text.
    private func unpackedTexts(_ files: [(String, String)]) throws -> [String: String] {
        let url = try save(ZipFixture(files: files.map { .init(name: Array($0.0.utf8), data: Data($0.1.utf8)) }),
                           as: "Clash-\(UUID().uuidString).zip")
        var limits = ZipLimits.standard
        let folder = try XCTUnwrap(try MarkdownImporter.unzip(url, within: &limits))
        defer { try? fm.removeItem(at: folder) }
        var texts: [String: String] = [:]
        let enumerator = try XCTUnwrap(fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = String(file.resolvingSymlinksInPath().path.dropFirst(folder.resolvingSymlinksInPath().path.count + 1))
            texts[path.precomposedStringWithCanonicalMapping] = try String(contentsOf: file, encoding: .utf8)
        }
        return texts
    }

    func testNamesDifferingOnlyInCaseAreBothKept() throws {
        XCTAssertEqual(try unpackedTexts([("Notes/README.md", "upper"), ("Notes/readme.md", "lower")]),
                       ["Notes/README.md": "upper", "Notes/readme 2.md": "lower"])
    }

    func testNFCAndNFDNamesAreBothKept() throws {
        let nfc = "Café.md".precomposedStringWithCanonicalMapping
        let nfd = "Café.md".decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        XCTAssertEqual(try unpackedTexts([(nfc, "one"), (nfd, "two")]), [nfc: "one", "Café 2.md": "two"])
    }

    func testRepeatedNamesAreBothKept() throws {
        XCTAssertEqual(try unpackedTexts([("Page.md", "first"), ("Page.md", "second"), ("Page 2.md", "third"), ("LICENSE", "a"), ("LICENSE", "b")]),
                       ["Page.md": "first", "Page 3.md": "second", "Page 2.md": "third", "LICENSE": "a", "LICENSE 2": "b"])
    }

    func testNumberedNamesNeverTakeANameALaterEntryHas() throws {
        XCTAssertEqual(try unpackedTexts([("Page.md", "first"), ("page.md", "second"), ("PAGE 2.md", "real two"),
                                          ("doc", "file"), ("doc/x.md", "renamed folder"), ("Doc 2/y.md", "real folder"),
                                          ("sub/n.md", "1"), ("sub/n.md", "2"), ("SUB/N 2.md", "real n2")]),
                       ["Page.md": "first", "page 3.md": "second", "PAGE 2.md": "real two",
                        "doc": "file", "doc 3/x.md": "renamed folder", "Doc 2/y.md": "real folder",
                        "sub/n.md": "1", "sub/n 3.md": "2", "sub/N 2.md": "real n2"])
    }

    func testReservedNamesAreComparedAsTheVolumeComparesThem() throws {
        XCTAssertEqual(try unpackedTexts([("Strasse.md", "1"), ("Straße.md", "2"), ("Strasse 2.md", "3")]),
                       ["Strasse.md": "1", "Straße 3.md": "2", "Strasse 2.md": "3"])
    }

    func testCaseVariantsOfARenamedFolderShareIt() throws {
        XCTAssertEqual(try unpackedTexts([("a", "file"), ("A/x.md", "x"), ("a/y.md", "y")]),
                       ["a": "file", "A 2/x.md": "x", "A 2/y.md": "y"])
        XCTAssertEqual(try unpackedTexts([("a", "file"), ("a", "file two"), ("a/x.md", "x"), ("A/y.md", "y"), ("a/", "")]),
                       ["a": "file", "a 2": "file two", "a 3/x.md": "x", "a 3/y.md": "y"])
    }

    func testFileAndFolderWithTheSameNameAreBothKept() throws {
        XCTAssertEqual(try unpackedTexts([("Doc", "file"), ("doc/inner.md", "in folder"), ("doc/more.md", "also"),
                                          ("Folder/x.md", "x"), ("folder", "file after folder"), ("Folder/", "")]),
                       ["Doc": "file", "doc 2/inner.md": "in folder", "doc 2/more.md": "also",
                        "Folder/x.md": "x", "folder 2": "file after folder"])
    }

    func testManyRepeatedNamesUnpackWithoutRetryingEveryNumber() throws {
        let count = 5_000
        let url = try save(ZipFixture(files: (0..<count).map { _ in .init(name: Array("a.md".utf8), data: Data()) }
                                        + (0..<count).map { _ in .init(name: Array("d/x".utf8), data: Data()) }),
                           as: "Many.zip")
        var limits = ZipLimits.standard
        let start = Date()
        let result = try XCTUnwrap(try MarkdownImporter.unpack(url, within: &limits))
        defer { try? fm.removeItem(at: result.folder) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        XCTAssertEqual(result.renamed, 2 * (count - 1))
        XCTAssertTrue(fm.fileExists(atPath: result.folder.appendingPathComponent("a \(count).md").path))
        XCTAssertTrue(fm.fileExists(atPath: result.folder.appendingPathComponent("d/x \(count)").path))
    }

    func testRenamedEntriesAreCountedInTheReport() async throws {
        let outer = try save(ZipFixture(files: [page("# Page\nOne"), page("# Page\nTwo"),
                                                .init(name: Array("page \(pageID).MD".utf8), data: Data("# Page\nThree".utf8))]),
                             as: "Twice.zip")
        let report = try await NotionImporter.importExport(outer, into: makeStore())
        XCTAssertEqual(report.notesImported, 3)
        XCTAssertEqual(report.filesRenamed, 2)
        XCTAssertTrue(report.summary.contains("2 files in the archive were renamed"), report.summary)
    }

    func testDittoArchiveWithSwedishNamesUnpacks() throws {
        let folder = base.appendingPathComponent("Källa/Möte å ä ö", isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("Bilder ö"), withIntermediateDirectories: true)
        try Data("# Möte\nÅ ä ö".utf8).write(to: folder.appendingPathComponent("Anteckning ä.md"))
        try Data(repeating: 65, count: 300_000).write(to: folder.appendingPathComponent("Bilder ö/Bild å.bin"))
        let zip = base.appendingPathComponent("Svenska.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        var limits = ZipLimits.standard
        let unpacked = try XCTUnwrap(try MarkdownImporter.unzip(zip, within: &limits))
        defer { try? fm.removeItem(at: unpacked) }
        let root = unpacked.appendingPathComponent("Möte å ä ö")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Anteckning ä.md"), encoding: .utf8), "# Möte\nÅ ä ö")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Bilder ö/Bild å.bin")).count, 300_000)
        let names = try fm.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.allSatisfy { $0 == $0.precomposedStringWithCanonicalMapping }, "\(names)")
    }

    func testZip64ArchiveImports() async throws {
        let outer = try save(ZipFixture(files: [
            page("# Wide\nZip64 sizes"),
            .init(name: Array("Other \(pageID.replacingOccurrences(of: "1", with: "2")).md".utf8),
                  data: Data(("# Other\n" + String(repeating: "text ", count: 20_000)).utf8), deflate: true),
        ], zip64: true, zip64Fields: true), as: "Wide.zip")
        let totals = try XCTUnwrap(MarkdownImporter.zipTotals(outer))
        XCTAssertEqual(totals.entries, 2)
        let report = try await NotionImporter.importExport(outer, into: makeStore())
        XCTAssertEqual(report.notesImported, 2)
    }
}
