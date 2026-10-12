import Foundation

public struct S3ListPage: Sendable, Equatable {
    public var objects: [RemoteObject]
    public var isTruncated: Bool
    public var nextContinuationToken: String?
}

public struct S3ErrorBody: Sendable, Equatable {
    public var code: String
    public var message: String
}

/// Parses `ListBucketResult` (ListObjectsV2) and S3 `Error` documents.
public enum S3ListParser {
    public static func parse(_ data: Data) throws -> S3ListPage {
        let delegate = ListDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else {
            throw StorageError.invalidResponse("Malformed ListBucketResult")
        }
        return S3ListPage(objects: delegate.objects, isTruncated: delegate.isTruncated, nextContinuationToken: delegate.nextToken)
    }

    public static func parseError(_ data: Data) -> S3ErrorBody? {
        guard !data.isEmpty else { return nil }
        let delegate = ErrorDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let code = delegate.code else { return nil }
        return S3ErrorBody(code: code, message: delegate.message ?? "")
    }

    static func stripQuotes(_ etag: String) -> String {
        var value = etag.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("W/") { value.removeFirst(2) }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private final class ListDelegate: NSObject, XMLParserDelegate {
        var objects: [RemoteObject] = []
        var isTruncated = false
        var nextToken: String?
        var sawRoot = false

        private var path: [String] = []
        private var text = ""
        private var key: String?
        private var etag: String?
        private var size = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if path.isEmpty, elementName == "ListBucketResult" { sawRoot = true }
            path.append(elementName)
            text = ""
            if elementName == "Contents" {
                key = nil
                etag = nil
                size = 0
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let parent = path.count >= 2 ? path[path.count - 2] : nil
            switch (parent, elementName) {
            case ("Contents", "Key"): key = text
            case ("Contents", "ETag"): etag = S3ListParser.stripQuotes(text)
            case ("Contents", "Size"): size = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            case ("ListBucketResult", "Contents"):
                if let key { objects.append(RemoteObject(key: key, etag: etag ?? "", size: size)) }
            case ("ListBucketResult", "IsTruncated"):
                isTruncated = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            case ("ListBucketResult", "NextContinuationToken"):
                nextToken = text.isEmpty ? nil : text
            default: break
            }
            path.removeLast()
            text = ""
        }
    }

    private final class ErrorDelegate: NSObject, XMLParserDelegate {
        var code: String?
        var message: String?
        private var depth = 0
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            depth += 1
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if depth == 2 {
                if elementName == "Code" { code = text }
                if elementName == "Message" { message = text }
            }
            depth -= 1
            text = ""
        }
    }
}
