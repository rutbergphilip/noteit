import Foundation

public enum RemoteLayout {
    // "inkwell" is the legacy protocol name (from before NoteIt); it is part of the wire format and must stay.
    public static let folder = "inkwell"
    public static let root = folder + "/v1/"
    /// Throwaway objects written to probe conditional-write support (S3 only).
    public static let canaryPrefix = folder + "/.canary/"
    // Legacy bytes, kept so the probe stays identical for remote stores shared with Inkwell.
    public static let canaryMismatchETag = "inkwell-canary-mismatch"
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
