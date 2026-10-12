import Foundation

public enum RemoteLayout {
    public static let root = "inkwell/v1/"

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
