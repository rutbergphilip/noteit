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

    private func open(_ handler: URLSchemeHandler, _ string: String) {
        handler.handle(URL(string: string)!)
    }

    private func text(of id: UUID, in store: NoteStore) -> String {
        store.body(for: id).string
    }

    func testNewAsksUnlessSettingOn() {
        let (handler, store) = makeHandler()
        _ = store.createNotebook(name: "Inbox", symbol: "tray", colorHex: "#0A84FF")
        open(handler, "noteit://new?title=Hi&text=There")
        XCTAssertEqual(questions, ["A link wants to create a note in “Inbox”."])
        XCTAssertEqual(store.notes.filter { $0.title == "Hi" }.count, 1)
        XCTAssertEqual(saved, ["Inbox"])

        defaults.set(true, forKey: PrefKey.urlSchemeChangesWithoutAsking)
        open(handler, "noteit://new?title=Again&open=1")
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(saved.count, 1)
    }

    func testAppendAsksUnlessSettingOn() throws {
        let (handler, store) = makeHandler()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Plan\nfirst")).id
        open(handler, "noteit://append?title=plan&text=second")
        XCTAssertEqual(questions, ["A link wants to add text to “Plan”."])
        XCTAssertTrue(text(of: id, in: store).hasSuffix("second"))

        defaults.set(true, forKey: PrefKey.urlSchemeChangesWithoutAsking)
        open(handler, "noteit://append?id=\(id.uuidString)&text=third")
        XCTAssertEqual(questions.count, 1)
        XCTAssertTrue(text(of: id, in: store).hasSuffix("third"))
    }

    func testDontAllowCallsXCancel() {
        let (handler, store) = makeHandler()
        answer = false
        open(handler, "noteit://x-callback-url/new?text=x&x-success=app://ok&x-cancel=app://cancel")
        XCTAssertEqual(callbacks, [URL(string: "app://cancel")!])
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testShareInboxNeverAsks() {
        let (handler, _) = makeHandler()
        open(handler, "noteit://new?inbox=\(UUID().uuidString)")
        XCTAssertTrue(questions.isEmpty)
    }

    func testOpenAndSearchNeverAsk() {
        let (handler, store) = makeHandler()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Plan")).id
        open(handler, "noteit://open?id=\(id.uuidString)")
        open(handler, "noteit://note/\(id.uuidString)?heading=Later")
        open(handler, "noteit://open?title=Nothing%20here")
        open(handler, "noteit://search?q=milk")
        open(handler, "noteit://settings?tab=integrations")
        XCTAssertTrue(questions.isEmpty)
        XCTAssertEqual(shown, [id, id])
        XCTAssertEqual(searches, ["Nothing here", "milk"])
    }

    func testDailyHostsUnavailableWhileGateOff() {
        let (handler, _) = makeHandler()
        open(handler, "noteit://daily")
        open(handler, "noteit://x-callback-url/append?daily=today&text=x&x-error=app://err")
        XCTAssertEqual(notices, ["Daily notes aren't available in this version."])
        XCTAssertTrue(questions.isEmpty)
        let error = URLComponents(url: try! XCTUnwrap(callbacks.first), resolvingAgainstBaseURL: false)
        XCTAssertEqual(error?.queryItems?.first { $0.name == "errorCode" }?.value, "not_implemented")
    }

    func testHTTPSuccessCallbackHasNoIdOrTitle() {
        let (handler, _) = makeHandler()
        defaults.set(true, forKey: PrefKey.urlSchemeChangesWithoutAsking)
        open(handler, "noteit://x-callback-url/new?text=x&x-success=https://example.com/ok")
        open(handler, "noteit://x-callback-url/new?title=T&x-success=app://ok")
        XCTAssertEqual(callbacks.count, 2)
        XCTAssertEqual(callbacks[0], URL(string: "https://example.com/ok"))
        let items = URLComponents(url: callbacks[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["id", "title", "url"])
        XCTAssertEqual(items[1].value, "T")
    }

    func testHTTPErrorCallbackHasNoMessage() {
        let (handler, _) = makeHandler()
        open(handler, "noteit://x-callback-url/open?id=\(UUID().uuidString)&x-error=https://example.com/err")
        open(handler, "noteit://x-callback-url/open?id=\(UUID().uuidString)&x-error=app://err")
        XCTAssertEqual(callbacks.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [] },
                       [["errorCode"], ["errorCode", "errorMessage"]])
        XCTAssertTrue(notices.isEmpty)
    }

    func testLockedNoteRefusesAppendWithoutAsking() {
        let (handler, store) = makeHandler()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Secret")).id
        store.notes[store.noteIndex(id)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        open(handler, "noteit://append?id=\(id.uuidString)&text=x")
        XCTAssertTrue(questions.isEmpty)
        XCTAssertEqual(notices, ["That note is locked."])
    }

    func testRegisteredHostDispatches() {
        let registry = URLRouteRegistry()
        var received: [URL] = []
        registry.register(host: "join") { received.append($0) }
        let (handler, _) = makeHandler(registry: registry)
        open(handler, "noteit://join/abc#key")
        XCTAssertEqual(received, [URL(string: "noteit://join/abc#key")!])
        XCTAssertTrue(notices.isEmpty)
    }

    func testUnknownHostShowsNotice() {
        let (handler, _) = makeHandler()
        open(handler, "noteit://nowhere")
        open(handler, "noteit://bad_host")
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
