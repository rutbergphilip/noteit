import Foundation

public enum RecordKind: String, Codable, Sendable {
    case notebook, note, smartFolder

    /// Conflicts keep the newer edit instead of making a conflict copy (records without a body).
    public var usesLastWriterWins: Bool { self != .note }
}

public struct LocalRecord: Sendable, Hashable {
    public var id: UUID
    public var kind: RecordKind
    public var revision: UUID
    public var modifiedAt: Date

    public init(id: UUID, kind: RecordKind, revision: UUID, modifiedAt: Date) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.modifiedAt = modifiedAt
    }
}

public struct RecordPayload: Sendable {
    public var id: UUID
    public var kind: RecordKind
    public var revision: UUID
    public var modifiedAt: Date
    public var deviceID: String
    public var meta: Data
    public var body: Data?
    /// The body's wire format (`BodyFormat`); nil means legacy RTFD. The adapter sets it on export and reads it on
    /// apply, so the engine stays body-agnostic (web-app spec §3.4 item 2).
    public var bodyFormat: String?

    public init(id: UUID, kind: RecordKind, revision: UUID, modifiedAt: Date, deviceID: String, meta: Data, body: Data? = nil,
                bodyFormat: String? = nil) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.meta = meta
        self.body = body
        self.bodyFormat = bodyFormat
    }
}

/// Body format identifiers on the wire (web-app spec §3.4 item 8). Legacy RTFD has no identifier: the envelope
/// omits `bodyFormat`, and nothing inside the engine or the adapters ever names it.
public enum BodyFormat {
    public static let noteItDocV1 = "noteit-doc/1"
    /// sync-security's locked notes; valid only in a store with the `locked-notes` feature.
    public static let noteItLockedV1 = "noteit-locked/1"

    /// The wire rule: only nil (legacy), `noteItDocV1`, or `noteItLockedV1` in a store with `.lockedNotes` may be
    /// published. Called by `SyncEngine.push` right after `export`, before anything is persisted or sent.
    public static func validateForPublish(_ value: String?, features: Set<StoreFeature> = []) throws {
        switch value {
        case nil, noteItDocV1?: return
        case noteItLockedV1? where features.contains(.lockedNotes): return
        case let other?: throw SyncError.invalidPayload("bodyFormat: \(other.debugDescription) can't be published")
        }
    }

    /// The pairing rule: `bodyVersion` is present exactly when `bodyFormat` is a versioned format, and the format is
    /// one this store allows. Checked on publish and on pull.
    public static func validateEnvelope(_ envelope: RemoteEnvelope, features: Set<StoreFeature> = []) throws {
        switch envelope.bodyFormat {
        case nil:
            if envelope.bodyVersion != nil { throw SyncError.invalidPayload("bodyVersion: set without bodyFormat") }
        case noteItDocV1?, noteItLockedV1?:
            if envelope.bodyFormat == noteItLockedV1, !features.contains(.lockedNotes) {
                throw SyncError.invalidPayload("bodyFormat: \(noteItLockedV1) without the locked-notes feature")
            }
            if envelope.bodyVersion == nil { throw SyncError.invalidPayload("bodyVersion: missing for \(envelope.bodyFormat!)") }
        case let other?:
            throw SyncError.invalidPayload("bodyFormat: unknown \(other.debugDescription)")
        }
    }
}

/// Stored sealed at the record's meta key.
public struct RemoteEnvelope: Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: RecordKind
    public var revision: UUID
    public var modifiedAt: Date
    public var deviceID: String
    public var deviceName: String
    public var meta: Data
    public var bodySHA256: String?
    /// `BodyFormat.noteItDocV1` (or `noteItLockedV1`); omitted for legacy RTFD bodies at `notes/<id>.body`.
    public var bodyFormat: String?
    /// Names the versioned body object `bodies/<id>.<bodyVersion>.<TAG>.body`; set exactly when `bodyFormat` is.
    public var bodyVersion: UUID?

    public init(id: UUID, kind: RecordKind, revision: UUID, modifiedAt: Date, deviceID: String, deviceName: String, meta: Data,
                bodySHA256: String? = nil, bodyFormat: String? = nil, bodyVersion: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.meta = meta
        self.bodySHA256 = bodySHA256
        self.bodyFormat = bodyFormat
        self.bodyVersion = bodyVersion
    }
}

public struct Tombstone: Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: RecordKind
    public var deletedAt: Date
    public var deviceID: String
    /// The meta etag the deleter based its decision on; nil when it saw no meta (or in older tombstones).
    public var deletedMetaETag: String?

    public init(id: UUID, kind: RecordKind, deletedAt: Date, deviceID: String, deletedMetaETag: String? = nil) {
        self.id = id
        self.kind = kind
        self.deletedAt = deletedAt
        self.deviceID = deviceID
        self.deletedMetaETag = deletedMetaETag
    }
}

/// Where a device runs (foundations step 3). `DeviceInfo.platform` holds the raw value as a string, so a value
/// from a newer app survives.
public enum DevicePlatform: String, Codable, Sendable, CaseIterable {
    case mac, ios, web
}

public struct DeviceInfo: Codable, Sendable, Hashable {
    public var deviceID: String
    public var name: String
    public var lastSync: Date
    /// A `DevicePlatform` raw value; nil for older apps.
    public var platform: String?
    public var appVersion: String?
    /// `StoreFeature` raw values this app reads; nil counts as none.
    public var supportedFeatures: [String]?
    /// The rekey id (`Rekey.toKeyID`) this device acknowledged; written by sync-security.
    public var rekeyAck: String?

    public init(deviceID: String, name: String, lastSync: Date, platform: String? = nil, appVersion: String? = nil,
                supportedFeatures: [String]? = nil, rekeyAck: String? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.lastSync = lastSync
        self.platform = platform
        self.appVersion = appVersion
        self.supportedFeatures = supportedFeatures
        self.rekeyAck = rekeyAck
    }
}
