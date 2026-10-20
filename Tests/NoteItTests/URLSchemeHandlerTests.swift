import AppKit
import XCTest
import NoteItCore
@testable import NoteIt

@MainActor
final class URLSchemeHandlerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default

    private var questions: [String] = []
    private var notices: [String] = []
    private var callbacks: [URL] = []
    private var shown: [UUID] = []
    private var saved: [String?] = []
    private var searches: [String] = []
    private var answer = true
    private var dailyAvailable = false

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-urlscheme-\(UUID().uuidString)", isDirectory: true)
        suiteName = "noteit-urlscheme-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: root)
    }

    private func makeHandler(registry: URLRouteRegistry? = nil) -> (URLSchemeHandler, NoteStore) {
        let store = NoteStore(location: LibraryLocation(url: root.appendingPathComponent("lib"), seedsFreshLibrary: false))
        let staged = StagedUploads(directory: root.appendingPathComponent("staged"))
        let service = AutomationService(store: store, defaults: defaults, staged: staged, isLoading: { false })
        let environment = URLSchemeHandler.Environment(
            confirm: { [unowned self] in questions.append($0); return answer },
            notify: { [unowned self] in notices.append($0) },
            openCallback: { [unowned self] in callbacks.append($0) },
            showNote: { [unowned self] id, _ in shown.append(id) },
            showSaved: { [unowned self] _, notebook in saved.append(notebook) },
            showSearch: { [unowned self] in searches.append($0) },
            showSettings: { _ in },
            dailyAvailable: { [unowned self] in dailyAvailable }
        )
        return (URLSchemeHandler(service: service, registry: registry ?? URLRouteRegistry(), defaults: defaults, environment: environment), store)
    }

    private func open(_ handler: URLSchemeHandler, _ string: String) async {
        await handler.handle(URL(string: string)!)
    }

    private func text(of id: UUID, in store: NoteStore) -> String {
        store.body(for: id).string
    }

    func testNewAsksUnlessSettingOn() async {
        let (handler, store) = makeHandler()
        _ = store.createNotebook(name: "Inbox", symbol: "tray", colorHex: "#0A84FF")
        await open(handler, "noteit://new?title=Hi&text=There")
        XCTAssertEqual(questions, ["A link wants to create a note in “Inbox”."])
        XCTAssertEqual(store.notes.filter { $0.title == "Hi" }.count, 1)
        XCTAssertEqual(saved, ["Inbox"])

        defaults.set(true, forKey: PrefKey.urlSchemeChangesWithoutAsking)
        await open(handler, "noteit://new?title=Again&open=1")
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(saved.count, 1)
    }

    func testAppendAsksUnlessSettingOn() async throws {
        let (handler, store) = makeHandler()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Plan\nfirst")).id
        await open(handler, "noteit://append?title=plan&text=second")
        XCTAssertEqual(questions, ["A link wants to add text to “Plan”."])
        XCTAssertTrue(text(of: id, in: store).hasSuffix("second"))

        defaults.set(true, forKey: PrefKey.urlSchemeChangesWithoutAsking)
        await open(handler, "noteit://append?id=\(id.uuidString)&text=third")
        XCTAssertEqual(questions.count, 1)
        XCTAssertTrue(text(of: id, in: store).hasSuffix("third"))
    }

    func testDontAllowCallsXCancel() async {
        let (handler, store) = makeHandler()
        answer = false
        await open(handler, "noteit://x-callback-url/new?text=x&x-success=app://ok&x-cancel=app://cancel")
        XCTAssertEqual(callbacks, [URL(string: "app://cancel")!])
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testShareInboxNeverAsks() async {
        let (handler, _) = makeHandler()
        await open(handler, "noteit://new?inbox=\(UUID().uuidString)")
        XCTAssertTrue(questions.isEmpty)
    }

    func testOpenAndSearchNeverAsk() async {
        let (handler, store) = makeHandler()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Plan")).id
        await open(handler, "noteit://open?id=\(id.uuidString)")
        await open(handler, "noteit://note/\(id.uuidString)?heading=Later")
        await open(handler, "noteit://open?title=Nothing%20here")
        await open(handler, "noteit://search?q=milk")
        await open(handler, "noteit://settings?tab=integrations")
        XCTAssertTrue(questions.isEmpty)
        XCTAssertEqual(shown, [id, id])
        XCTAssertEqual(searches, ["Nothing here", "milk"])
    }

    func testDailyHostsUnavailableWhileGateOff() async {
        let (handler, _) = makeHandler()
        await open(handler, "noteit://daily")
        await open(handler, "noteit://x-callback-url/append?daily=today&text=x&x-error=app://err")
        XCTAssertEqual(notices, ["Daily notes aren't available in this version."])
        XCTAssertTrue(questions.isEmpty)
        let error = URLComponents(url: try! XCTUnwrap(callbacks.first), resolvingAgainstBaseURL: false)
        XCTAssertEqual(error?.queryItems?.first { $0.name == "errorCode" }?.value, "not_implemented")
    }

    func testHTTPSuccessCallbackHasNoIdOrTitle() async {
        let (handler, _) = makeHandler()
        defaults.set(true, forKey: PrefKey.urlSchemeChangesWithoutAsking)
        await open(handler, "noteit://x-callback-url/new?text=x&x-success=https://example.com/ok")
        await open(handler, "noteit://x-callback-url/new?title=T&x-success=app://ok")
        XCTAssertEqual(questions, ["A link wants to create a note in “NoteIt”."], "a web link asks even with the setting on")
        XCTAssertEqual(callbacks.count, 2)
        XCTAssertEqual(callbacks[0], URL(string: "https://example.com/ok"))
        let items = URLComponents(url: callbacks[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["id", "title", "url"])
        XCTAssertEqual(items[1].value, "T")
    }

    func testHTTPErrorCallbackHasNoMessage() async {
        let (handler, _) = makeHandler()
        await open(handler, "noteit://x-callback-url/open?id=\(UUID().uuidString)&x-error=https://example.com/err")
        await open(handler, "noteit://x-callback-url/open?id=\(UUID().uuidString)&x-error=app://err")
        await open(handler, "noteit://x-callback-url/append?id=\(UUID().uuidString)&text=x&x-error=https://example.com/err")
        await open(handler, "noteit://x-callback-url/append?id=\(UUID().uuidString)&text=x&x-error=app://err")
        XCTAssertEqual(callbacks.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? [] },
                       [[URLQueryItem(name: "errorCode", value: "not_found"), URLQueryItem(name: "errorMessage", value: "No note with that id.")],
                        [URLQueryItem(name: "errorCode", value: "not_changed")],
                        [URLQueryItem(name: "errorCode", value: "not_found"), URLQueryItem(name: "errorMessage", value: "No note with that id.")]])
        XCTAssertEqual(questions, ["A link wants to add text to a note."], "only the web link asks")
        XCTAssertEqual(notices, ["No note with that id.", "No note with that id."], "web links tell the user, not the page")
    }

    func testAppendToMissingTitleSaysTitle() async {
        let (handler, _) = makeHandler()
        await open(handler, "noteit://x-callback-url/append?title=Nothing&text=x&x-error=app://err")
        let items = URLComponents(url: callbacks[0], resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "errorCode" }?.value, "not_found")
        XCTAssertEqual(items.first { $0.name == "errorMessage" }?.value, "No note with that title.")
    }

    func testLockedNoteRefusesAppendWithoutAsking() async {
        let (handler, store) = makeHandler()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Secret")).id
        store.notes[store.noteIndex(id)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        await open(handler, "noteit://append?id=\(id.uuidString)&text=x")
        await open(handler, "noteit://x-callback-url/append?id=\(id.uuidString)&text=x&x-error=app://err")
        XCTAssertTrue(questions.isEmpty)
        XCTAssertEqual(notices, ["That note is locked."])
        XCTAssertEqual(URLComponents(url: callbacks[0], resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "note_locked")

        await open(handler, "noteit://x-callback-url/append?id=\(id.uuidString)&text=x&x-error=https://example.com/err")
        XCTAssertEqual(questions, ["A link wants to add text to a note."], "a web link asks, as if the note could be changed")
        XCTAssertEqual(callbacks.last, URL(string: "https://example.com/err?errorCode=not_changed"))
        XCTAssertEqual(text(of: id, in: store), "Secret")
    }

    /// What a web page sees must not depend on whether the note or notebook exists, or is locked.
    func testWebCallbacksCantTellWhetherNotesExist() async throws {
        let (handler, store) = makeHandler()
        _ = store.createNotebook(name: "Inbox", symbol: "tray", colorHex: "#0A84FF")
        let plain = store.createNote(in: nil, initial: NSAttributedString(string: "Plan")).id
        let locked = store.createNote(in: nil, initial: NSAttributedString(string: "Secret")).id
        store.notes[store.noteIndex(locked)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        let deleted = store.createNote(in: nil, initial: NSAttributedString(string: "Gone")).id
        store.moveToRecentlyDeleted([deleted])
        let web = "&x-error=https://example.com/err&x-cancel=https://example.com/cancel&x-success=https://example.com/ok"
        let failing = ["append?id=\(UUID().uuidString)&text=x", "append?id=\(locked.uuidString)&text=x",
                       "append?id=\(deleted.uuidString)&text=x", "append?title=Nothing&text=x", "append?title=Secret&text=x",
                       "new?notebook=Nowhere&text=x", "new?notebook=\(UUID().uuidString)&text=x"]
        for (allow, withoutAsking) in [(false, false), (true, false), (false, true), (true, true)] {
            answer = allow
            defaults.set(withoutAsking, forKey: PrefKey.urlSchemeChangesWithoutAsking)
            for link in failing + ["append?id=\(plain.uuidString)&text=x", "new?notebook=Inbox&text=x"] {
                questions = []
                callbacks = []
                notices = []
                await open(handler, "noteit://x-callback-url/" + link + web)
                XCTAssertEqual(questions.count, 1, link)
                let expected = !allow ? "https://example.com/cancel"
                    : failing.contains(link) ? "https://example.com/err?errorCode=not_changed" : "https://example.com/ok"
                XCTAssertEqual(callbacks, [URL(string: expected)!], link)
                XCTAssertEqual(notices.count, allow && failing.contains(link) ? 1 : 0, "after Allow the user sees why: \(link)")
            }
        }
    }

    func testConcealedFailureAfterAllowShowsReason() async {
        let (handler, _) = makeHandler()
        await open(handler, "noteit://x-callback-url/append?title=Nothing&text=x&x-error=https://example.com/err")
        XCTAssertEqual(callbacks, [URL(string: "https://example.com/err?errorCode=not_changed")!])
        XCTAssertEqual(notices, ["No note with that title."])
    }

    /// Links that only show something call a web `x-success` the same way whether or not the note exists.
    func testWebCallbacksCantTellWhetherShownNotesExist() async {
        let (handler, store) = makeHandler()
        let plain = store.createNote(in: nil, initial: NSAttributedString(string: "Plan")).id
        let web = "x-error=https://example.com/err&x-success=https://example.com/ok"
        for id in [plain, UUID()] {
            for link in ["open?id=\(id.uuidString)&", "note/\(id.uuidString)?", "open?title=\(id == plain ? "Plan" : "Nothing")&",
                         "note?title=\(id == plain ? "Plan" : "Nothing")&", "search?q=Plan&"] {
                callbacks = []
                await open(handler, "noteit://x-callback-url/" + link + web)
                XCTAssertEqual(callbacks, [URL(string: "https://example.com/ok")!], link)
            }
        }
        XCTAssertTrue(questions.isEmpty)
        XCTAssertEqual(notices, ["No note with that id.", "No note with that id."], "a missing id is still explained locally")
        XCTAssertEqual(shown, Array(repeating: plain, count: 4))
        XCTAssertEqual(searches, ["Plan", "Nothing", "Nothing", "Plan"])
    }

    func testRegisteredHostDispatches() async {
        let registry = URLRouteRegistry()
        var received: [URL] = []
        registry.register(host: "join") { received.append($0) }
        let (handler, _) = makeHandler(registry: registry)
        await open(handler, "noteit://join/abc#key")
        XCTAssertEqual(received, [URL(string: "noteit://join/abc#key")!])
        XCTAssertTrue(notices.isEmpty)
    }

    func testUnknownHostShowsNotice() async {
        let (handler, _) = makeHandler()
        await open(handler, "noteit://nowhere")
        await open(handler, "noteit://bad_host")
        XCTAssertEqual(notices, ["NoteIt doesn't know this link.", "NoteIt doesn't know this link."])
    }

    func testHeadingLocationFindsHeadingParagraphs() {
        let body = NSMutableAttributedString(string: "Plan\n", attributes: EditorStyle.attributes(for: .title))
        body.append(NSAttributedString(string: "Later\n", attributes: EditorStyle.bodyAttributes))
        body.append(NSAttributedString(string: "Later\n", attributes: EditorStyle.attributes(for: .heading)))
        XCTAssertEqual(URLSchemeHandler.headingLocation("later", in: body), 11)
        XCTAssertNil(URLSchemeHandler.headingLocation("Missing", in: body))
    }

    func testCopyNoteLinkWritesNoteForm() throws {
        let (_, store) = makeHandler()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Plan")).id
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("noteit-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        CopyNoteLink.perform(noteID: id, store: store, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "noteit://note/\(id.uuidString)")
        let rtf = try XCTUnwrap(pasteboard.data(forType: .rtf))
        let linked = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
        XCTAssertEqual(linked.string, "Plan")
        let link = linked.attribute(.link, at: 0, effectiveRange: nil)
        XCTAssertEqual((link as? URL)?.absoluteString ?? link as? String, "noteit://note/\(id.uuidString)")
    }
}
