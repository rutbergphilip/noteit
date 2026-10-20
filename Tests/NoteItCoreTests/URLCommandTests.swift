import Foundation
import NoteItCore
import XCTest

final class URLCommandTests: XCTestCase {
    private let id = UUID(uuidString: "6F1C3A2E-9B4D-4E7A-8C21-0D5E7F9A1B3C")!

    private func parse(_ raw: String, file: StaticString = #filePath, line: UInt = #line) throws -> (URLCommand, XCallback) {
        let url = try XCTUnwrap(URL(string: raw), file: file, line: line)
        return try URLCommand.parse(url).get()
    }

    private func command(_ raw: String, file: StaticString = #filePath, line: UInt = #line) throws -> URLCommand {
        try parse(raw, file: file, line: line).0
    }

    private func error(_ raw: String) -> URLCommandError? {
        guard case let .failure(error) = URLCommand.parse(URL(string: raw)!) else { return nil }
        return error
    }

    func testNoteById() throws {
        XCTAssertEqual(try command("noteit://note/\(id.uuidString.lowercased())"), .note(id: id, heading: nil))
    }

    func testNoteByIdWithHeading() throws {
        XCTAssertEqual(try command("noteit://note/\(id.uuidString)?heading=To%20do"), .note(id: id, heading: "To do"))
    }

    func testNoteByTitle() throws {
        XCTAssertEqual(try command("noteit://note?title=Weekly%20plan"), .noteTitle(title: "Weekly plan", heading: nil))
        XCTAssertEqual(try command("noteit://note?title=Plan&heading=Mon"), .noteTitle(title: "Plan", heading: "Mon"))
        XCTAssertEqual(error("noteit://note/not-a-uuid"), .invalid("note"))
    }

    func testOpenIdStaysAnAction() throws {
        XCTAssertEqual(try command("noteit://open?id=\(id.uuidString)"), .open(.id(id)))
    }

    func testNewAllParameters() throws {
        let raw = "noteit://new?title=Hi&text=There&notebook=Work&tags=a,%20b,,c&open=1"
        XCTAssertEqual(try command(raw), .new(title: "Hi", text: "There", notebook: "Work", tags: ["a", "b", "c"], open: true))
        XCTAssertEqual(try command("noteit://new?text=x"), .new(title: nil, text: "x", notebook: nil, tags: [], open: false))
        for value in ["1", "true", "YES"] {
            XCTAssertEqual(try command("noteit://new?text=x&open=\(value)"),
                           .new(title: nil, text: "x", notebook: nil, tags: [], open: true), value)
        }
        XCTAssertEqual(try command("noteit://new?text=x&open=0"), .new(title: nil, text: "x", notebook: nil, tags: [], open: false))
    }

    func testShareInbox() throws {
        XCTAssertEqual(try command("noteit://new?inbox=\(id.uuidString)"), .shareInbox(id))
        XCTAssertEqual(error("noteit://new?inbox=nope"), .invalid("inbox"))
    }

    func testAppendById() throws {
        XCTAssertEqual(try command("noteit://append?id=\(id.uuidString)&text=More&position=start&timestamp=yes"),
                       .append(target: .id(id), text: "More", position: .start, timestamp: true))
        XCTAssertEqual(error("noteit://append?id=\(id.uuidString)&text=x&position=middle"), .invalid("position"))
        XCTAssertEqual(error("noteit://append?id=\(id.uuidString)"), .invalid("text"))
    }

    func testAppendByTitle() throws {
        XCTAssertEqual(try command("noteit://append?title=Hi&text=More"),
                       .append(target: .title("Hi"), text: "More", position: .end, timestamp: false))
        XCTAssertEqual(error("noteit://append?text=More"), .invalid("target"))
    }

    func testAppendDaily() throws {
        XCTAssertEqual(try command("noteit://append?daily=today&text=Call%20Anna&timestamp=1"),
                       .append(target: .daily, text: "Call Anna", position: .end, timestamp: true))
        XCTAssertEqual(error("noteit://append?daily=tomorrow&text=x"), .invalid("daily"))
    }

    func testChangesNotes() throws {
        let changing = [
            "noteit://new?text=x",
            "noteit://append?id=\(id.uuidString)&text=x",
            "noteit://append?title=Hi&text=x",
            "noteit://append?daily=today&text=x",
            "noteit://x-callback-url/new?text=x",
        ]
        for raw in changing { XCTAssertTrue(try command(raw).changesNotes, raw) }
        let notChanging = [
            "noteit://new?inbox=\(id.uuidString)",
            "noteit://open?id=\(id.uuidString)",
            "noteit://note/\(id.uuidString)",
            "noteit://note?title=Hi",
            "noteit://search?q=x",
            "noteit://daily",
            "noteit://settings?tab=sync",
            "noteit://tasks/today",
        ]
        for raw in notChanging { XCTAssertFalse(try command(raw).changesNotes, raw) }
    }

    func testOpenByIdAndTitle() throws {
        XCTAssertEqual(try command("noteit://open?title=Groceries"), .open(.title("Groceries")))
        XCTAssertEqual(error("noteit://open"), .invalid("target"))
        XCTAssertEqual(error("noteit://open?id=nope"), .invalid("id"))
    }

    func testSearch() throws {
        XCTAssertEqual(try command("noteit://search?q=milk%20eggs"), .search("milk eggs"))
        XCTAssertEqual(try command("noteit://daily"), .daily)
    }

    func testSettingsTabAcceptsEveryFrozenRawValue() throws {
        XCTAssertEqual(URLCommand.settingsTabs, ["general", "shortcuts", "editor", "sync", "data", "sharing", "smart",
                                                 "integrations", "plugins", "about"])
        for tab in URLCommand.settingsTabs {
            XCTAssertEqual(try command("noteit://settings?tab=\(tab)"), .settings(tab: tab))
        }
        XCTAssertEqual(try command("noteit://settings"), .settings(tab: "general"))
        XCTAssertEqual(error("noteit://settings?tab=nope"), .invalid("tab"))
    }

    func testRegisteredHostKeepsFragment() throws {
        let url = URL(string: "noteit://join?code=abc#k=secret")!
        XCTAssertEqual(try URLCommand.parse(url).get().0, .registered(host: "join", url: url))
        XCTAssertEqual(try command("noteit://Tasks"), .registered(host: "tasks", url: URL(string: "noteit://Tasks")!))
        XCTAssertEqual(error("noteit://bad_host"), .unknownHost("bad_host"))
        XCTAssertTrue(URLCommand.reservedHosts.isSuperset(of: ["new", "append", "open", "note", "search", "daily", "settings", "x-callback-url"]))
        XCTAssertEqual(URLCommand.reservedHosts.count, 8)
    }

    func testXCallbackForm() throws {
        let (command, callback) = try parse(
            "noteit://x-callback-url/append?title=Hi&text=x&x-success=myapp://ok&x-error=myapp://err&x-cancel=myapp://cancel")
        XCTAssertEqual(command, .append(target: .title("Hi"), text: "x", position: .end, timestamp: false))
        XCTAssertEqual(callback, XCallback(success: URL(string: "myapp://ok"), error: URL(string: "myapp://err"),
                                           cancel: URL(string: "myapp://cancel")))
        XCTAssertEqual(try self.command("noteit://x-callback-url/note/\(id.uuidString)?heading=A&x-success=myapp://ok"),
                       .note(id: id, heading: "A"))
        XCTAssertEqual(try self.command("noteit://x-callback-url/daily"), .daily)
        XCTAssertEqual(error("noteit://x-callback-url"), .invalid("action"))
    }

    func testDangerousCallbacksDropped() throws {
        for scheme in ["javascript:alert(1)", "file:///etc/passwd", "data:text/plain,hi", "noteit://new?text=x"] {
            let encoded = scheme.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            let (_, callback) = try parse("noteit://x-callback-url/search?q=x&x-success=\(encoded)&x-error=\(encoded)&x-cancel=\(encoded)")
            XCTAssertEqual(callback, XCallback(), scheme)
        }
    }

    func testHTTPCallbacksMayNotReceiveNoteDetails() {
        XCTAssertFalse(XCallback.mayReceiveNoteDetails(URL(string: "https://example.com/ok")!))
        XCTAssertFalse(XCallback.mayReceiveNoteDetails(URL(string: "HTTP://example.com/ok")!))
        XCTAssertTrue(XCallback.mayReceiveNoteDetails(URL(string: "shortcuts://x-callback-url/ok")!))
    }

    func testOversizedTextRejected() {
        let ok = String(repeating: "a", count: URLCommand.maxTextBytes)
        XCTAssertNotNil(try? command("noteit://new?text=\(ok)"))
        XCTAssertEqual(error("noteit://new?text=\(ok)a"), .tooLarge)
        XCTAssertEqual(error("noteit://append?title=Hi&text=\(ok)a"), .tooLarge)
        let multibyte = String(repeating: "%C3%A9", count: URLCommand.maxTextBytes / 2 + 1)
        XCTAssertEqual(error("noteit://new?text=\(multibyte)"), .tooLarge, "the limit counts UTF-8 bytes")
    }

    func testPercentEncodedPlusAndUnicode() throws {
        XCTAssertEqual(try command("noteit://search?q=1%2B1"), .search("1+1"))
        XCTAssertEqual(try command("noteit://search?q=a+b"), .search("a+b"), "a literal + is not a space")
        XCTAssertEqual(try command("noteit://search?q=caf%C3%A9%20%F0%9F%93%9D"), .search("café 📝"))
        XCTAssertEqual(try command("noteit://search?q=a%26b%3Dc"), .search("a&b=c"))
    }

    func testCallbackURLAppendsItemsKeepingExistingQuery() {
        let base = URL(string: "myapp://done?source=noteit")!
        let url = URLCommand.callbackURL(base, adding: [URLQueryItem(name: "title", value: "A & B+C"),
                                                        URLQueryItem(name: "id", value: id.uuidString)])
        XCTAssertEqual(url.absoluteString, "myapp://done?source=noteit&title=A%20%26%20B%2BC&id=\(id.uuidString)")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "title" })?.value, "A & B+C")
        XCTAssertEqual(URLCommand.callbackURL(base, adding: []), base)
    }

    func testOtherSchemesAreInvalid() {
        XCTAssertEqual(error("https://new?text=x"), .invalid("scheme"))
    }
}
