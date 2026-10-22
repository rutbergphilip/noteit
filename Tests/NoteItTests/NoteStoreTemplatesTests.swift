import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

@MainActor
final class NoteStoreTemplatesTests: XCTestCase {
    private var root: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-templates-\(UUID().uuidString)", isDirectory: true)
        suiteName = "noteit-templates-\(UUID().uuidString)"
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

    private func text(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: EditorStyle.bodyAttributes)
    }

    private func template(_ store: NoteStore, _ string: String) -> UUID {
        let meta = store.createTemplate()
        store.updateBody(meta.id, text(string))
        return meta.id
    }

    func testOldNotebookJSONDecodes() throws {
        let json = ##"{"id":"0B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","name":"Inbox","symbol":"tray","colorHex":"#0A84FF","sortIndex":0}"##
        let notebook = try JSONDecoder().decode(Notebook.self, from: Data(json.utf8))
        XCTAssertNil(notebook.defaultTemplateID)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(notebook)) as? [String: Any])
        XCTAssertNil(encoded["defaultTemplateID"])
    }

    func testNilTemplateLeavesRevisionFieldsUnchanged() {
        var notebook = Notebook(name: "Work", symbol: "briefcase", colorHex: "#0A84FF", sortIndex: 1)
        XCTAssertEqual(NoteStore.revisionFields(notebook), ["notebook", "Work", "briefcase", "#0A84FF", "1"])
        let template = UUID()
        notebook.defaultTemplateID = template
        XCTAssertEqual(NoteStore.revisionFields(notebook).last, "template \(template.uuidString)")
    }

    func testOwnedCodingKeysIncludeDefaultTemplateID() {
        XCTAssertTrue(Notebook.ownedCodingKeys.contains("defaultTemplateID"))
    }

    func testTemplatesNotebookFoundByName() {
        let store = makeStore()
        XCTAssertNil(store.templatesNotebookID(createIfMissing: false))
        let named = store.createNotebook(name: "templates", symbol: "doc", colorHex: Tokens.Hex.notebookBlue)
        XCTAssertEqual(store.templatesNotebookID(createIfMissing: true), named.id)
        XCTAssertEqual(store.notebooks.count, 1)

        let chosen = store.createNotebook(name: "Snippets", symbol: "doc", colorHex: Tokens.Hex.notebookBlue)
        defaults.set(chosen.id.uuidString, forKey: PrefKey.templatesNotebookID)
        XCTAssertEqual(store.templatesNotebookIDIfSet, chosen.id)
    }

    func testCreateFromTemplateDerivesTitleAndTags() throws {
        let store = makeStore()
        let templateID = template(store, "Meeting {{title}}\nNotes #meeting {{cursor}}")
        XCTAssertEqual(store.templates.map(\.id), [templateID])
        XCTAssertEqual(NoteStore.templateName(try XCTUnwrap(store.note(with: templateID))), "Meeting")

        let inbox = store.createNotebook(name: "Inbox", symbol: "tray", colorHex: Tokens.Hex.notebookBlue)
        let meta = try store.createNote(fromTemplate: templateID, title: "Budget", in: inbox.id)
        XCTAssertEqual(meta.title, "Meeting Budget")
        XCTAssertEqual(meta.tags, ["meeting"])
        XCTAssertEqual(meta.notebookID, inbox.id)
        XCTAssertEqual(store.body(for: meta.id).string, "Meeting Budget\nNotes #meeting ")
        XCTAssertEqual(RichTextEditor.pendingCaret.removeValue(forKey: meta.id), ("Meeting Budget\nNotes #meeting " as NSString).length)
        XCTAssertEqual(store.body(for: templateID).string, "Meeting {{title}}\nNotes #meeting {{cursor}}")
    }

    func testDefaultTemplateUsedByNewNote() throws {
        let store = makeStore()
        let templateID = template(store, "Daily standup\nYesterday:")
        var work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        work.defaultTemplateID = templateID
        store.updateNotebook(work)

        store.selection = .notebook(work.id)
        let meta = try XCTUnwrap(store.createNoteInCurrentContext())
        XCTAssertEqual(store.body(for: meta.id).string, "Daily standup\nYesterday:")
        XCTAssertEqual(meta.notebookID, work.id)

        let captured = try XCTUnwrap(store.captureNote(title: "", body: "Shipped", in: work.id))
        XCTAssertEqual(store.body(for: captured.id).string, "Daily standup\nYesterday:\nShipped")

        let linked = try XCTUnwrap(store.createNoteForLink(title: "Retro", from: meta.id))
        XCTAssertEqual(store.body(for: linked.id).string, "Daily standup\nYesterday:")

        store.selection = .allNotes
        XCTAssertEqual(store.body(for: try XCTUnwrap(store.createNoteInCurrentContext()).id).string, "")
    }

    func testMissingDefaultTemplateIsNone() throws {
        let store = makeStore()
        let templateID = template(store, "Standup")
        var work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        work.defaultTemplateID = templateID
        store.updateNotebook(work)
        XCTAssertEqual(store.defaultTemplateID(for: work.id), templateID)

        store.moveToRecentlyDeleted([templateID])
        XCTAssertNil(store.defaultTemplateID(for: work.id))
        store.selection = .notebook(work.id)
        XCTAssertEqual(store.body(for: try XCTUnwrap(store.createNoteInCurrentContext()).id).string, "")

        work.defaultTemplateID = UUID()
        store.updateNotebook(work)
        XCTAssertNil(store.defaultTemplateID(for: work.id))
    }

    func testTemplatesExcludedFromCandidates() async {
        let store = makeStore()
        let templateID = template(store, "Atlas")
        let note = store.createNote(in: nil, initial: text("Atlas")).id
        let source = store.createNote(in: nil, initial: text("Source")).id
        XCTAssertTrue(store.isTemplate(templateID))
        XCTAssertFalse(store.isTemplate(note))
        XCTAssertEqual(store.linkCandidates(excluding: source).map(\.id), [note])
        XCTAssertEqual(store.noteID(forTitle: "Atlas", preferring: nil), note)

        let linking = store.createNote(in: store.templatesNotebookIDIfSet, initial: {
            let body = NSMutableAttributedString(attributedString: text("Linker\n"))
            body.append(NSAttributedString(string: "Atlas", attributes: [.link: NoteLink.note(id: note, heading: nil).url]))
            return body
        }()).id
        XCTAssertTrue(store.isTemplate(linking))
        for _ in 0..<100 where store.outgoingLinks(from: linking).isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.outgoingLinks(from: linking).isEmpty)
        XCTAssertTrue(store.backlinks(to: note).isEmpty)
    }

    func testInsertTemplateDropsTitleParagraph() {
        let expansion = TemplateExpansion(text: text("Meeting\nAgenda: "), caret: 16)
        let (dropped, caret) = NoteItTextView.templateInsertion(expansion, keepsTitle: false)
        XCTAssertEqual(dropped.string, "Agenda: ")
        XCTAssertEqual(caret, 8)
        XCTAssertEqual(NoteItTextView.templateInsertion(expansion, keepsTitle: true).0.string, "Meeting\nAgenda: ")
        XCTAssertEqual(NoteItTextView.templateInsertion(TemplateExpansion(text: text("One line"), caret: nil), keepsTitle: false).0.string, "One line")
    }
}
