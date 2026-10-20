import Foundation
import NoteItSync

/// `local-api.json`, which tells local clients whether the Local API is on and on which port. It never contains
/// a token. Shape owned by the automation plan; built in foundations Task 5.1.
public struct DiscoveryFile: Codable, Sendable, Equatable {
    public var version: Int
    public var pid: Int32
    public var appVersion: String
    public var apiEnabled: Bool
    /// nil while the API is off.
    public var port: UInt16?
    public var baseURL: URL?
    public var startedAt: Date

    public static let fileName = "local-api.json"

    public init(version: Int = 1, pid: Int32, appVersion: String, apiEnabled: Bool, port: UInt16?, baseURL: URL?,
                startedAt: Date) {
        self.version = version
        self.pid = pid
        self.appVersion = appVersion
        self.apiEnabled = apiEnabled
        self.port = port
        self.baseURL = baseURL
        self.startedAt = startedAt
    }

    /// NOTEIT_DATA_DIR (via AppEnvironment) or ~/Library/Application Support/<AppIdentity.dataFolderName>.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        if let dataDir = AppEnvironment.nonEmpty("DATA_DIR", in: environment) {
            return URL(fileURLWithPath: dataDir, isDirectory: true)
        }
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true)
    }

    /// nil when the file is missing, corrupt or stale (its process isn't running).
    public static func read(from directory: URL,
                            isProcessAlive: (Int32) -> Bool = DiscoveryFile.processIsAlive) -> DiscoveryFile? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let file = try? APIJSON.decoder().decode(DiscoveryFile.self, from: data),
              isProcessAlive(file.pid)
        else { return nil }
        return file
    }

    /// Atomic, mode 0600: written to a private temporary file in `directory`, then renamed over the old one.
    public func write(to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try APIJSON.encoder().encode(self)
        let target = directory.appendingPathComponent(Self.fileName)
        let temp = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        guard rename(temp.path, target.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public static func remove(from directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
