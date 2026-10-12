import XCTest
@testable import InkwellSync

final class SigV4SignerTests: XCTestCase {
    private let credentials = S3Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )
    private let date = Date(timeIntervalSince1970: 1_369_353_600) // 20130524T000000Z

    private func signed(_ url: String, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        SigV4Signer.sign(request: &request, payloadSHA256: SigV4Signer.emptyPayloadSHA256, credentials: credentials, region: "us-east-1", service: "s3", date: date)
        return request
    }

    private func signature(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")?.components(separatedBy: "Signature=").last
    }

    func testEmptyPayloadHash() {
        XCTAssertEqual(SigV4Signer.emptyPayloadSHA256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testGetObjectWithRange() {
        let request = signed("https://examplebucket.s3.amazonaws.com/test.txt", headers: ["Range": "bytes=0-9"])
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
    }

    func testGetBucketLifecycle() {
        let request = signed("https://examplebucket.s3.amazonaws.com/?lifecycle")
        XCTAssertEqual(signature(request), "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date,"))
    }

    func testListObjects() {
        let request = signed("https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")
        XCTAssertEqual(signature(request), "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    func testQueryOrderDoesNotAffectSignature() {
        let a = signed("https://examplebucket.s3.amazonaws.com/?prefix=J&max-keys=2")
        XCTAssertEqual(signature(a), "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    func testConditionalHeadersAreSigned() {
        let request = signed("https://examplebucket.s3.amazonaws.com/k", headers: ["If-None-Match": "*"])
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("SignedHeaders=host;if-none-match;x-amz-content-sha256;x-amz-date,"))
    }

    func testURIEncode() {
        XCTAssertEqual(SigV4Signer.uriEncode("a b/c~d*"), "a%20b%2Fc~d%2A")
        XCTAssertEqual(SigV4Signer.uriEncode("a b/c", encodeSlash: false), "a%20b/c")
    }

    func testCredentialsDescriptionRedactsSecret() {
        XCTAssertFalse(String(describing: credentials).contains("EXAMPLEKEY"))
    }
}
