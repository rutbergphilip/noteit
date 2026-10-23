import CryptoKit
import Foundation
import NoteItSync

/// Where the library syncs to. S3 presets only differ in their defaults and help text.
enum SyncProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case folder, awsS3, cloudflareR2, backblazeB2, googleCloud, minio, customS3, noteItServer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .folder: "Folder"
        case .awsS3: "Amazon S3"
        case .cloudflareR2: "Cloudflare R2"
        case .backblazeB2: "Backblaze B2"
        case .googleCloud: "Google Cloud"
        case .minio: "MinIO / NAS"
        case .customS3: "Custom S3"
        case .noteItServer: "NoteIt Server"
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .awsS3: "shippingbox.fill"
        case .cloudflareR2: "cloud.fill"
        case .backblazeB2: "flame.fill"
        case .googleCloud: "globe"
        case .minio: "externaldrive.fill.badge.wifi"
        case .customS3: "server.rack"
        case .noteItServer: "network"
        }
    }

    /// One-line hint shown on the provider card.
    var hint: String {
        switch self {
        case .folder: "Any folder — NAS, iCloud Drive, Dropbox, USB"
        case .awsS3: "Your own AWS bucket"
        case .cloudflareR2: "No egress fees"
        case .backblazeB2: "Low-cost cloud storage"
        case .googleCloud: "Cloud Storage with HMAC keys"
        case .minio: "Self-hosted S3 on your network"
        case .customS3: "Wasabi, Synology C2 and more"
        case .noteItServer: "Your self-hosted NoteIt web app"
        }
    }

    var helpText: String {
        switch self {
        case .folder:
            "Choose a folder that your other Macs can reach, such as a NAS share, iCloud Drive or Dropbox. NoteIt keeps its files in an “\(RemoteLayout.folder)” subfolder."
        case .awsS3:
            "Create a bucket and an IAM access key limited to it. Replace <region> with the bucket's region, for example eu-north-1."
        case .cloudflareR2:
            "Create an R2 bucket and an API token with Object Read & Write access. Your account ID is shown on the R2 overview page."
        case .backblazeB2:
            "Create a private bucket and an application key for it. The endpoint is listed on the bucket's details page."
        case .googleCloud:
            "In Cloud Storage → Settings → Interoperability, create an HMAC key for a service account with access to your bucket."
        case .minio:
            "Use the S3 API address of your MinIO server or NAS (Synology, QNAP, TrueNAS), usually on port 9000."
        case .customS3:
            "Any S3-compatible service. Path-style addressing works with most self-hosted servers."
        case .noteItServer:
            "Create an access key in the NoteIt web app under Settings → Account → S3 Access Keys. Each person uses their own key and their own sync passphrase."
        }
    }

    var isS3: Bool { self != .folder }

    /// Self-hosted servers often only speak http on the local network; cloud providers always offer https.
    var allowsPlainHTTP: Bool { self == .minio || self == .customS3 || self == .noteItServer }

    /// A NoteIt server keeps each person's store at the top of their own namespace and refuses other keys.
    var allowsKeyPrefix: Bool { self != .noteItServer }

    var endpointTemplate: String {
        switch self {
        case .folder: ""
        case .awsS3: "https://s3.<region>.amazonaws.com"
        case .cloudflareR2: "https://<account-id>.r2.cloudflarestorage.com"
        case .backblazeB2: "https://s3.<region>.backblazeb2.com"
        case .googleCloud: "https://storage.googleapis.com"
        case .minio: "http://<nas-host>:9000"
        case .customS3: "https://"
        case .noteItServer: "https://<host>/s3"
        }
    }

    var defaultRegion: String {
        switch self {
        case .awsS3: "us-east-1"
        case .cloudflareR2, .googleCloud: "auto"
        case .backblazeB2: "us-west-004"
        case .minio, .customS3, .noteItServer: "us-east-1"
        case .folder: ""
        }
    }

    var defaultPathStyle: Bool { self == .minio || self == .customS3 || self == .googleCloud || self == .noteItServer }

    /// The bucket a NoteIt server serves under `/s3` (web-app spec §6.3); the other presets have none.
    var defaultBucket: String? { self == .noteItServer ? "noteit" : nil }
}

/// Non-secret sync settings, stored as JSON in UserDefaults. Secrets live in the keychain.
struct SyncConfiguration: Codable, Equatable, Sendable {
    var provider: SyncProvider
    var folderBookmark: Data?
    var folderPath: String?
    var s3: S3Config?
    var encrypted: Bool
    var deviceID: String
    var deviceName: String

    static let defaultsKey = "syncConfiguration"
    static let deviceIDKey = "syncDeviceID"

    init(provider: SyncProvider, folderBookmark: Data? = nil, folderPath: String? = nil, s3: S3Config? = nil,
         encrypted: Bool = true, deviceID: String = SyncConfiguration.stableDeviceID(), deviceName: String = SyncConfiguration.defaultDeviceName) {
        self.provider = provider
        self.folderBookmark = folderBookmark
        self.folderPath = folderPath
        self.s3 = s3
        self.encrypted = encrypted
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(SyncProvider.self, forKey: .provider)
        folderBookmark = try c.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        s3 = try c.decodeIfPresent(S3Config.self, forKey: .s3)
        encrypted = try c.decodeIfPresent(Bool.self, forKey: .encrypted) ?? true
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? UUID().uuidString
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? Self.defaultDeviceName
    }

    static var defaultDeviceName: String { Host.current().localizedName ?? "Mac" }

    /// One ID per Mac, kept across disconnect/reconnect so other devices don't see a new device each time.
    static func stableDeviceID(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: deviceIDKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceIDKey)
        return id
    }

    static func load(_ defaults: UserDefaults = .standard) -> SyncConfiguration? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SyncConfiguration.self, from: data)
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Bucket/prefix or folder path, for display.
    var destination: String {
        if provider == .folder {
            return (folderPath as NSString?)?.abbreviatingWithTildeInPath ?? "Folder"
        }
        guard let s3 else { return provider.displayName }
        let prefix = s3.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? s3.bucket : "\(s3.bucket)/\(prefix)"
    }

    /// The sync folder's name for messages, from the saved path, so it never touches the volume.
    var folderName: String? {
        guard provider == .folder, let folderPath, !folderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: folderPath, isDirectory: true).lastPathComponent
    }

    /// Identifies the remote store (not the credentials), e.g. to key the local sync state file.
    var storeKey: String {
        let parts: [String]
        if provider == .folder {
            parts = ["folder", folderPath.map(Self.standardizedPath) ?? ""]
        } else {
            parts = [provider.rawValue, s3?.endpoint.absoluteString.lowercased() ?? "", s3?.bucket ?? "",
                     s3?.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""]
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `URL(fileURLWithPath:).standardizedFileURL.path`, which keys existing state files, worked out from the string
    /// alone: Foundation stats the path, which blocks on a NAS that went away. Paths it would resolve on disk (a ".."
    /// after a symlink, a "/private" it drops when the path exists) still go through it; a chosen folder has neither.
    static func standardizedPath(_ path: String) -> String {
        let components = path.split(separator: "/").filter { $0 != "." }
        guard path.hasPrefix("/"), !components.contains(".."), components.first != "private" else {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        }
        return "/" + components.joined(separator: "/")
    }

    /// Resolves the folder, preferring the security-scoped bookmark and falling back to the stored path.
    /// `refreshedBookmark` is set when the bookmark was stale and has been recreated.
    func resolveFolder() -> (url: URL, scoped: Bool, refreshedBookmark: Data?)? {
        if let bookmark = folderBookmark {
            for options: URL.BookmarkResolutionOptions in [[.withSecurityScope, .withoutUI], [.withoutUI]] {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                    let refreshed = stale ? Self.makeBookmark(for: url) : nil
                    return (url, options.contains(.withSecurityScope), refreshed)
                }
            }
        }
        if let folderPath, !folderPath.isEmpty {
            return (URL(fileURLWithPath: folderPath, isDirectory: true), false, nil)
        }
        return nil
    }

    static func makeBookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }
}

enum PassphraseStrength: Int, Comparable {
    case tooShort, weak, fair, good, strong

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    init(_ passphrase: String) {
        let length = passphrase.count
        guard length >= 8 else { self = .tooShort; return }
        var classes = 0
        if passphrase.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if passphrase.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if passphrase.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if passphrase.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }
        let words = passphrase.split(whereSeparator: { $0 == " " || $0 == "-" }).count
        var score = 0
        if length >= 12 { score += 1 }
        if length >= 16 { score += 1 }
        if length >= 24 || words >= 4 { score += 1 }
        if classes >= 3 { score += 1 }
        switch score {
        case 0: self = .weak
        case 1: self = .fair
        case 2: self = .good
        default: self = .strong
        }
    }

    var label: String {
        switch self {
        case .tooShort: "Too short"
        case .weak: "Weak"
        case .fair: "Fair"
        case .good: "Good"
        case .strong: "Strong"
        }
    }
}
