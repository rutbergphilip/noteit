import Foundation
import NoteItAPI
import XCTest

final class HTTPParserTests: XCTestCase {
    private let parser = HTTPParser()

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func request(_ result: HTTPParseResult, file: StaticString = #filePath, line: UInt = #line)
        -> (HTTPRequest, Int)? {
        guard case .request(let request, let consumed) = result else {
            XCTFail("Expected a request, got \(result)", file: file, line: line)
            return nil
        }
        return (request, consumed)
    }

    func testParsesSimpleGet() {
        let raw = "GET /v1/ping HTTP/1.1\r\nHost: 127.0.0.1:47600\r\nAccept: */*\r\n\r\n"
        guard let (request, consumed) = request(parser.parse(data(raw))) else { return }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/ping")
        XCTAssertEqual(request.query, [:])
        XCTAssertEqual(request.headers["host"], "127.0.0.1:47600")
        XCTAssertEqual(request.headers["ACCEPT"], "*/*")
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertEqual(consumed, raw.utf8.count)
    }

    func testNeedsMoreForPartialHeaders() {
        XCTAssertEqual(parser.parse(Data()), .needMore)
        XCTAssertEqual(parser.parse(data("GET /v1/ping HTTP/1.1\r\nHost: 127.0.0.1")), .needMore)
        XCTAssertEqual(parser.parse(data("GET /v1/ping HTTP/1.1\r\nHost: x\r\n\r")), .needMore)
    }

    func testNeedsMoreForPartialBody() {
        let head = "POST /v1/notes HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n"
        XCTAssertEqual(parser.parse(data(head + "{\"body\"")), .needMore)
        guard let (request, consumed) = request(parser.parse(data(head + "{\"body\":1}"))) else { return }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{\"body\":1}")
        XCTAssertEqual(consumed, head.utf8.count + 10)
    }

    func testPipelinedRequests() {
        let first = "POST /v1/notes HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}"
        let second = "GET /v1/notes?limit=5 HTTP/1.1\r\nHost: x\r\n\r\n"
        var buffer = data(first + second + "GET /v1/pi")
        guard let (one, consumedOne) = request(parser.parse(buffer)) else { return }
        XCTAssertEqual(one.method, "POST")
        XCTAssertEqual(one.body, data("{}"))
        XCTAssertEqual(consumedOne, first.utf8.count)
        buffer.removeFirst(consumedOne)
        guard let (two, consumedTwo) = request(parser.parse(buffer)) else { return }
        XCTAssertEqual(two.path, "/v1/notes")
        XCTAssertEqual(two.query, ["limit": "5"])
        buffer.removeFirst(consumedTwo)
        XCTAssertEqual(parser.parse(buffer), .needMore)
    }

    func testHeaderLimit() {
        let limited = HTTPParser(limits: HTTPParserLimits(maxHeaderBytes: 64))
        let long = "GET /v1/ping HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 100)
        XCTAssertEqual(limited.parse(data(long)), .failure(status: 431, .tooLarge))
        XCTAssertEqual(limited.parse(data(long + "\r\n\r\n")), .failure(status: 431, .tooLarge))
        XCTAssertEqual(limited.parse(data("GET / HTTP/1.1\r\nX-Pad: a")), .needMore)
    }

    func testBodyLimit() {
        let limited = HTTPParser(limits: HTTPParserLimits(maxJSONBody: 10, maxBinaryBody: 20))
        let tooBig = "POST /v1/attachments HTTP/1.1\r\nHost: x\r\nContent-Length: 21\r\n\r\n"
        XCTAssertEqual(limited.parse(data(tooBig)), .failure(status: 413, .tooLarge))
        let fits = "POST /v1/attachments HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n" + String(repeating: "b", count: 20)
        XCTAssertNotNil(request(limited.parse(data(fits))))
        let bogus = "POST /v1/notes HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n"
        XCTAssertEqual(parser.parse(data(bogus)), .failure(status: 400, .badRequest))
        let conflicting = "POST /v1/notes HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"
        XCTAssertEqual(parser.parse(data(conflicting)), .failure(status: 400, .badRequest))
    }

    func testParseHeadReturnsHeadBeforeBody() {
        let limited = HTTPParser(limits: HTTPParserLimits(maxJSONBody: 10, maxBinaryBody: 20))
        let head = "POST /v1/notes HTTP/1.1\r\nHost: x\r\nContent-Length: 50000000\r\n\r\n"
        guard case .head(let request, let bodyStart, let length) = limited.parseHead(data(head + "ab")) else {
            return XCTFail("expected a head")
        }
        XCTAssertEqual(request.path, "/v1/notes")
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertEqual(bodyStart, head.utf8.count)
        XCTAssertEqual(length, 50_000_000)
        XCTAssertEqual(limited.parseHead(data("POST /v1/notes HTTP/1.1\r\n")), .needMore)
    }

    func testChunkedRejected() {
        let chunked = "POST /v1/notes HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"
        XCTAssertEqual(parser.parse(data(chunked)), .failure(status: 411, .lengthRequired))
        let noLength = "POST /v1/notes HTTP/1.1\r\nHost: x\r\n\r\n{}"
        XCTAssertEqual(parser.parse(data(noLength)), .failure(status: 411, .lengthRequired))
        let emptyPost = "POST /v1/notes/1/restore HTTP/1.1\r\nHost: x\r\n\r\n"
        XCTAssertNotNil(request(parser.parse(data(emptyPost))))
    }

    func testBareLFRejected() {
        XCTAssertEqual(parser.parse(data("GET /v1/ping HTTP/1.1\nHost: x\n\n")), .failure(status: 400, .badRequest))
        XCTAssertEqual(parser.parse(data("GET /v1/ping HTTP/1.1\r\nHost: x\n\r\n\r\n")), .failure(status: 400, .badRequest))
    }

    func testQueryDecoding() {
        let raw = "GET /v1/notes/My%20Note/attachments/a%2Bb.png?q=hello+world&tag=caf%C3%A9&flag&q=second&empty= HTTP/1.1\r\n\r\n"
        guard let (request, _) = request(parser.parse(data(raw))) else { return }
        XCTAssertEqual(request.path, "/v1/notes/My Note/attachments/a+b.png")
        XCTAssertEqual(request.query, ["q": "hello world", "tag": "café", "flag": "", "empty": ""])
        XCTAssertEqual(parser.parse(data("GET /v1/notes?q=%zz HTTP/1.1\r\n\r\n")), .failure(status: 400, .badRequest))
        XCTAssertEqual(parser.parse(data("GET v1/notes HTTP/1.1\r\n\r\n")), .failure(status: 400, .badRequest))
        XCTAssertEqual(parser.parse(data("get /v1/notes HTTP/1.1\r\n\r\n")), .failure(status: 400, .badRequest))
        XCTAssertEqual(parser.parse(data("GET /v1/notes HTTP/2\r\n\r\n")), .failure(status: 400, .badRequest))
    }

    func testResponseSerialization() {
        var response = HTTPResponse.json(["ok": true], status: 201)
        response.headers["Allow"] = "GET"
        let text = String(decoding: response.serialized(keepAlive: true), as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(parts.count, 2)
        let lines = parts[0].components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "HTTP/1.1 201 Created")
        XCTAssertTrue(lines.contains("Content-Type: application/json; charset=utf-8"))
        XCTAssertTrue(lines.contains("Content-Length: \(parts[1].utf8.count)"))
        XCTAssertTrue(lines.contains("Cache-Control: no-store"))
        XCTAssertTrue(lines.contains("X-Content-Type-Options: nosniff"))
        XCTAssertTrue(lines.contains("Connection: keep-alive"))
        XCTAssertTrue(lines.contains("Allow: GET"))
        XCTAssertEqual(parts[1], "{\"ok\":true}")

        let closing = String(decoding: HTTPResponse.error(.notFound, "No").serialized(keepAlive: false), as: UTF8.self)
        XCTAssertTrue(closing.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(closing.contains("\r\nConnection: close\r\n"))
    }

    func testFuzzNeverCrashes() {
        var random = SeededGenerator(seed: 0x5EED)
        let small = HTTPParser(limits: HTTPParserLimits(maxHeaderBytes: 512, maxJSONBody: 256, maxBinaryBody: 1024))
        let alphabet = Array("GETPOST /v1?=&%:\r\n0123456789abcHTTP/1.Content-Length".utf8) + [0, 0xFF, 0xC3]
        for _ in 0..<10_000 {
            let count = Int.random(in: 0...200, using: &random)
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            for _ in 0..<count {
                bytes.append(Bool.random(using: &random) ? alphabet.randomElement(using: &random)! : UInt8.random(in: 0...255, using: &random))
            }
            assertResult(small.parse(Data(bytes)))
        }
        let valid = [
            "GET /v1/ping HTTP/1.1\r\nHost: 127.0.0.1:47600\r\n\r\n",
            "POST /v1/notes HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"body\":\"hi\"}",
            "PATCH /v1/notes/A%20B?x=1+2 HTTP/1.1\r\nIf-Match: \"x\"\r\nContent-Length: 2\r\n\r\n{}GET / HTTP/1.1\r\n\r\n",
        ].map { Array($0.utf8) }
        for _ in 0..<2_000 {
            var bytes = valid.randomElement(using: &random)!
            bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &random)))
            if !bytes.isEmpty, Bool.random(using: &random) {
                bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
            }
            assertResult(small.parse(Data(bytes)))
            assertResult(parser.parse(Data(bytes).dropFirst(min(1, bytes.count))))
        }
    }

    private func assertResult(_ result: HTTPParseResult) {
        switch result {
        case .needMore: break
        case .request(_, let consumed): XCTAssertGreaterThan(consumed, 0)
        case .failure(let status, _): XCTAssertTrue((400...499).contains(status))
        }
    }
}

/// SplitMix64, so the fuzz run is the same every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
