import Foundation
import NoteItAPI
import NoteItDoc

/// Files uploaded ahead of a note that refers to them as `noteit-attachment:att_<id>`. They live for an hour.
@MainActor
final class StagedUploads {
    static let maxFiles = 20
    static let maxTotalBytes = 100_000_000
    static let lifetime: TimeInterval = 3600

    let directory: URL
    private let now: () -> Date
    private let fm = FileManager.default

    init(directory: URL = DiscoveryFile.directory().appendingPathComponent("staged", isDirectory: true),
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    static func isValidID(_ id: String) -> Bool {
        guard id.hasPrefix("att_") else { return false }
        let rest = id.dropFirst(4)
        return rest.count == 22 && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    func stage(_ data: Data) throws(AutomationError) -> StagedUploadDTO {
        let date = now()
        purgeExpired(now: date)
        guard !data.isEmpty else { throw .invalidInput("The upload is empty.") }
        guard AttachmentLimit.allows(byteCount: data.count) else { throw .tooLarge }
        let existing = files()
        guard existing.count < Self.maxFiles,
              existing.reduce(0, { $0 + $1.size }) + data.count <= Self.maxTotalBytes else { throw .tooLarge }
        let id = Self.newID()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(id)
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        } catch {
            throw .invalidInput("The upload couldn't be saved.")
        }
        return StagedUploadDTO(id: id, expiresAt: date.addingTimeInterval(Self.lifetime))
    }

    /// The staged file's bytes, or nil when `id` is malformed, unknown or expired.
    func data(for id: String) -> Data? {
        guard Self.isValidID(id) else { return nil }
        let url = directory.appendingPathComponent(id)
        guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now().timeIntervalSince(modified) < Self.lifetime else { return nil }
        return try? Data(contentsOf: url)
    }

    func purgeExpired(now date: Date) {
        for file in files() where date.timeIntervalSince(file.modified) >= Self.lifetime {
            try? fm.removeItem(at: file.url)
        }
    }

    func removeAll() {
        try? fm.removeItem(at: directory)
    }

    private func files() -> [(url: URL, size: Int, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard Self.isValidID(url.lastPathComponent), let values = try? url.resourceValues(forKeys: Set(keys)) else {
                return nil
            }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "att_" + encoded
    }
}
