import Foundation

/// What `ensureFeature` did (foundations step 3). `lateBlockers`: devices that block the feature but weren't in
/// the list `confirm` saw, because their records appeared between the device check and the manifest write
/// (program §4 rule 4: the device list is a warning, not a fence). Empty when the feature was already set.
public struct FeatureAddition: Sendable {
    public let session: StoreSession
    public let lateBlockers: [FeatureBlocker]
}

extension SyncEngine {
    static let manifestWriteRetries = 3

    /// Read-modify-write of the manifest with `If-Match` (foundations step 3, program §4 rule 3). Keys `Manifest`
    /// doesn't own survive. Refuses a manifest with `rekey` set (rekeyInProgress), so it can start a rekey but
    /// never update or clear one. A 412 re-reads and re-checks before replaying `change`, up to 3 times.
    public static func updateManifest(backend: StorageBackend, session: StoreSession,
                                      _ change: @Sendable (inout Manifest) throws -> Void) async throws -> StoreSession {
        try await modifyManifest(backend: backend, session: session) { manifest in
            try change(&manifest)
            return true
        }
    }

    /// The only writer allowed while `rekey` is set (sync-security's heartbeat and finish). Every attempt requires
    /// `rekey?.toKeyID == expectedRekeyToKeyID`; `change` may touch only `rekey`, `keyring` and `encryption`.
    public static func updateRekey(backend: StorageBackend, session: StoreSession, expectedRekeyToKeyID: String,
                                   _ change: @Sendable (inout Manifest) throws -> Void) async throws -> StoreSession {
        try await writeManifest(backend: backend, session: session, check: { manifest in
            guard manifest.rekey?.toKeyID == expectedRekeyToKeyID else { throw SyncError.manifestChangedConcurrently }
            try checkSuits(manifest, session)
        }, change: { manifest in
            let before = manifest
            try change(&manifest)
            guard manifest.formatVersion == before.formatVersion, manifest.createdAt == before.createdAt,
                  (manifest.features ?? []).sorted() == (before.features ?? []).sorted() else {
                throw SyncError.invalidManifest("a rekey update may change only rekey, keyring and encryption")
            }
            return true
        })
    }

    /// Devices whose record says they can't read `feature` or anything it requires. A record without
    /// `supportedFeatures` supports nothing. The record of `currentDeviceID` never blocks.
    public static func devicesBlocking(_ feature: StoreFeature, backend: StorageBackend, session: StoreSession,
                                       currentDeviceID: String) async throws -> [FeatureBlocker] {
        let needed = Set([feature] + feature.requires).map(\.rawValue)
        let prefix = RemoteLayout.root + "devices/"
        var blockers: [FeatureBlocker] = []
        for object in try await backend.list(prefix: prefix) where object.key.hasSuffix(".json") {
            let recordID = String(object.key.dropFirst(prefix.count).dropLast(".json".count))
            let info: DeviceInfo
            do {
                let sealed = try await backend.get(object.key).data
                info = try decode(DeviceInfo.self, from: try session.cipher.open(sealed, context: context(object.key)))
            } catch StorageError.notFound {
                continue
            } catch let error as StorageError {
                throw error
            } catch {
                // An unreadable record can't say it supports anything.
                guard recordID != currentDeviceID else { continue }
                blockers.append(FeatureBlocker(deviceID: recordID, deviceName: recordID))
                continue
            }
            guard info.deviceID != currentDeviceID else { continue }
            let supported = Set(info.supportedFeatures ?? [])
            if needed.contains(where: { !supported.contains($0) }) {
                blockers.append(FeatureBlocker(deviceID: info.deviceID, deviceName: info.name, appVersion: info.appVersion,
                                               lastSync: info.lastSync))
            }
        }
        return blockers.sorted { ($0.deviceName, $0.deviceID) < ($1.deviceName, $1.deviceID) }
    }

    /// The only way to add a feature older apps can't read (program §4 rule 4). Adds `feature.requires` in the
    /// same write. Calls `confirm` only when a device blocks; `false` throws featureDeclined and writes nothing.
    public static func ensureFeature(_ feature: StoreFeature, backend: StorageBackend, session: StoreSession,
                                     currentDeviceID: String,
                                     confirm: @Sendable ([FeatureBlocker]) async -> Bool) async throws -> FeatureAddition {
        try await ensureFeature(feature, backend: backend, session: session, currentDeviceID: currentDeviceID,
                                supported: StoreFeature.supported, confirm: confirm)
    }

    static func ensureFeature(_ feature: StoreFeature, backend: StorageBackend, session: StoreSession, currentDeviceID: String,
                              supported: Set<StoreFeature>,
                              confirm: @Sendable ([FeatureBlocker]) async -> Bool) async throws -> FeatureAddition {
        if session.features.contains(feature) { return FeatureAddition(session: session, lateBlockers: []) }
        let needed = feature.requires + [feature]
        // A build never adds a feature it can't read.
        for item in needed where !supported.contains(item) { throw SyncError.unsupportedFeature(item.rawValue) }
        if let rekey = session.manifest.rekey { throw SyncError.rekeyInProgress(deviceName: rekey.deviceName) }

        let blockers = try await devicesBlocking(feature, backend: backend, session: session, currentDeviceID: currentDeviceID)
        if !blockers.isEmpty, !(await confirm(blockers)) { throw SyncError.featureDeclined(feature.rawValue) }

        let names = needed.map(\.rawValue)
        let updated = try await modifyManifest(backend: backend, session: session) { manifest in
            let current = Set(manifest.features ?? [])
            // A 412 re-read that already has the feature (same key ID, checked before this runs) is adopted.
            guard !names.allSatisfy(current.contains) else { return false }
            manifest.features = Array(current.union(names))
            return true
        }
        let seen = Set(blockers.map(\.deviceID))
        let after = try await devicesBlocking(feature, backend: backend, session: updated, currentDeviceID: currentDeviceID)
        return FeatureAddition(session: updated, lateBlockers: after.filter { !seen.contains($0.deviceID) })
    }

    // MARK: - Read-modify-write

    /// `change` returns false to adopt the manifest it was given without writing.
    private static func modifyManifest(backend: StorageBackend, session: StoreSession,
                                       _ change: (inout Manifest) throws -> Bool) async throws -> StoreSession {
        try await writeManifest(backend: backend, session: session, check: { manifest in
            if let rekey = manifest.rekey { throw SyncError.rekeyInProgress(deviceName: rekey.deviceName) }
            guard try keyID(of: manifest) == session.keyID else {
                throw SyncError.keyChanged(byDevice: manifest.keyring?.changedBy ?? "")
            }
            try checkSuits(manifest, session)
        }, change: change)
    }

    /// The manifest still suits the session: openable with `session.supported`, and no space feature in a library.
    private static func checkSuits(_ manifest: Manifest, _ session: StoreSession) throws {
        do {
            try checkOpenable(manifest, supported: session.supported)
            _ = try keyID(of: manifest)
        } catch {
            throw SyncError.manifestChangedConcurrently
        }
        if session.kind == .library, manifest.features?.contains(StoreFeature.noteItSpace.rawValue) == true {
            throw SyncError.manifestChangedConcurrently
        }
    }

    private static func writeManifest(backend: StorageBackend, session: StoreSession, check: (Manifest) throws -> Void,
                                      change: (inout Manifest) throws -> Bool) async throws -> StoreSession {
        var attempt = 0
        while true {
            let (data, rawETag) = try await backend.get(RemoteLayout.manifest())
            let etag = unquoted(rawETag)
            guard let stored = try? decode(Manifest.self, from: data) else {
                throw StorageError.invalidResponse("Unreadable manifest")
            }
            try check(stored)
            var manifest = stored
            guard try change(&manifest) else { return derivedSession(after: stored, etag: etag, from: session) }
            let features = Set(manifest.features ?? [])
            manifest.features = features.isEmpty ? nil : features.sorted()
            if !features.isEmpty { manifest.formatVersion = 2 }
            do {
                try checkOpenable(manifest, supported: session.supported)
                _ = try keyID(of: manifest)
            } catch {
                throw SyncError.invalidManifest("the change leaves a manifest this build can't open: \(error)")
            }
            let body = try mergedManifestJSON(manifest, into: data)
            do {
                let written = try await backend.put(RemoteLayout.manifest(), data: body, ifMatch: etag, ifNoneMatch: false)
                return derivedSession(after: manifest, etag: unquoted(written), from: session)
            } catch StorageError.preconditionFailed {
                attempt += 1
                guard attempt <= manifestWriteRetries else { throw SyncError.manifestChangedConcurrently }
            }
        }
    }

    /// Same key ID: keeps the cipher and `dataKey`. A changed key ID (a rekey finish) drops `dataKey`; the
    /// caller (sync-security) builds the session for the new key.
    private static func derivedSession(after manifest: Manifest, etag: String, from session: StoreSession) -> StoreSession {
        let keyID = try? keyID(of: manifest)
        if keyID == session.keyID { return session.replacing(manifest: manifest, etag: etag) }
        return StoreSession(kind: session.kind, manifest: manifest, manifestETag: etag, cipher: session.cipher, keyID: keyID,
                            features: StoreSession.features(of: manifest), supported: session.supported, dataKey: nil,
                            passedCipher: session.passedCipher)
    }

    /// `manifest` written over the stored JSON: only the keys `Manifest` owns change, unknown keys survive.
    static func mergedManifestJSON(_ manifest: Manifest, into stored: Data) throws -> Data {
        let encoded = try encode(manifest)
        guard var raw = try JSONSerialization.jsonObject(with: stored) as? [String: Any] else { return encoded }
        let owned = Set(Manifest.CodingKeys.allCases.map(\.stringValue))
        guard raw.keys.contains(where: { !owned.contains($0) }) else { return encoded }
        let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        for key in owned { raw[key] = fields[key] }
        return try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    }
}
