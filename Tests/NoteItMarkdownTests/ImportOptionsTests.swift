import CryptoKit
import NoteItDoc
import XCTest
@testable import NoteItMarkdown

final class ImportOptionsTests: XCTestCase {
    private actor Fetches {
        var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func inlines(_ body: BodyContainer) -> [Inline] {
        var result: [Inline] = []
        MarkdownWriter.forEachContent(in: body.doc) { result += $0 }
        return result
    }

    func testImagesBecomeAttachmentsFetchedOnce() async throws {
        let fetches = Fetches()
        let png = png
        let options = MarkdownImportOptions(baseURL: URL(string: "https://example.com/posts/one.html")) { url in
            await fetches.record(url)
            return url.lastPathComponent == "missing.png" ? nil : png
        }
        let text = "![Dot](img/dot%20one.png) and ![Again](img/dot%20one.png)\n\n![Abs](https://cdn.example.com/a.png)\n\n![Gone](missing.png)\n"
        let imported = try await MarkdownCodec.importDocument(text, options: options)

        let urls = await fetches.urls
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/posts/img/dot%20one.png", "https://cdn.example.com/a.png",
                                                    "https://example.com/posts/missing.png"])
        XCTAssertEqual(imported.body.attachments, [sha(png): Attachment(mime: "image/png", name: "Dot", data: png)])
        XCTAssertEqual(inlines(imported.body), [
            .image(sha: sha(png), name: "Dot", mime: "image/png", width: nil), .text(" and ", marks: []),
            .image(sha: sha(png), name: "Again", mime: "image/png", width: nil),
            .image(sha: sha(png), name: "Abs", mime: "image/png", width: nil),
        ])
        XCTAssertEqual(imported.unresolvedImages, [AttachmentRef(path: "missing.png", displayName: "Gone")])
    }

    func testOversizedAndUnavailableImagesAreDropped() async throws {
        let big = Data(count: AttachmentLimit.maxBytes + 1)
        let options = MarkdownImportOptions { url in url.lastPathComponent == "big.png" ? big : nil }
        let imported = try await MarkdownCodec.importDocument("Before ![Big](big.png) ![None](none.png|300) after\n", options: options)
        XCTAssertEqual(imported.body.attachments, [:])
        XCTAssertEqual(inlines(imported.body), [.text("Before   after", marks: [])])
        XCTAssertEqual(imported.unresolvedImages.map(\.path), ["big.png", "none.png|300"])
    }

    func testWikiLinksUseResolveNoteLink() async throws {
        let id = UUID()
        let options = MarkdownImportOptions(resolveNoteLink: { $0 == "Plan" ? id : nil })
        let imported = try await MarkdownCodec.importDocument("---\naliases: [x]\n---\nSee [[Plan]] and [[Other]]\n", options: options)
        XCTAssertEqual(imported.frontMatter.extra, "aliases: [x]")
        XCTAssertEqual(inlines(imported.body), [
            .text("See ", marks: []), .text("Plan", marks: [.link(href: "noteit://note/" + id.uuidString)]),
            .text(" and ", marks: []), .text("Other", marks: [.link(href: "noteit://note?title=Other")]),
        ])
    }
}
