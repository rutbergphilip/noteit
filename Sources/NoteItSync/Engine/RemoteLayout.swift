import CryptoKit
import Foundation

public enum RemoteLayout {
    public static let folder = "noteit"
    public static let root = folder + "/v1/"
    /// Where Inkwell (NoteIt's former name) kept the store. Read only to migrate it (see `RemoteMigration`).
    public static let legacyRoot = "inkwell/v1/"
    /// Throwaway objects written to probe conditional-write support (S3 only).
    public static let canaryPrefix = folder + "/.canary/"
    public static let canaryMismatchETag = "noteit-canary-mismatch"
    // Legacy bytes: seeds every note's content revision, which is synced. Changing it forces a full re-sync.
    public static let revisionHashSeed = "inkwell-revision-v1"

    /// Never encrypted: it carries the parameters needed to derive the key.
    public static func manifest() -> String {
        root + "manifest.json"
    }

    public static func meta(_ kind: RecordKind, _ id: UUID) -> String {
        switch kind {
        case .notebook: return root + "notebooks/\(id.uuidString).json"
        case .note: return root + "notes/\(id.uuidString).meta"
        case .smartFolder: return root + "smart-folders/\(id.uuidString).json"
        }
    }

    public static func body(_ id: UUID) -> String {
        root + "notes/\(id.uuidString).body"
    }

    public static func tombstone(_ id: UUID) -> String {
        root + "tombstones/\(id.uuidString).json"
    }

    public static func device(_ deviceID: String) -> String {
        root + "devices/\(deviceID).json"
    }

    /// Versioned noteit-doc bodies (web-app spec §3.4.9). Old builds ignore this folder entirely.
    public static let bodiesPrefix = root + "bodies/"
    /// The tag of a body whose commit uses `If-None-Match: *` (the note has no meta yet).
    public static let newTag = "new"

    /// `bodies/<ID>.<VERSION>.<TAG>.body`; a locked body ends in `.locked` instead (program §4 rule 13).
    public static func docBody(_ id: UUID, version: UUID, tag: String, locked: Bool = false) -> String {
        bodiesPrefix + "\(id.uuidString).\(version.uuidString).\(tag).\(locked ? "locked" : "body")"
    }

    /// Spec §3.4.9: the first 10 bytes of SHA-256 over the UTF-8 of the unquoted ETag, RFC 4648 base32 without
    /// padding: 16 characters `[A-Z2-7]`.
    public static func baseTag(_ etag: String) -> String {
        let digest = Array(SHA256.hash(data: Data(unquotedETag(etag).utf8)).prefix(10))
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer = 0, bits = 0
        for byte in digest {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        return output
    }

    /// A parsed body name under `bodiesPrefix`.
    public struct DocBodyName: Sendable, Equatable {
        public let id: UUID
        public let version: UUID
        public let tag: String
        public let locked: Bool
    }

    /// Parses `<ID>.<VERSION>.<TAG>.body|.locked`: both UUIDs in uppercase canonical form, TAG 16 base32
    /// characters or `new`. Anything else under `bodies/` is an unparsable ("stray") name.
    public static func parseDocBody(_ key: String) -> DocBodyName? {
        guard key.hasPrefix(bodiesPrefix) else { return nil }
        let parts = key.dropFirst(bodiesPrefix.count).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[3] == "body" || parts[3] == "locked",
              let id = UUID(uuidString: parts[0]), id.uuidString == parts[0],
              let version = UUID(uuidString: parts[1]), version.uuidString == parts[1],
              isTag(parts[2]) else { return nil }
        return DocBodyName(id: id, version: version, tag: parts[2], locked: parts[3] == "locked")
    }

    static func isTag(_ tag: String) -> Bool {
        tag == newTag || (tag.count == 16 && tag.allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) })
    }

    static func unquotedETag(_ etag: String) -> String {
        etag.count >= 2 && etag.hasPrefix("\"") && etag.hasSuffix("\"") ? String(etag.dropFirst().dropLast()) : etag
    }

    /// Who showed a reminder (organise). No version's record sync reads this folder.
    public static let reminderClaimsPrefix = root + "claims/reminders/"

    public static func reminderClaim(_ id: UUID) -> String {
        reminderClaimsPrefix + "\(id.uuidString).json"
    }
}

/// How objects under a prefix are sealed (program §4 rule 6). foundations Task 3.5; sync-security and sharing
/// add rows that use `.spaceKey` and `.unsealed`.
/// storeKey: sealed with the session's key (the personal store key, or the space key in a space session).
/// spaceKey: objects sealed with a space key inside a personal store.
/// unsealed: signed logs, HPKE key files and the canary; RekeyRunner never re-seals them.
public enum RecordSealing: Sendable, Equatable { case storeKey, spaceKey, unsealed }

/// One row of the remote layout registry (foundations Task 3.5).
public struct RemotePrefix: Sendable, Equatable {
    /// Full key prefix, e.g. "noteit/v1/notes/".
    public let path: String
    /// Segments after `path`; "noteit/v1/notes/<UUID>.meta" is 1.
    public let depth: Int
    public let sealing: RecordSealing
    /// The sub-project slug that owns the row.
    public let owner: String

    public init(path: String, depth: Int, sealing: RecordSealing, owner: String) {
        self.path = path
        self.depth = depth
        self.sealing = sealing
        self.owner = owner
    }
}

/// The prefix registry and key grammar (program §4 rule 8), foundations Task 3.5. Each sub-project that adds a
/// prefix adds its row here, plus vectors in fixtures/golden/layout-keys.json.
extension RemoteLayout {
    public static let prefixes: [RemotePrefix] = [
        RemotePrefix(path: root + "notebooks/", depth: 1, sealing: .storeKey, owner: "core"),
        RemotePrefix(path: root + "notes/", depth: 1, sealing: .storeKey, owner: "core"),
        RemotePrefix(path: root + "tombstones/", depth: 1, sealing: .storeKey, owner: "core"),
        RemotePrefix(path: root + "devices/", depth: 1, sealing: .storeKey, owner: "core"),
        RemotePrefix(path: root + "smart-folders/", depth: 1, sealing: .storeKey, owner: "organise"),
        RemotePrefix(path: root + "claims/reminders/", depth: 1, sealing: .storeKey, owner: "organise"),
        RemotePrefix(path: root + "bodies/", depth: 1, sealing: .storeKey, owner: "web-app"),
    ]

    /// `manifest()`; never sealed and excluded from rekey.
    public static let manifestKey = manifest()

    /// The longest registered row whose path prefixes `key` and whose depth equals the key's depth below it.
    public static func prefix(for key: String) -> RemotePrefix? {
        prefix(for: key, prefixes: prefixes)
    }

    static func prefix(for key: String, prefixes: [RemotePrefix]) -> RemotePrefix? {
        prefixes
            .filter { key.hasPrefix($0.path) && depth(of: key, below: $0.path) == $0.depth }
            .max { $0.path.count < $1.path.count }
    }

    /// Every segment matches [A-Za-z0-9._-]+ and is not "." or ".."; a segment whose part before the first "."
    /// is a UUID must be its uppercase canonical form; the key is `manifestKey`, a canary key, or sits under a
    /// registered prefix at exactly the depth of a row with that path.
    public static func isValidKey(_ key: String) -> Bool {
        isValidKey(key, prefixes: prefixes)
    }

    static func isValidKey(_ key: String, prefixes: [RemotePrefix]) -> Bool {
        guard hasValidSegments(key) else { return false }
        if key == manifestKey || isCanaryKey(key) { return true }
        guard let row = prefix(for: key, prefixes: prefixes) else { return false }
        // Body names carry a second UUID and a tag the generic grammar doesn't check.
        return row.path != bodiesPrefix || parseDocBody(key) != nil
    }

    /// A registered prefix path, `canaryPrefix`, or a parent root of either (every shorter prefix ending at a
    /// "/", such as "noteit/v1/" and "noteit/"), so clients that list the whole root (the 0.4.x engine, rclone)
    /// keep listing. `legacyRoot` and "inkwell/" stay listable so `RemoteMigration` can look for an Inkwell
    /// store; keys under them are not valid. Everything else is refused, including "".
    public static func isListablePrefix(_ prefix: String) -> Bool {
        isListablePrefix(prefix, prefixes: prefixes)
    }

    static func isListablePrefix(_ prefix: String, prefixes: [RemotePrefix]) -> Bool {
        guard prefix.hasSuffix("/"), hasValidSegments(String(prefix.dropLast())) else { return false }
        return (prefixes.map(\.path) + [canaryPrefix, legacyRoot]).contains { $0.hasPrefix(prefix) }
    }

    static func isCanaryKey(_ key: String) -> Bool {
        key.hasPrefix(canaryPrefix) && depth(of: key, below: canaryPrefix) == 1
    }

    private static func depth(of key: String, below path: String) -> Int {
        let rest = key.dropFirst(path.count)
        return rest.isEmpty ? 0 : rest.split(separator: "/", omittingEmptySubsequences: false).count
    }

    private static let segmentCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func hasValidSegments(_ key: String) -> Bool {
        key.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
            guard !segment.isEmpty, segment != ".", segment != "..",
                  segment.allSatisfy(segmentCharacters.contains) else { return false }
            let stem = String(segment.prefix { $0 != "." })
            if let uuid = UUID(uuidString: stem) { return stem == uuid.uuidString }
            return true
        }
    }
}
