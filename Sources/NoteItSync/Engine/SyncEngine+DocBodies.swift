import Foundation

/// What "Clean up unused storage…" removed (web-app spec §3.4.9).
public struct CleanupReport: Equatable, Sendable {
    public var deletedObjects: Int
    public var deletedBytes: Int64

    public init(deletedObjects: Int = 0, deletedBytes: Int64 = 0) {
        self.deletedObjects = deletedObjects
        self.deletedBytes = deletedBytes
    }
}

/// Versioned noteit-doc bodies, the upgrade to the `noteit-doc` feature, conversion and the orphan sweep (web-app
/// Task 0.4, spec §3.4 items 6, 7 and 9).
///
/// Publish order for a noteit-doc body: (1) seal once, persist the sealed bytes and a `PendingBody` in `uploading`;
/// (2) `PUT bodies/<id>.<V>.<TAG>.body` with `If-None-Match: *` (2xx or 412 both mean it is there); (3) persist
/// `committing`; (4) the meta `PUT` with `If-Match` on the base (or `If-None-Match` for `new`) is the commit point;
/// (5) save the base and clear the entry; (6) only where conditional writes are atomic, delete the previous body.
/// Nothing a reader can reach changes before step 4, and nothing here reads a clock.
extension SyncEngine {
    public static let bodyRepairGrace: TimeInterval = 86_400
    public static let strandedPasses = 20
    public static let strandedAge: TimeInterval = 86_400
    public static let maxRecoveryWritesPerPass = 5
    /// Only `cleanUpUnusedStorage()` reads it.
    public static let orphanBodyGracePeriod: TimeInterval = 30 * 86_400
    static let maxConversionsPerPass = 200
    static let maxOrphanDeletesPerPass = 200

    // MARK: - Sealed bytes of pending versions

    /// `PendingBodies/` next to the state file.
    var pendingBodiesDirectory: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("PendingBodies", isDirectory: true)
    }

    func pendingBodyURL(_ id: UUID, _ version: UUID) -> URL {
        pendingBodiesDirectory.appendingPathComponent("\(id.uuidString).\(version.uuidString)")
    }

    func clearPendingBody(_ id: UUID) {
        guard let entry = state.pendingBodyVersions.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: pendingBodyURL(id, entry.version))
        if state.pendingPushes[id] == entry.envelope.revision { state.pendingPushes[id] = nil }
    }

    private func bodyKey(_ id: UUID, _ entry: PendingBody) -> String {
        RemoteLayout.docBody(id, version: entry.version, tag: entry.tag)
    }

    // MARK: - Publish

    /// Steps 1–6 for a payload whose `bodyFormat` is noteit-doc. `remoteETag` is the meta this publish replaces (nil:
    /// none yet, so the tag is `new`). Returns false when the note was skipped (in doubt, or another writer won).
    func publishDoc(_ id: UUID, payload: RecordPayload, remoteETag: String?, _ pass: Pass) async throws -> Bool {
        if state.pendingBodyVersions[id] != nil {
            // Our in-doubt commit whose meta moved on: the planner already looked at that meta; nothing is deleted.
            guard pass.staleInDoubt.contains(id) else {
                pass.report.skipped += 1
                return false
            }
            clearPendingBody(id)
        }
        guard let body = payload.body else { throw SyncError.invalidPayload("bodyFormat without a body") }
        let version = newVersion()
        let tag = remoteETag.map(RemoteLayout.baseTag) ?? RemoteLayout.newTag
        let key = RemoteLayout.docBody(id, version: version, tag: tag)
        let envelope = RemoteEnvelope(
            id: id, kind: .note, revision: payload.revision, modifiedAt: payload.modifiedAt,
            deviceID: deviceID, deviceName: deviceName, meta: payload.meta,
            bodySHA256: Self.sha256Hex(body), bodyFormat: payload.bodyFormat, bodyVersion: version
        )
        try BodyFormat.validateEnvelope(envelope, features: session.current.features)
        let sealed = try seal(body, key: key)
        try FileManager.default.createDirectory(at: pendingBodiesDirectory, withIntermediateDirectories: true)
        try sealed.write(to: pendingBodyURL(id, version), options: .atomic)
        state.pendingPushes[id] = payload.revision
        state.pendingBodyVersions[id] = PendingBody(version: version, tag: tag, phase: .uploading, envelope: envelope)
        try saveState()
        pass.touched.insert(id)
        return try await uploadAndCommit(id, precondition: remoteETag, pass)
    }

    /// Steps 2–6 from the stored bytes, always to the same key.
    private func uploadAndCommit(_ id: UUID, precondition: String?, _ pass: Pass) async throws -> Bool {
        guard var entry = state.pendingBodyVersions[id] else { return false }
        guard let sealed = try? Data(contentsOf: pendingBodyURL(id, entry.version)) else {
            // The bytes are gone (a damaged state directory): this version can never be re-sent.
            clearPendingBody(id)
            try saveState()
            pass.report.skipped += 1
            return false
        }
        var bodyETag: String?
        do {
            bodyETag = try await backend.put(bodyKey(id, entry), data: sealed, ifMatch: nil, ifNoneMatch: true)
        } catch StorageError.preconditionFailed {
            // Only this device writes this key, always with these bytes: it's there.
        } catch let error as StorageError where !Self.isFatal(error) {
            // In doubt: the entry stays `uploading` and the request may still land.
            pass.report.skipped += 1
            return false
        }
        entry.phase = .committing
        state.pendingBodyVersions[id] = entry
        try saveState()
        return try await commit(id, precondition: precondition, firstAttempt: true, bodyETag: bodyETag, pass)
    }

    /// Step 4, then 5 and 6. A 412 is confirmed with a GET: our version there means an earlier attempt (or a silent
    /// replay) landed. Only a first attempt may delete its version after a definite 412.
    private func commit(_ id: UUID, precondition: String?, firstAttempt: Bool, bodyETag: String?, _ pass: Pass) async throws -> Bool {
        guard var entry = state.pendingBodyVersions[id] else { return false }
        let metaKey = RemoteLayout.meta(.note, id)
        let previous = previousBody(id, precondition: precondition, pass)
        var committedETag: String?
        do {
            committedETag = try await backend.put(metaKey, data: try seal(try Self.encode(entry.envelope), key: metaKey),
                                                  ifMatch: precondition, ifNoneMatch: precondition == nil)
        } catch StorageError.preconditionFailed {
            let current: (envelope: RemoteEnvelope, etag: String)?
            do {
                current = try await fetchEnvelope(id, kind: .note)
            } catch StorageError.notFound {
                current = nil
            } catch let error as StorageError where !Self.isFatal(error) {
                try markInDoubt(id, &entry, pass)
                return false
            } catch let error as StorageError {
                throw error
            } catch {
                current = nil   // unreadable: certainly not our envelope
            }
            if let current, current.envelope.bodyVersion == entry.version {
                committedETag = current.etag
            } else {
                if firstAttempt { try await deleteOwnVersion(id, entry, listedETag: bodyETag, pass) }
                clearPendingBody(id)
                try saveState()
                pass.report.skipped += 1
                return false
            }
        } catch let error as StorageError where !Self.isFatal(error) {
            try markInDoubt(id, &entry, pass)
            return false
        }
        guard let newETag = committedETag else { return false }

        // Step 5. bodyETag also marks the note as this device's publish, which body repair reads.
        let listed = pass.index.docBodies[id]?[entry.version]?.object.etag
        state.bases[id] = .init(revision: entry.envelope.revision, remoteMetaETag: newETag, replacedMetaETag: precondition,
                                bodyETag: bodyETag ?? listed ?? entry.version.uuidString, bodyVersion: entry.version)
        state.legacyBodies.remove(id)
        state.bodyMissingSince[id] = nil
        clearPendingBody(id)
        try saveState()
        pass.touched.insert(id)
        pass.report.pushed += 1

        // Step 6: with the HEAD-verify fallback a meta write checked earlier could still land and name the previous
        // body again, so it is kept there.
        if pass.atomicWrites, let previous {
            do {
                if previous.versioned {
                    if pass.atomicDeletes {
                        try await deleteIfUnchanged(previous.key, listedETag: previous.etag)
                    } else {
                        try await backend.delete(previous.key)   // an immutable key
                    }
                } else if pass.atomicDeletes {
                    try await deleteIfUnchanged(previous.key, listedETag: previous.etag)
                }
            } catch let error as StorageError where Self.isFatal(error) {
                throw error
            } catch {
                // The orphan sweep removes it later.
            }
        }
        return true
    }

    private func markInDoubt(_ id: UUID, _ entry: inout PendingBody, _ pass: Pass) throws {
        entry.phase = .inDoubt
        state.pendingBodyVersions[id] = entry
        try saveState()
        pass.report.skipped += 1
    }

    /// The body the meta at `precondition` referenced, when this device knows it (its base is that meta).
    private func previousBody(_ id: UUID, precondition: String?, _ pass: Pass) -> (key: String, etag: String, versioned: Bool)? {
        guard let precondition, let base = state.bases[id], base.remoteMetaETag == precondition else { return nil }
        if let version = base.bodyVersion {
            return pass.index.docBodies[id]?[version].map { ($0.object.key, $0.object.etag, true) }
        }
        return pass.index.bodies[id].map { (RemoteLayout.body(id), $0, false) }
    }

    /// Deletes a version this device uploaded and never committed. Its key is immutable, so without atomic
    /// conditional deletes a plain delete is safe.
    private func deleteOwnVersion(_ id: UUID, _ entry: PendingBody, listedETag: String?, _ pass: Pass) async throws {
        let key = bodyKey(id, entry)
        do {
            if pass.atomicDeletes, let etag = listedETag ?? pass.index.docBodies[id]?[entry.version]?.object.etag {
                try await backend.delete(key, ifMatch: etag)
            } else {
                try await backend.delete(key)
            }
        } catch let error as StorageError where Self.isFatal(error) {
            throw error
        } catch {
            // Best effort; the orphan sweep removes a stale-tag version where that is safe.
        }
    }

    // MARK: - Resolving pending entries

    /// Runs at the start of every pass for each entry (spec §3.4.9 "Resolving a pending entry"). An entry loaded in
    /// `committing` (a crash while the meta request was out) counts as `inDoubt`.
    func resolvePendingBody(_ id: UUID, _ pass: Pass) async throws {
        guard var entry = state.pendingBodyVersions[id] else { return }
        let listedMeta = pass.index.metas[id]?.etag
        let live = entry.tag == RemoteLayout.newTag
            ? listedMeta == nil && pass.index.tombstones[id] == nil
            : listedMeta.map { RemoteLayout.baseTag($0) == entry.tag } ?? false
        switch entry.phase {
        case .uploading:
            if live {
                pass.touched.insert(id)
                _ = try await uploadAndCommit(id, precondition: listedMeta, pass)
            } else {
                // No commit of this version can succeed any more, and this device will never send one.
                if pass.index.docBodies[id]?[entry.version] != nil {
                    try await deleteOwnVersion(id, entry, listedETag: nil, pass)
                }
                clearPendingBody(id)
                try saveState()
            }
        case .committing, .inDoubt:
            if entry.phase == .committing {
                entry.phase = .inDoubt
                state.pendingBodyVersions[id] = entry
                try saveState()
            }
            if live {
                // Re-send the same commit: same version, tag, revision and precondition, sealed afresh.
                pass.touched.insert(id)
                _ = try await commit(id, precondition: listedMeta, firstAttempt: false,
                                     bodyETag: pass.index.docBodies[id]?[entry.version]?.object.etag, pass)
            } else {
                // The planner sees the note first and adopts our write if the meta references our version.
                pass.staleInDoubt.insert(id)
            }
        }
    }

    /// After the planner: in-doubt entries whose meta moved on and doesn't reference them are dropped, deleting
    /// nothing; the orphan sweep removes the version where that is safe.
    func dropStaleInDoubtEntries(_ pass: Pass) async throws {
        var changed = false
        for id in pass.staleInDoubt where state.pendingBodyVersions[id] != nil {
            clearPendingBody(id)
            changed = true
        }
        if changed { try saveState() }
    }

    // MARK: - Body repair

    /// The meta this device holds references a version that is not listed. Its publisher republishes at once (new
    /// version, same revision); any other device waits `bodyRepairGrace`, and racing repairers end with one winner.
    func repairDocBodyIfMissing(_ id: UUID, version: UUID, base: SyncState.Base, _ pass: Pass) async throws {
        guard pass.index.docBodies[id]?[version] == nil else {
            if state.bodyMissingSince.removeValue(forKey: id) != nil { try saveState() }
            return
        }
        guard state.pendingBodyVersions[id] == nil, session.current.features.contains(.noteItDoc) else { return }
        let since: Date
        if let known = state.bodyMissingSince[id] {
            since = known
        } else {
            since = now()
            state.bodyMissingSince[id] = since
            try saveState()
        }
        guard base.bodyETag != nil || now().timeIntervalSince(since) >= Self.bodyRepairGrace else {
            pass.report.skipped += 1
            return
        }
        try await push(id, kind: .note, remoteETag: base.remoteMetaETag, pass, requireDoc: true)
    }

    // MARK: - Conversion sweep

    /// Republishes legacy RTFD notes as noteit-doc with the same revision (spec §3.4 item 7), at most 200 per pass.
    /// Each conversion is a normal versioned publish against `base.remoteMetaETag`; peers pull it once.
    func convertLegacyBodies(_ pass: Pass) async throws {
        var converted = 0
        var changed = false
        for id in state.legacyBodies.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard converted < Self.maxConversionsPerPass else { break }
            guard let base = state.bases[id], base.bodyVersion == nil else {
                state.legacyBodies.remove(id)
                changed = true
                continue
            }
            // A changed remote goes through the planner first; this pass's own writes are already in `base`.
            if !pass.touched.contains(id), pass.index.metas[id]?.etag != base.remoteMetaETag { continue }
            guard state.pendingBodyVersions[id] == nil,
                  state.pendingPushes[id] == nil || state.pendingPushes[id] == base.revision,
                  await currentRevision(id) == base.revision else { continue }
            converted += 1
            try await guardedRecord(id, pass) {
                try await self.push(id, kind: .note, remoteETag: base.remoteMetaETag, pass, requireDoc: true)
            }
        }
        if changed { try saveState() }
    }

    // MARK: - Orphan sweep

    /// Deletes bodies nothing can reference any more (spec §3.4.9), at most 200 per pass, each with `If-Match` on its
    /// listed ETag. Needs atomic conditional deletes at all; bodies (not just unparsable names) also need atomic
    /// conditional writes. Never touches this device's pending version, a note whose listed meta isn't the one this
    /// device knows, a body whose tag matches the listed meta, or a `new` body of a note without meta or tombstone.
    func sweepOrphanBodies(_ pass: Pass) async throws {
        guard pass.atomicDeletes else { return try forgetStrandedBodies(except: []) }
        var budget = Self.maxOrphanDeletesPerPass
        func remove(_ object: RemoteObject) async throws {
            guard budget > 0 else { return }
            budget -= 1
            try await deleteIfUnchanged(object.key, listedETag: object.etag)
        }
        for object in pass.index.strayBodies { try await remove(object) }
        guard pass.atomicWrites else {
            try forgetStrandedBodies(except: [])
            return
        }

        var stranded: [String: UUID] = [:]
        for (id, versions) in pass.index.docBodies.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where !pass.touched.contains(id) {
            let listedMeta = pass.index.metas[id]?.etag
            let tombstoned = pass.index.tombstones[id] != nil
            let base = state.bases[id]
            for (version, body) in versions.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                if state.pendingBodyVersions[id]?.version == version { continue }
                let deletable: Bool
                if let listedMeta {
                    // Only a meta this device has read says which version it references.
                    guard let base, base.remoteMetaETag == listedMeta else { break }
                    let unreferenced = base.bodyVersion != version
                    let liveTag = body.tag == RemoteLayout.baseTag(listedMeta)
                    deletable = unreferenced && !liveTag
                    // Kept only because its tag is live: its writer may still commit it, or was wiped.
                    if unreferenced, liveTag { stranded[body.object.key] = id }
                } else {
                    // Without a meta: a `new` body may belong to a create still in flight, unless a tombstone exists.
                    deletable = tombstoned || body.tag != RemoteLayout.newTag
                }
                if deletable { try await remove(body.object) }
            }
        }
        try await recoverStrandedBodies(stranded, pass)
        for (id, etag) in pass.index.bodies.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where !pass.touched.contains(id) {
            if let listedMeta = pass.index.metas[id]?.etag {
                guard let base = state.bases[id], base.remoteMetaETag == listedMeta, base.bodyVersion != nil else { continue }
            } else if pass.index.tombstones[id] == nil {
                continue
            }
            try await remove(RemoteObject(key: RemoteLayout.body(id), etag: etag, size: 0))
        }
    }

    // MARK: - Stranded bodies

    /// Keeps `strandedBodies` to the bodies stranded now (spec §3.4.9 "Stranded bodies: meta refresh"); once a note's
    /// body has been stranded for `strandedPasses` passes and `strandedAge`, refreshes the note's meta so that its tag
    /// goes stale and the next sweep deletes it, at most `maxRecoveryWritesPerPass` notes per pass. The pass count and
    /// the clock decide only when to refresh, never whether a delete is safe. Only on atomic stores (the caller's).
    private func recoverStrandedBodies(_ stranded: [String: UUID], _ pass: Pass) async throws {
        try forgetStrandedBodies(except: Set(stranded.keys))
        guard !stranded.isEmpty else { return }
        let now = now()
        for key in stranded.keys where state.strandedBodies[key] == nil {
            state.strandedBodies[key] = .init(firstSeenPass: state.passCount, firstSeenAt: now)
        }
        try saveState()

        var due: Set<UUID> = []
        for (key, id) in stranded {
            guard let seen = state.strandedBodies[key] else { continue }
            if state.passCount - seen.firstSeenPass >= Self.strandedPasses, now.timeIntervalSince(seen.firstSeenAt) >= Self.strandedAge {
                due.insert(id)
            }
        }
        var refreshes = 0
        for id in due.sorted(by: { $0.uuidString < $1.uuidString }) where refreshes < Self.maxRecoveryWritesPerPass {
            if try await refreshMeta(id, pass) { refreshes += 1 }
        }
    }

    /// Drops the entries of bodies no longer stranded or no longer listed.
    private func forgetStrandedBodies(except keys: Set<String>) throws {
        let kept = state.strandedBodies.filter { keys.contains($0.key) }
        guard kept.count != state.strandedBodies.count else { return }
        state.strandedBodies = kept
        try saveState()
    }

    /// The recovery write: the same envelope plaintext sealed again (a fresh nonce, so a new ETag of the same size),
    /// `If-Match` the listed meta. Only for a noteit-doc meta this device knows, with no unpushed edit and no pending
    /// entry. A 412 or an in-doubt outcome leaves nothing to resolve. Whether a write was sent.
    private func refreshMeta(_ id: UUID, _ pass: Pass) async throws -> Bool {
        guard let listed = pass.index.metas[id], listed.kind == .note, let base = state.bases[id],
              base.remoteMetaETag == listed.etag, base.bodyVersion != nil,
              pass.records[id]?.revision == base.revision,
              state.pendingBodyVersions[id] == nil, state.pendingPushes[id] == nil,
              !pass.touched.contains(id) else { return false }
        let key = RemoteLayout.meta(.note, id)
        do {
            let (data, etag) = try await backend.get(key)
            guard etag == listed.etag else { return false }
            let plaintext = try open(data, key: key)
            let envelope = try Self.decode(RemoteEnvelope.self, from: plaintext)
            guard envelope.id == id, envelope.kind == .note, envelope.bodyFormat != nil,
                  envelope.revision == base.revision, envelope.bodyVersion == base.bodyVersion else { return false }
            try BodyFormat.validateEnvelope(envelope, features: session.current.features)
            let newETag = try await backend.put(key, data: try seal(plaintext, key: key), ifMatch: listed.etag, ifNoneMatch: false)
            state.bases[id]?.remoteMetaETag = newETag
            pass.touched.insert(id)
            try saveState()
            return true
        } catch let error as StorageError where Self.isFatal(error) {
            throw error
        } catch {
            // 412: the meta moved on. In doubt: the next pass lists whichever ETag is current. Either way, nothing to do.
            return true
        }
    }

    // MARK: - Upgrade

    func canUpgrade(after report: SyncReport) -> Bool {
        let current = session.current
        return upgradesAutomatically && current.kind == .library && report.errors.isEmpty
            && !current.features.contains(.noteItDoc) && current.supported.contains(.noteItDoc)
    }

    /// The upgrade, then a normal pass (which ends with the conversion sweep). Nil when the store stays as it is.
    func runUpgrade() async throws -> SyncReport? {
        guard try await addNoteItDoc() else { return nil }
        return try await runPass()
    }

    /// Adds `noteit-doc` through `ensureFeature` (device check, read-modify-write, adoption of a concurrent upgrade)
    /// and swaps the session. Public only for tests; `sync()` calls it after a clean pass.
    public func upgradeToV2() async throws -> StoreSession {
        try await serialized {
            if await self.session.current.supported.contains(.noteItDoc) { _ = try await self.addNoteItDoc() }
            return await self.session.current
        }
    }

    /// Declines, a rekey and non-fatal failures leave the store as it is for a later clean pass; `keyChanged` and
    /// fatal storage errors propagate.
    private func addNoteItDoc() async throws -> Bool {
        let current = session.current
        guard !current.features.contains(.noteItDoc) else { return true }
        guard current.manifest.rekey == nil else { return false }
        if let beforeUpgradeHook { await beforeUpgradeHook() }
        do {
            let addition = try await Self.ensureFeature(.noteItDoc, backend: backend, session: current, currentDeviceID: deviceID,
                                                        supported: current.supported, confirm: featureConfirm)
            session.replace(addition.session)
            if !addition.lateBlockers.isEmpty { await lateBlockersHandler(addition.lateBlockers) }
            return addition.session.features.contains(.noteItDoc)
        } catch SyncError.featureDeclined, SyncError.rekeyInProgress {
            return false
        } catch let error as SyncError {
            if case .keyChanged = error { throw error }
            NSLog("NoteItSync: noteit-doc upgrade postponed: %@", String(describing: error))
            return false
        } catch let error as StorageError {
            if Self.isFatal(error) { throw error }
            NSLog("NoteItSync: noteit-doc upgrade postponed: %@", String(describing: error))
            return false
        }
    }

    // MARK: - Clean up unused storage

    /// Settings → Sync enables "Clean up unused storage…" only when this is true.
    public func cleanupAvailable() async -> Bool {
        await backend.atomicConditionalWrites()
    }

    /// Only ever called from the confirmed Settings action. Runs a pass, then deletes every `new` body whose note has
    /// neither meta nor tombstone, that isn't this device's pending version, and whose listed `lastModified` is
    /// older than `orphanBodyGracePeriod` (a body listed without one is kept). A creator still committing such a
    /// body after it was deleted loses the note's content: the confirmation warns about idle devices.
    public func cleanUpUnusedStorage() async throws -> CleanupReport {
        guard await backend.atomicConditionalWrites() else { throw SyncError.cleanupUnavailable }
        let cutoff = now().addingTimeInterval(-Self.orphanBodyGracePeriod)
        return try await serialized {
            _ = try await self.runPass()
            return try await self.deleteUnusedNewBodies(before: cutoff)
        }
    }

    private func deleteUnusedNewBodies(before cutoff: Date) async throws -> CleanupReport {
        let index = RemoteIndex(try await backend.list(prefix: RemoteLayout.root))
        let atomicDeletes = await backend.atomicConditionalDelete()
        var report = CleanupReport()
        for (id, versions) in index.docBodies where index.metas[id] == nil && index.tombstones[id] == nil {
            for (version, body) in versions where body.tag == RemoteLayout.newTag && state.pendingBodyVersions[id]?.version != version {
                guard let modified = body.object.lastModified, modified < cutoff else { continue }
                do {
                    if atomicDeletes {
                        try await backend.delete(body.object.key, ifMatch: body.object.etag)
                    } else {
                        try await backend.delete(body.object.key)   // an immutable key
                    }
                } catch StorageError.notFound {
                    continue
                } catch StorageError.preconditionFailed {
                    continue
                }
                report.deletedObjects += 1
                report.deletedBytes += Int64(body.object.size)
            }
        }
        return report
    }
}
