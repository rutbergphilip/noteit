import Foundation

public enum RecordKind: String, Codable, Sendable {
    case notebook, note
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

    public init(id: UUID, kind: RecordKind, revision: UUID, modifiedAt: Date, deviceID: String, meta: Data, body: Data? = nil) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.meta = meta
        self.body = body
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

    public init(id: UUID, kind: RecordKind, revision: UUID, modifiedAt: Date, deviceID: String, deviceName: String, meta: Data, bodySHA256: String? = nil) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.meta = meta
        self.bodySHA256 = bodySHA256
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
