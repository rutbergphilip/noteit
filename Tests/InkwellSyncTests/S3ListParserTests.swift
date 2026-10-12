import XCTest
@testable import InkwellSync

final class S3ListParserTests: XCTestCase {
    func testParsesTruncatedPage() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>bucket</Name>
          <Prefix>inkwell/v1/</Prefix>
          <KeyCount>2</KeyCount>
          <MaxKeys>2</MaxKeys>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
          <Contents>
            <Key>inkwell/v1/notes/a&amp;b.meta</Key>
            <LastModified>2026-10-12T10:00:00.000Z</LastModified>
            <ETag>&quot;9b2cf535f27731c974343645a3985328&quot;</ETag>
            <Size>42</Size>
            <Owner><ID>x</ID></Owner>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
          <Contents>
            <Key>inkwell/v1/manifest.json</Key>
            <ETag>"abc-2"</ETag>
            <Size>7</Size>
          </Contents>
        </ListBucketResult>
        """
        let page = try S3ListParser.parse(Data(xml.utf8))
        XCTAssertTrue(page.isTruncated)
        XCTAssertEqual(page.nextContinuationToken, "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
        XCTAssertEqual(page.objects, [
            RemoteObject(key: "inkwell/v1/notes/a&b.meta", etag: "9b2cf535f27731c974343645a3985328", size: 42),
            RemoteObject(key: "inkwell/v1/manifest.json", etag: "abc-2", size: 7),
        ])
    }

    func testParsesEmptyFinalPage() throws {
        let xml = """
        <ListBucketResult><Name>b</Name><KeyCount>0</KeyCount><IsTruncated>false</IsTruncated></ListBucketResult>
        """
        let page = try S3ListParser.parse(Data(xml.utf8))
        XCTAssertFalse(page.isTruncated)
        XCTAssertNil(page.nextContinuationToken)
        XCTAssertEqual(page.objects, [])
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try S3ListParser.parse(Data("<Nope/>".utf8)))
        XCTAssertThrowsError(try S3ListParser.parse(Data("not xml".utf8)))
    }

    func testParsesErrorDocument() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>AccessDenied</Code><Message>Access Denied</Message><RequestId>1</RequestId></Error>
        """
        XCTAssertEqual(S3ListParser.parseError(Data(xml.utf8)), S3ErrorBody(code: "AccessDenied", message: "Access Denied"))
        XCTAssertNil(S3ListParser.parseError(Data()))
    }
}
