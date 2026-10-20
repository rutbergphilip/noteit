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
        return prefix(for: key, prefixes: prefixes) != nil
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
