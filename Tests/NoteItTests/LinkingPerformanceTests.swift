import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

/// Quick checks of the spec §14 targets on synthetic data, with 3× headroom for debug builds (8× on shared CI
/// runners, still under the 10× a quadratic regression costs). The published benchmarks run in surfaces-polish's
/// suite. `NOTEIT_PERF=1` prints the timings.
@MainActor
final class LinkingPerformanceTests: XCTestCase {
    private static let noteCount = 10_000
    private static let linksPerNote = 5
    private static let headroom = ProcessInfo.processInfo.environment["CI"] == nil ? 3.0 : 8.0
    private static let printsTimings = ProcessInfo.processInfo.environment["NOTEIT_PERF"] == "1"

    private var root: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-linkperf-\(UUID().uuidString)", isDirectory: true)
        suiteName = "noteit-linkperf-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        store.preferences = defaults
        store.installLinkIndex()
        return store
    }

    /// Best of `runs`, in milliseconds.
    private func time(_ name: String, runs: Int = 5, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        if Self.printsTimings { print("PERF linking.\(name): \(String(format: "%.2f", best)) ms") }
        return best
    }

    private func assertWithin(_ ms: Double, target: Double, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(ms, target * Self.headroom, "\(name): \(ms) ms, target \(target) ms", file: file, line: line)
    }

    private static let words = ["atlas", "river", "garden", "budget", "meeting", "planning", "travel", "recipe", "design",
                                "review", "summer", "winter", "project", "notes", "ideas", "launch", "draft", "family"]

    private static func title(_ index: Int) -> String {
        "\(words[index % words.count].capitalized) \(words[(index / words.count) % words.count]) \(index)"
    }

    /// 10,000 notes with 50,000 links; 500 of them link to note 0.
    private func syntheticLibrary(_ store: NoteStore) -> [UUID] {
        let ids = (0..<Self.noteCount).map { _ in UUID() }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        store.notes = ids.enumerated().map { index, id in
            NoteMeta(id: id, title: Self.title(index), preview: "", isPinned: false,
                     createdAt: date, updatedAt: date.addingTimeInterval(Double(index)), tags: [])
        }
        let index = store.linkIndex
        for (position, id) in ids.enumerated() {
            let links = (0..<Self.linksPerNote).map { k -> OutgoingLink in
                let target = k == 0 && position > 0 && position <= 500 ? ids[0] : ids[1 + (position * 7 + k * 131) % (ids.count - 1)]
                return OutgoingLink(url: NoteLink.note(id: target, heading: nil).url, text: Self.title(k),
                                    location: k * 40, context: "Some context around the link to \(Self.title(k))")
            }
            index.set(links, for: id)
        }
        return ids
    }

    private func longNote(paragraphs: Int, linkEvery: Int) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for index in 0..<paragraphs {
            let kind: BlockKind = index % 50 == 0 ? .heading : .body
            let line = NSMutableAttributedString(string: "Paragraph \(index) talks about plans and ideas ",
                                                 attributes: EditorStyle.attributes(for: kind))
            if index % linkEvery == 0 {
                var attributes = EditorStyle.bodyAttributes
                attributes[.link] = NoteLink.note(id: UUID(), heading: nil).url
                line.append(NSAttributedString(string: "Atlas", attributes: attributes))
            }
            line.append(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(for: kind)))
            text.append(line)
        }
        return text
    }

    func testSuggestionKeystroke() {
        let store = makeStore()
        let ids = syntheticLibrary(store)
        _ = store.linkCandidates(excluding: nil)
        let ms = time("suggestionKeystroke") {
            let candidates = store.linkCandidates(excluding: ids[1])
            let result = LinkSuggester.suggestions(for: LinkQuery("gard plan"), candidates: candidates, headings: { _ in [] })
            XCTAssertFalse(result.isEmpty)
        }
        assertWithin(ms, target: 8, "suggestion keystroke")
    }

    func testExtractLargeNote() {
        let note = longNote(paragraphs: 1_500, linkEvery: 25)
        XCTAssertGreaterThanOrEqual(note.string.split(separator: " ").count, 10_000)
        let ms = time("extract10kWords") { XCTAssertEqual(LinkExtractor.links(in: note).count, 60) }
        assertWithin(ms, target: 2, "link extraction")
    }

    func testLoadIndexFile() throws {
        let store = makeStore()
        _ = syntheticLibrary(store)
        let url = root.appendingPathComponent(LinkIndex.fileName)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dates = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0.updatedAt) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(store.linkIndex.snapshot(updatedAt: dates)).write(to: url)
        let ms = time("loadIndexFile", runs: 3) { XCTAssertEqual(LinkIndex.readFile(at: url)?.entries.count, Self.noteCount) }
        assertWithin(ms, target: 150, "load link-index.json")
    }

    func testBacklinks500() {
        let store = makeStore()
        let ids = syntheticLibrary(store)
        let ms = time("backlinks500") { XCTAssertEqual(store.backlinks(to: ids[0]).count, 500) }
        assertWithin(ms, target: 16, "500 backlinks")
    }

    func testMentionScan() {
        let folded = (0..<Self.noteCount).map { index in
            TextFold.fold("\(Self.title(index)) and a paragraph about plans, ideas, budgets and the next river trip. " +
                          String(repeating: "More words follow here to make the note longer. ", count: 20))
        }
        let title = TextFold.fold("Garden budget")
        let ms = time("mentionScan", runs: 3) {
            XCTAssertGreaterThan(folded.filter { MentionFinder.mayMention(title, inFolded: $0) }.count, 0)
        }
        assertWithin(ms, target: 200, "unlinked mentions scan")
    }

    func testRename100() async {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: NSAttributedString(string: "Atlas\n", attributes: EditorStyle.bodyAttributes)).id
        for index in 0..<100 {
            let text = NSMutableAttributedString(string: "Source \(index)\nSee ", attributes: EditorStyle.bodyAttributes)
            var attributes = EditorStyle.bodyAttributes
            attributes[.link] = NoteLink.note(id: target, heading: nil).url
            text.append(NSAttributedString(string: "Atlas", attributes: attributes))
            _ = store.createNote(in: nil, initial: text)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = await store.rewriteLinkText(targeting: target, from: "Atlas", to: "Atlas 2")
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if Self.printsTimings { print("PERF linking.rename100: \(String(format: "%.2f", ms)) ms") }
        XCTAssertEqual(result.updated, 100)
        // Disk-bound (100 bodies plus versions written); a regression guard rather than a benchmark.
        assertWithin(ms, target: 3_000, "rename of 100 sources")
    }

    func testOutline5000() {
        let note = longNote(paragraphs: 5_000, linkEvery: 1_000)
        let ms = time("outline5000") { XCTAssertEqual(OutlineExtractor.items(in: note).count, 100) }
        assertWithin(ms, target: 5, "outline of 5,000 paragraphs")
    }

    func testDailyLookup() throws {
        let store = makeStore()
        let notebook = store.createNotebook(name: "Daily Notes", symbol: "calendar", colorHex: Tokens.Hex.notebookBlue)
        defaults.set(notebook.id.uuidString, forKey: PrefKey.dailyNotesNotebookID)
        let calendar = DayKey.dailyCalendar()
        let first = DayKey(year: 2000, month: 1, day: 1).date(calendar: calendar, hour: 12)!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        store.notes = (0..<Self.noteCount).map { index in
            let day = DayKey(calendar.date(byAdding: .day, value: index / 2, to: first)!, calendar: calendar)
            let title = index.isMultiple(of: 2) ? DailyNoteTitle.title(for: day, format: .iso, locale: .current) : Self.title(index)
            return NoteMeta(id: UUID(), notebookID: notebook.id, title: title, preview: "", isPinned: false,
                            createdAt: date, updatedAt: date, tags: [])
        }
        let build = time("dailyIndexBuild", runs: 3) {
            store.dailyNoteIndexCache = nil
            XCTAssertEqual(store.dailyNoteIndex?.byDay.count, Self.noteCount / 2)
        }
        assertWithin(build, target: 20, "cold daily index build")
        var edit = 0
        let rebuild = time("dailyIndexRebuild") {
            edit += 1
            store.notes[1].title = Self.title(1) + " \(edit)"
            XCTAssertEqual(store.dailyNoteIndex?.byDay.count, Self.noteCount / 2)
        }
        assertWithin(rebuild, target: 5, "daily index rebuild after an edit")
        let probe = store.notes[1_000].id
        let lookup = time("dailyLookup") {
            for _ in 0..<1_000 { _ = store.dailyDay(of: probe) }
        }
        assertWithin(lookup, target: 1, "1,000 cached daily lookups")
    }

    func testIndexFileSize() throws {
        let store = makeStore()
        _ = syntheticLibrary(store)
        let dates = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0.updatedAt) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(store.linkIndex.snapshot(updatedAt: dates)).count
        if Self.printsTimings { print("PERF linking.indexFileBytes: \(bytes)") }
        XCTAssertLessThanOrEqual(bytes, 15_000_000)
    }
}
