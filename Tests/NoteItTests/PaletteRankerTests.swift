import XCTest
@testable import NoteIt

final class PaletteRankerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func note(
        _ title: String,
        minutesAgo: Double = 0,
        notebook: UUID? = nil,
        pinned: Bool = false,
        id: UUID = UUID()
    ) -> NoteMeta {
        let date = base.addingTimeInterval(-minutesAgo * 60)
        return NoteMeta(id: id, notebookID: notebook, title: title, preview: "", isPinned: pinned,
                        createdAt: date, updatedAt: date, tags: [])
    }

    private func notebook(_ name: String, symbol: String = "folder", id: UUID = UUID()) -> Notebook {
        Notebook(id: id, name: name, symbol: symbol, colorHex: "#000000", sortIndex: 0)
    }

    private func command(_ id: String, _ title: String, keywords: [String] = [], shortcut: String? = nil) -> PaletteCommandInfo {
        PaletteCommandInfo(id: id, title: title, symbol: "gear", shortcut: shortcut, keywords: keywords)
    }

    private func ranked(
        _ query: String,
        notes: [NoteMeta] = [],
        notebooks: [Notebook] = [],
        commands: [PaletteCommandInfo] = [],
        bodyMatches: [UUID: Double] = [:],
        limit: Int = 50
    ) -> [PaletteItem] {
        PaletteRanker.items(query: query, notes: notes, notebooks: notebooks, commands: commands,
                            bodyMatches: bodyMatches, limit: limit)
    }

    // MARK: - parse

    func testParseCommandPrefixWithSpaces() {
        let parsed = PaletteRanker.parse("   >  new note  ")
        XCTAssertEqual(parsed.mode, .commands)
        XCTAssertEqual(parsed.text, "new note")
        XCTAssertEqual(PaletteRanker.parse(">").mode, .commands)
        XCTAssertEqual(PaletteRanker.parse(">").text, "")
    }

    func testParseEverythingTrimsText() {
        let parsed = PaletteRanker.parse("  grocery list ")
        XCTAssertEqual(parsed.mode, .everything)
        XCTAssertEqual(parsed.text, "grocery list")
        XCTAssertEqual(PaletteRanker.parse("a > b").mode, .everything)
    }

    // MARK: - Commands mode

    func testCommandsModeEmptyListsAllCommandsSortedByTitle() {
        let commands = [command("c", "Toggle Sidebar"), command("a", "New Note", shortcut: "⌘N"), command("b", "Export…")]
        let items = ranked(">", notes: [note("New Note ideas")], commands: commands)
        XCTAssertEqual(items.map(\.id), ["command:b", "command:a", "command:c"])
        XCTAssertEqual(items[1].shortcut, "⌘N")
        XCTAssertNil(items[1].subtitle)
        XCTAssertEqual(items[1].kind, .command("a"))
    }

    func testCommandsModeOnlyReturnsCommandsByScore() {
        let commands = [command("sidebar", "Toggle Sidebar"), command("new", "New Note"), command("export", "Export")]
        let items = ranked("> new", notes: [note("New")], notebooks: [notebook("New")], commands: commands)
        XCTAssertEqual(items.map(\.id), ["command:new"])
        XCTAssertEqual(items[0].matchedIndices, [0, 1, 2])
    }

    func testKeywordsOnlyMatchHasNoHighlightsAndScoresBelowTitleMatch() {
        let commands = [
            command("prefs", "Settings…", keywords: ["preferences"]),
            command("print", "Print Preview")
        ]
        let items = ranked("> pre", commands: commands)
        XCTAssertEqual(items.map(\.id), ["command:print", "command:prefs"])
        XCTAssertEqual(items[1].matchedIndices, [])
        XCTAssertFalse(items[0].matchedIndices.isEmpty)
    }

    // MARK: - Everything mode, empty

    func testEverythingEmptyShowsTenMostRecentNotes() {
        var notes: [NoteMeta] = []
        for i in 0..<15 {
            notes.append(note("Note \(i)", minutesAgo: Double(i)))
        }
        let items = ranked("  ", notes: notes.shuffled(), notebooks: [notebook("Note")], commands: [command("n", "Note")])
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items.map(\.title), (0..<10).map { "Note \($0)" })
        XCTAssertFalse(items.contains { $0.id == "create" })
    }

    // MARK: - Everything mode, text

    func testNoteItemFields() {
        let work = notebook("Work")
        let pinnedID = UUID()
        let notes = [
            note("Plan A", notebook: work.id, pinned: true, id: pinnedID),
            note("Plan B", minutesAgo: 1)
        ]
        let items = ranked("plan", notes: notes, notebooks: [work])
        XCTAssertEqual(items[0].id, "note:\(pinnedID.uuidString)")
        XCTAssertEqual(items[0].kind, .note(pinnedID))
        XCTAssertEqual(items[0].subtitle, "Work")
        XCTAssertEqual(items[0].symbol, "pin.fill")
        XCTAssertEqual(items[0].matchedIndices, [0, 1, 2, 3])
        XCTAssertNil(items[1].subtitle)
        XCTAssertEqual(items[1].symbol, "doc.text")
    }

    func testNotebookItemFields() {
        let work = notebook("Work", symbol: "briefcase")
        let solo = notebook("Workouts", symbol: "figure.run")
        let notes = [note("a", notebook: work.id), note("b", notebook: work.id), note("c", notebook: solo.id)]
        let items = ranked("work", notes: notes, notebooks: [work, solo])
        let notebooks = items.filter { if case .notebook = $0.kind { return true } else { return false } }
        XCTAssertEqual(notebooks.map(\.id), ["notebook:\(work.id.uuidString)", "notebook:\(solo.id.uuidString)"])
        XCTAssertEqual(notebooks.map(\.subtitle), ["2 notes", "1 note"])
        XCTAssertEqual(notebooks.map(\.symbol), ["briefcase", "figure.run"])
        XCTAssertEqual(notebooks[0].matchedIndices, [0, 1, 2, 3])
    }

    func testEmptyNotebookSubtitle() {
        let items = ranked("arch", notebooks: [notebook("Archive")])
        XCTAssertEqual(items.first?.subtitle, "0 notes")
    }

    func testEmptyTitlesUseTheAppLabel() {
        let untitled = note("")
        let items = ranked("new no", notes: [untitled])
        XCTAssertEqual(items.first?.id, "note:\(untitled.id.uuidString)")
        XCTAssertEqual(items.first?.title, "New Note")
        XCTAssertEqual(items.first?.title, untitled.displayTitle)
        XCTAssertEqual(items.first?.matchedIndices, [0, 1, 2, 4, 5])
        XCTAssertEqual(ranked("new note", notes: [untitled]).last?.id, "create")
    }

    func testBodyMatchesRankAfterTitleMatches() {
        let bodyOnly = note("Shopping", minutesAgo: 0)
        let weakTitle = note("Some very long title that barely matches recipes later on", minutesAgo: 5)
        let strongTitle = note("Recipes 2026", minutesAgo: 10)
        let ignored = note("Unrelated", minutesAgo: 0)
        let items = ranked("recipes", notes: [bodyOnly, weakTitle, strongTitle, ignored], bodyMatches: [bodyOnly.id: 1])
        let ids = items.map(\.id)
        XCTAssertEqual(ids, ["note:\(strongTitle.id.uuidString)", "note:\(weakTitle.id.uuidString)",
                             "note:\(bodyOnly.id.uuidString)", "create"])
        XCTAssertEqual(items[2].matchedIndices, [])
    }

    func testMergesKindsByScore() {
        let journal = notebook("Journal")
        let items = ranked(
            "journal",
            notes: [note("My journal entry")],
            notebooks: [journal],
            commands: [command("j", "Open Journal Settings")]
        )
        XCTAssertEqual(items.first?.id, "notebook:\(journal.id.uuidString)")
        XCTAssertEqual(items.count, 4)
    }

    func testCreateItemAppendedWithTrimmedText() {
        let items = ranked("  Buy milk  ", notes: [note("Groceries")])
        XCTAssertEqual(items.last, PaletteItem(
            id: "create",
            kind: .createNote("Buy milk"),
            title: "New Note “Buy milk”",
            subtitle: nil,
            symbol: "square.and.pencil",
            shortcut: nil,
            matchedIndices: []
        ))
    }

    func testCreateItemOmittedWhenATitleEqualsTextIgnoringCase() {
        let items = ranked("CAFÉ", notes: [note("Café"), note("Café notes")])
        XCTAssertFalse(items.contains { $0.id == "create" })
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(ranked("plan", notes: [note("  Plan ")]).contains { $0.id == "create" })
    }

    func testCreateItemKeptWhenOnlyAccentsDiffer() {
        let resume = note("Résumé")
        let items = ranked("Resume", notes: [resume])
        XCTAssertEqual(items.map(\.id), ["note:\(resume.id.uuidString)", "create"])
        XCTAssertEqual(items.last?.kind, .createNote("Resume"))
        XCTAssertEqual(ranked("cafe", notes: [note("Café")]).last?.id, "create")
    }

    func testExactTitleRanksFirstAcrossKinds() {
        let exact = note("Plan", minutesAgo: 60)
        let items = ranked(
            "plan",
            notes: [note("Plans"), note("Project plan"), note("Planning"), exact],
            notebooks: [notebook("Plans and ideas")],
            commands: [command("plan", "Plan Trip")]
        )
        XCTAssertEqual(items.first?.id, "note:\(exact.id.uuidString)")
    }

    func testCreateItemPresentForPartialTitle() {
        let items = ranked("caf", notes: [note("Café")])
        XCTAssertEqual(items.last?.id, "create")
    }

    func testLimitRespectedBeforeCreateItem() {
        var notes: [NoteMeta] = []
        for i in 0..<60 {
            notes.append(note("Meeting \(i)", minutesAgo: Double(i)))
        }
        let items = ranked("meeting", notes: notes, limit: 5)
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.last?.id, "create")
        XCTAssertEqual(ranked("meeting", notes: notes).count, 51)
    }

    func testTieBreakNotesThenNotebooksThenCommandsThenRecencyThenTitle() {
        let older = note("Plan", minutesAgo: 30)
        let newer = note("Plan", minutesAgo: 1)
        let planBook = notebook("Plan")
        let items = ranked(
            "plan",
            notes: [older, newer],
            notebooks: [planBook],
            commands: [command("plan", "Plan")]
        )
        let ids = items.map(\.id)
        XCTAssertEqual(ids, ["note:\(newer.id.uuidString)", "note:\(older.id.uuidString)",
                             "notebook:\(planBook.id.uuidString)", "command:plan"])
    }

    func testTieBreakByTitleWhenScoresAndDatesMatch() {
        let b = note("Plan b")
        let a = note("Plan a")
        let items = ranked("plan", notes: [b, a])
        XCTAssertEqual(items.map(\.title), ["Plan a", "Plan b", "New Note “plan”"])
    }

    func testIDsAreUnique() {
        let book = notebook("Ideas")
        let items = ranked("ideas", notes: [note("Ideas 1"), note("Ideas 2")], notebooks: [book],
                           commands: [command("ideas", "Show Ideas")])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    func testWarmRankingOfManyNonASCIITitlesIsFast() {
        let words = ["会議メモ", "プロジェクト計画", "週次レビュー", "Résumé", "café", "naïve", "Ærøskøbing", "Straße", "Ångström", "señor"]
        var notes: [NoteMeta] = []
        for i in 0..<5000 {
            var title = "\(words[i % words.count]) \(words[(i / 3) % words.count]) – "
            title += "\(words[(i / 7) % words.count]) \(words[(i / 11) % words.count]) №\(i) "
            title += "\(words[(i / 13) % words.count]) déjà vu \(words[(i / 17) % words.count])"
            notes.append(note(title, minutesAgo: Double(i)))
        }
        _ = ranked("cafe 計画", notes: notes)
        let start = Date()
        let items = ranked("cafe 計画", notes: notes)
        let elapsed = Date().timeIntervalSince(start)
        print("Palette warm ranking of \(notes.count) titles: \(Int(elapsed * 1000)) ms")
        XCTAssertEqual(items.count, 51)
        XCTAssertLessThan(elapsed, 0.5)
    }

    // MARK: - Smart folders and tags

    func testSmartFolderRanksByName() {
        let folder = SmartFolder(name: "Open tasks", query: "is:todo", sortIndex: 0)
        let items = PaletteRanker.items(query: "open tas", notes: [note("Groceries")], notebooks: [], commands: [command("x", "Open Quickly…")],
                                        bodyMatches: [:], smartFolders: [folder])
        XCTAssertEqual(items.first?.kind, .smartFolder(folder.id))
        XCTAssertEqual(items.first?.subtitle, "Smart Folder · is:todo")
        XCTAssertFalse(PaletteRanker.items(query: "todo", notes: [], notebooks: [], commands: [], bodyMatches: [:],
                                           smartFolders: [folder]).contains { $0.kind == .smartFolder(folder.id) })
    }

    func testTagRanksByPathWithCount() {
        let items = PaletteRanker.items(query: "work/ac", notes: [], notebooks: [], commands: [], bodyMatches: [:],
                                        tags: [("work", 3), ("work/acme", 1), ("home", 2)])
        XCTAssertEqual(items.first?.kind, .tag("work/acme"))
        XCTAssertEqual(items.first?.title, "#work/acme")
        XCTAssertEqual(items.first?.subtitle, "1 note")
        XCTAssertFalse(items.contains { $0.kind == .tag("home") })
    }
}
