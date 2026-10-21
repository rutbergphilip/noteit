import AppKit
import Foundation

/// `<data>/Previous Library <date>/`: the RTFD bodies a conversion to Markdown left behind (spec §3.6). It is never
/// moved to the Trash unless the user chooses to.
struct PreviousLibrary: Equatable {
    static let folderPrefix = "Previous Library "
    static let markerName = "previous-library.json"
    static let questionDelay: TimeInterval = 30 * 24 * 3600

    private struct Marker: Codable {
        var createdAt: Date
        var keep: Bool
    }

    let url: URL
    var createdAt: Date
    var keep: Bool

    /// Creates the folder with a unique name and its marker.
    static func create(in dataDir: URL, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let base = folderPrefix + formatter.string(from: now)
        var url = dataDir.appendingPathComponent(base, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dataDir.appendingPathComponent("\(base) \(number)", isDirectory: true)
            number += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try writeMarker(Marker(createdAt: now, keep: false), in: url)
        return url
    }

    private static func writeMarker(_ marker: Marker, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: folder.appendingPathComponent(markerName), options: .atomic)
    }

    /// Every previous library in the data folder, oldest first.
    static func find(dataDir: URL) -> [PreviousLibrary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.filter { $0.hasPrefix(folderPrefix) }.compactMap { name in
            let url = dataDir.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: url.appendingPathComponent(markerName)),
                  let marker = try? decoder.decode(Marker.self, from: data) else { return nil }
            return PreviousLibrary(url: url, createdAt: marker.createdAt, keep: marker.keep)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var size: Int64 { LibraryConverter.size(of: url) }

    /// Asked once, 30 days after the conversion, unless the user chose **Keep**.
    func shouldAsk(now: Date) -> Bool {
        !keep && now.timeIntervalSince(createdAt) >= Self.questionDelay && exists
    }

    mutating func keepIt() throws {
        try Self.writeMarker(Marker(createdAt: createdAt, keep: true), in: url)
        keep = true
    }

    func moveToTrash(using trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        try trash(url)
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: createdAt)
    }

    private static func sizeText(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// The Your Data row.
    func title(size: Int64) -> String {
        "Previous library from \(dateText) (\(Self.sizeText(size)))"
    }

    func question(size: Int64) -> String {
        "Your previous library from \(dateText) is still on this Mac (\(Self.sizeText(size))). Move it to the Trash?"
    }

    static let trashButton = "Move to Trash"
    static let keepButton = "Keep"

    /// At launch: asks about the oldest previous library that is due, at most one per launch.
    @MainActor
    static func askIfDue(dataDir: URL, now: Date = Date()) {
        guard var previous = find(dataDir: dataDir).first(where: { $0.shouldAsk(now: now) }) else { return }
        let alert = NSAlert()
        alert.messageText = previous.question(size: previous.size)
        alert.addButton(withTitle: trashButton)
        alert.addButton(withTitle: keepButton)
        do {
            if alert.runModal() == .alertFirstButtonReturn {
                try previous.moveToTrash()
            } else {
                try previous.keepIt()
            }
        } catch {
            NSLog("NoteIt: couldn't update the previous library: \(error)")
        }
    }
}
