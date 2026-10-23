import { type Bytes, b64decode, b64encode, sha256Hex } from './bytes.js';
import { fromDouble2001, toDouble2001 } from './dates.js';
import { isFatal, RecordDeferred, RecordRefused, StorageError, SyncError } from './errors.js';
import {
  BODY_FORMAT_DOC_V1,
  BODY_FORMAT_LOCKED_V1,
  checkOpenable,
  decodeDevice,
  decodeEnvelope,
  decodeManifest,
  decodeTombstone,
  encodeEnvelope,
  encodeJson,
  type DeviceInfo,
  type RemoteEnvelope,
  rekeyIsStale,
  SUPPORTED_FEATURES,
  type Tombstone,
} from './formats.js';
import { baseTag, context, indexRemote, keys, NEW_TAG, type RecordKind, type RemoteIndex, ROOT } from './layout.js';
import { type Base, decide, type LocalRecord } from './planner.js';
import { manifestKeyID, type StoreSession } from './session.js';
import { DEVICE_WRITE_INTERVAL_S, type PendingBody, type SyncState, type SyncStateStore, TOMBSTONE_RETENTION_DAYS } from './state.js';
import type { StorageBackend } from './storage/backend.js';
import { newUuid, type Uuid } from './uuid.js';

/** Body fields a meta-only write keeps exactly as they were (legacy RTFD and locked notes in a noteit-doc store). */
export interface CarriedBody {
  bodySHA256?: string;
  bodyFormat?: string;
  bodyVersion?: Uuid;
}

export interface RecordPayload {
  id: Uuid;
  kind: RecordKind;
  revision: Uuid;
  modifiedAt: Date;
  deviceID: string;
  meta: Bytes;
  body?: Bytes;
  bodyFormat?: string;
  /** On export: publish only the meta, with these body fields. On pull: the envelope's body fields. */
  carriedBody?: CarriedBody;
}

export interface LocalDeletion {
  kind: RecordKind;
  deletedAt: Date;
}

export interface SyncLocalStore {
  records(): Promise<LocalRecord[]>;
  deletions(): Promise<Map<Uuid, LocalDeletion>>;
  export(id: Uuid, kind: RecordKind): Promise<RecordPayload>;
  /** Inserts or replaces the record, keeping `p.revision`. */
  apply(p: RecordPayload): Promise<void>;
  applyDeletion(id: Uuid, kind: RecordKind): Promise<void>;
  /** Imports the payload as a new record with a new id and a new revision. */
  importConflictCopy(p: RecordPayload, fromDevice: string): Promise<void>;
  clearDeletion(id: Uuid): Promise<void>;
  revision(id: Uuid, kind: RecordKind): Promise<Uuid | undefined>;
  passDidFinish(): Promise<void>;
}

export interface SyncReport {
  pushed: number;
  pulled: number;
  deleted: number;
  conflicts: number;
  skipped: number;
  errors: string[];
}

interface Pass {
  report: SyncReport;
  index: RemoteIndex;
  records: Map<Uuid, LocalRecord>;
  deletions: Map<Uuid, LocalDeletion>;
  seen: Set<Uuid>;
  importedCopies: boolean;
  touchedTombstones: Set<Uuid>;
}

interface FetchedRemote {
  envelope: RemoteEnvelope;
  etag: string;
  /** undefined when the body is missing or doesn't match `bodySHA256` (an upload in progress). */
  payload?: RecordPayload;
  bodyETag?: string;
}

export const SUPPORTED_FEATURE_NAMES = [...SUPPORTED_FEATURES].sort();

export class SyncEngine {
  session: StoreSession;
  private readonly backend: StorageBackend;
  private readonly local: SyncLocalStore;
  private readonly stateStore: SyncStateStore;
  private readonly deviceID: string;
  private readonly deviceName: string;
  private readonly appVersion: string | undefined;
  private readonly now: () => Date;
  private state!: SyncState;
  private tail: Promise<unknown> = Promise.resolve();

  constructor(opts: {
    backend: StorageBackend;
    session: StoreSession;
    local: SyncLocalStore;
    state: SyncStateStore;
    deviceID: string;
    deviceName: string;
    appVersion?: string;
    now?: () => Date;
  }) {
    this.backend = opts.backend;
    this.session = opts.session;
    this.local = opts.local;
    this.stateStore = opts.state;
    this.deviceID = opts.deviceID;
    this.deviceName = opts.deviceName;
    this.appVersion = opts.appVersion;
    this.now = opts.now ?? (() => new Date());
  }

  private get docMode(): boolean {
    return this.session.features.has('noteit-doc');
  }

  /** Passes are serialized. Throws only fatal errors; per-record failures land in `report.errors`. */
  sync(): Promise<SyncReport> {
    const run = this.tail.then(async () => {
      try {
        return await this.runPass();
      } finally {
        await this.local.passDidFinish();
      }
    });
    this.tail = run.catch(() => undefined);
    return run;
  }

  cleanupAvailable(): Promise<boolean> {
    return this.backend.atomicConditionalWrites();
  }

  // MARK: pass

  private async runPass(): Promise<SyncReport> {
    const index = indexRemote(await this.backend.list(ROOT));
    if (!index.manifest) throw new SyncError('storeMissing', 'the store has no manifest');
    await this.refreshSession(index.manifest.etag);
    this.state = await this.stateStore.load();
    this.state.passCount += 1;
    await this.handleForeignRekey();

    const records = await this.local.records();
    const pass: Pass = {
      report: { pushed: 0, pulled: 0, deleted: 0, conflicts: 0, skipped: 0, errors: [] },
      index,
      records: new Map(records.map((r) => [r.id, r])),
      deletions: await this.local.deletions(),
      seen: new Set(),
      importedCopies: false,
      touchedTombstones: new Set(),
    };
    const ids = new Set<Uuid>([
      ...pass.records.keys(),
      ...pass.deletions.keys(),
      ...index.metas.keys(),
      ...index.tombstones.keys(),
      ...Object.keys(this.state.bases),
      ...Object.keys(this.state.pendingBodyVersions),
    ]);
    for (const id of this.ordered(ids, pass)) await this.processSafely(id, pass);

    if (pass.importedCopies) {
      const fresh = (await this.local.records()).filter((r) => !pass.seen.has(r.id));
      for (const r of fresh) pass.records.set(r.id, r);
      for (const id of this.ordered(new Set(fresh.map((r) => r.id)), pass)) await this.processSafely(id, pass);
    }

    await this.guarded(pass, () => this.sweepTombstones(pass));
    await this.guarded(pass, () => this.writeDeviceRecordIfDue());
    await this.saveState();
    return pass.report;
  }

  /** Swaps the session when the listed manifest ETag changed; compares key identity, never salt or iterations. */
  private async refreshSession(listedETag: string): Promise<void> {
    if (listedETag === this.session.manifestETag) return;
    const { data, etag } = await this.backend.get(keys.manifest);
    const manifest = decodeManifest(data);
    const features = checkOpenable(manifest, this.session.supported);
    if ((await manifestKeyID(manifest)) !== this.session.keyID) {
      throw new SyncError('keyChanged', manifest.keyring?.changedBy ?? '');
    }
    if (this.docMode && !features.has('noteit-doc')) throw new SyncError('legacyStore');
    this.session = { ...this.session, manifest, manifestETag: etag, features };
  }

  /** A rekey owned by another device: acknowledge it in our device record, then stop the pass (spec §2.5). */
  private async handleForeignRekey(): Promise<void> {
    const rekey = this.session.manifest.rekey;
    if (!rekey || rekey.deviceID === this.deviceID) return;
    if (this.state.lastDeviceAck !== rekey.toKeyID) {
      await this.writeDeviceRecord(rekey.toKeyID);
      this.state.lastDeviceAck = rekey.toKeyID;
      await this.saveState();
    }
    if (rekeyIsStale(rekey, this.now())) throw new SyncError('rekeyIncomplete');
    throw new SyncError('rekeyInProgress', rekey.deviceName);
  }

  private ordered(ids: Set<Uuid>, pass: Pass): Uuid[] {
    const rank = (id: Uuid): number =>
      (pass.records.get(id)?.kind ?? pass.deletions.get(id)?.kind ?? pass.index.metas.get(id)?.kind) === 'notebook' ? 0 : 2;
    return [...ids].sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0));
  }

  private async guarded(pass: Pass, work: () => Promise<void>): Promise<void> {
    try {
      await work();
    } catch (e) {
      if (e instanceof RecordDeferred) pass.report.skipped += 1;
      else if (e instanceof StorageError && isFatal(e)) throw e;
      else pass.report.errors.push(String(e instanceof Error ? e.message : e));
    }
  }

  private async processSafely(id: Uuid, pass: Pass): Promise<void> {
    pass.seen.add(id);
    try {
      await this.process(id, pass);
    } catch (e) {
      if (e instanceof RecordDeferred) pass.report.skipped += 1;
      else if (e instanceof StorageError && isFatal(e)) throw e;
      else pass.report.errors.push(`${id}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private async process(id: Uuid, pass: Pass): Promise<void> {
    if (this.docMode && this.state.pendingBodyVersions[id]) {
      if ((await this.resolvePending(id, pass)) === 'skip') return;
    }
    const localRecord = pass.records.get(id);
    const deletion = pass.deletions.get(id);
    const remoteMeta = pass.index.metas.get(id);
    let metaETag = remoteMeta?.etag;
    const kind: RecordKind = localRecord?.kind ?? deletion?.kind ?? remoteMeta?.kind ?? 'note';

    let tombstone: Tombstone | undefined;
    if (pass.index.tombstones.has(id)) {
      if (localRecord || remoteMeta) tombstone = await this.fetchTombstone(id);
      else tombstone = { id, kind, deletedAt: -Infinity, deviceID: '' };
    }

    if (remoteMeta && tombstone) {
      let tombstoneWins: boolean;
      if (tombstone.deletedMetaETag !== undefined) tombstoneWins = tombstone.deletedMetaETag === remoteMeta.etag;
      else tombstoneWins = (await this.fetchEnvelope(id, remoteMeta.kind)).envelope.modifiedAt <= tombstone.deletedAt;
      if (tombstoneWins) {
        try {
          await this.backend.delete(keys.metaKey(id, remoteMeta.kind), { ifMatch: remoteMeta.etag });
        } catch (e) {
          if (e instanceof StorageError && e.kind === 'preconditionFailed') {
            pass.report.skipped += 1;
            return;
          }
          if (!(e instanceof StorageError && e.kind === 'notFound')) throw e;
        }
        if (remoteMeta.kind === 'note') await this.deleteBodies(id, pass);
        metaETag = undefined;
      } else {
        await this.deleteIfPresent(keys.tombstone(id));
        this.forgetTombstoneDate(id, pass);
        tombstone = undefined;
      }
    }

    const base = this.state.bases[id];
    const action = decide(
      localRecord,
      deletion?.deletedAt,
      {
        ...(metaETag !== undefined ? { metaETag } : {}),
        ...(tombstone
          ? {
              tombstone: {
                deletedAt: fromDouble2001(tombstone.deletedAt),
                ...(tombstone.deletedMetaETag !== undefined ? { deletedMetaETag: tombstone.deletedMetaETag } : {}),
              },
            }
          : {}),
      },
      base,
    );

    const refused = this.state.refusedRemotes[id];
    if (refused) {
      if (refused.metaETag !== metaETag) {
        delete this.state.refusedRemotes[id];
        await this.saveState();
      } else if (action === 'pull' || action === 'conflict') {
        pass.report.skipped += 1;
        pass.report.errors.push(`${id}: ${refused.reason}`);
        return;
      }
    }

    switch (action) {
      case 'none':
        if (!this.docMode && base && localRecord && kind === 'note' && base.bodyETag !== undefined &&
          base.bodyETag !== pass.index.bodies.get(id)?.etag && base.revision === localRecord.revision && metaETag === base.remoteMetaETag) {
          await this.repushBody(id, base, pass);
        }
        return;
      case 'push':
        if (localRecord) await this.push(id, localRecord.kind, metaETag, pass);
        return;
      case 'pull': {
        const metaKind = remoteMeta?.kind;
        if (!metaKind) return;
        if ((await this.pull(id, metaKind, localRecord?.revision, pass)) && deletion) await this.local.clearDeletion(id);
        return;
      }
      case 'conflict':
        if (localRecord) await this.resolveConflict(id, localRecord, pass);
        return;
      case 'pushDeletion':
        if (deletion) await this.pushDeletion(id, deletion, metaETag, pass);
        return;
      case 'applyRemoteDeletion':
        if (!localRecord) return;
        if ((await this.currentRevision(id)) !== localRecord.revision) {
          pass.report.skipped += 1;
          return;
        }
        await this.local.applyDeletion(id, localRecord.kind);
        delete this.state.bases[id];
        delete this.state.pendingPushes[id];
        await this.saveState();
        pass.report.deleted += 1;
        return;
      case 'resurrectPush':
        if (!localRecord) return;
        await this.deleteIfPresent(keys.tombstone(id));
        this.forgetTombstoneDate(id, pass);
        await this.push(id, localRecord.kind, undefined, pass);
        return;
      case 'forgetBase':
        if (base || this.state.pendingPushes[id]) {
          delete this.state.bases[id];
          delete this.state.pendingPushes[id];
          await this.saveState();
        }
        if (deletion) await this.local.clearDeletion(id);
        return;
    }
  }

  // MARK: actions

  /** Conditional on `remoteETag` (absence when undefined). Returns false when another writer got there first. */
  private async push(id: Uuid, kind: RecordKind, remoteETag: string | undefined, pass: Pass): Promise<boolean> {
    const payload = await this.local.export(id, kind);
    if (this.docMode && kind === 'note' && !payload.carriedBody) return this.publishDocBody(id, payload, remoteETag, pass);

    const envelope: RemoteEnvelope = {
      id,
      kind,
      revision: payload.revision,
      modifiedAt: toDouble2001(payload.modifiedAt),
      deviceID: this.deviceID,
      deviceName: this.deviceName,
      meta: b64encode(payload.meta),
    };
    if (payload.carriedBody) {
      const c = payload.carriedBody;
      if (c.bodySHA256 !== undefined) envelope.bodySHA256 = c.bodySHA256;
      if (c.bodyFormat !== undefined) envelope.bodyFormat = c.bodyFormat;
      if (c.bodyVersion !== undefined) envelope.bodyVersion = c.bodyVersion;
    } else if (payload.body) {
      envelope.bodySHA256 = await sha256Hex(payload.body);
    }
    const carriedBase = payload.carriedBody?.bodyFormat === BODY_FORMAT_LOCKED_V1 ? envelope : undefined;
    const encoded = encodeEnvelope(envelope, carriedBase);
    this.state.pendingPushes[id] = payload.revision;
    await this.saveState();
    const metaKey = keys.metaKey(id, kind);
    let newETag: string;
    try {
      newETag = await this.backend.put(metaKey, await this.seal(encoded, metaKey), remoteETag !== undefined ? { ifMatch: remoteETag } : { ifNoneMatch: true });
    } catch (e) {
      if (e instanceof StorageError && e.kind === 'preconditionFailed') {
        delete this.state.pendingPushes[id];
        await this.saveState();
        pass.report.skipped += 1;
        return false;
      }
      throw e;
    }
    let bodyETag: string | undefined;
    if (payload.body && !payload.carriedBody && !this.docMode) {
      bodyETag = await this.backend.put(keys.noteBody(id), await this.seal(payload.body, keys.noteBody(id)), {});
    }
    const nextBase: Base = { revision: payload.revision, remoteMetaETag: newETag };
    if (remoteETag !== undefined) nextBase.replacedMetaETag = remoteETag;
    if (bodyETag !== undefined) nextBase.bodyETag = bodyETag;
    if (payload.carriedBody?.bodyVersion) nextBase.bodyVersion = payload.carriedBody.bodyVersion;
    this.state.bases[id] = nextBase;
    delete this.state.pendingPushes[id];
    await this.saveState();
    pass.report.pushed += 1;
    return true;
  }

  /** Spec §3.4.9 publish order: seal once, persist, upload the version, then commit it with the meta write. */
  private async publishDocBody(id: Uuid, payload: RecordPayload, remoteETag: string | undefined, pass: Pass): Promise<boolean> {
    if (!payload.body) throw new SyncError('invalidPayload', 'note without a body');
    if (payload.bodyFormat !== BODY_FORMAT_DOC_V1) throw new SyncError('invalidPayload', `bodyFormat ${String(payload.bodyFormat)}`);
    const version = newUuid();
    const tag = remoteETag !== undefined ? await baseTag(remoteETag) : NEW_TAG;
    const envelope: RemoteEnvelope = {
      id,
      kind: 'note',
      revision: payload.revision,
      modifiedAt: toDouble2001(payload.modifiedAt),
      deviceID: this.deviceID,
      deviceName: this.deviceName,
      meta: b64encode(payload.meta),
      bodySHA256: await sha256Hex(payload.body),
      bodyFormat: BODY_FORMAT_DOC_V1,
      bodyVersion: version,
    };
    encodeEnvelope(envelope);
    const bodyKey = keys.docBody(id, version, tag);
    const sealed = await this.seal(payload.body, bodyKey);
    await this.stateStore.putPendingBody(id, version, sealed);
    const pending: PendingBody = { version, tag, phase: 'uploading', envelope, ...(remoteETag !== undefined ? { ifMatch: remoteETag } : {}) };
    this.state.pendingPushes[id] = payload.revision;
    this.state.pendingBodyVersions[id] = pending;
    await this.saveState();
    return this.uploadAndCommit(id, pending, sealed, pass);
  }

  private async uploadAndCommit(id: Uuid, pending: PendingBody, sealed: Bytes, pass: Pass): Promise<boolean> {
    const bodyKey = keys.docBody(id, pending.version, pending.tag);
    let bodyETag: string | undefined;
    try {
      bodyETag = await this.backend.put(bodyKey, sealed, { ifNoneMatch: true });
    } catch (e) {
      if (!(e instanceof StorageError)) throw e;
      if (isFatal(e)) throw e;
      if (e.kind !== 'preconditionFailed') {
        // In doubt: the entry stays `uploading` and the same bytes go to the same key next pass.
        pass.report.skipped += 1;
        return false;
      }
    }
    return this.commit(id, pending, true, pass, bodyETag);
  }

  private async commit(id: Uuid, pending: PendingBody, firstAttempt: boolean, pass: Pass, bodyETag?: string): Promise<boolean> {
    pending.phase = 'committing';
    this.state.pendingBodyVersions[id] = pending;
    await this.saveState();
    const metaKey = keys.noteMeta(id);
    let newETag: string;
    try {
      newETag = await this.backend.put(
        metaKey,
        await this.seal(encodeEnvelope(pending.envelope), metaKey),
        pending.ifMatch !== undefined ? { ifMatch: pending.ifMatch } : { ifNoneMatch: true },
      );
    } catch (e) {
      if (!(e instanceof StorageError) || isFatal(e)) throw e;
      if (e.kind === 'preconditionFailed') {
        let landed: { envelope: RemoteEnvelope; etag: string } | undefined;
        try {
          landed = await this.fetchEnvelope(id, 'note');
        } catch (err) {
          if (!(err instanceof StorageError && err.kind === 'notFound')) throw err;
        }
        if (landed && landed.envelope.bodyVersion === pending.version) {
          newETag = landed.etag;
        } else {
          if (firstAttempt) await this.deleteIfPresent(keys.docBody(id, pending.version, pending.tag));
          await this.clearPending(id, pending);
          pass.report.skipped += 1;
          return false;
        }
      } else {
        pending.phase = 'inDoubt';
        this.state.pendingBodyVersions[id] = pending;
        await this.saveState();
        pass.report.skipped += 1;
        return false;
      }
    }
    const previous = this.state.bases[id];
    const nextBase: Base = { revision: pending.envelope.revision, remoteMetaETag: newETag, bodyVersion: pending.version };
    if (pending.ifMatch !== undefined) nextBase.replacedMetaETag = pending.ifMatch;
    if (bodyETag !== undefined) nextBase.docBodyETag = bodyETag;
    this.state.bases[id] = nextBase;
    await this.clearPending(id, pending);
    pass.report.pushed += 1;
    await this.deletePreviousBody(id, previous, pending, pass);
    return true;
  }

  /** Step 6: only where conditional writes are atomic; failures are left to the orphan sweep. */
  private async deletePreviousBody(id: Uuid, previous: Base | undefined, pending: PendingBody, pass: Pass): Promise<void> {
    if (!previous || pending.ifMatch === undefined || previous.remoteMetaETag !== pending.ifMatch) return;
    try {
      if (!(await this.backend.atomicConditionalWrites())) return;
      const atomicDelete = await this.backend.atomicConditionalDelete();
      if (previous.bodyVersion && previous.bodyVersion !== pending.version) {
        const listed = pass.index.docBodies.get(id)?.get(previous.bodyVersion);
        if (listed && !listed.locked) await this.backend.delete(listed.key, atomicDelete ? { ifMatch: listed.etag } : {});
      } else if (!previous.bodyVersion && atomicDelete) {
        const legacy = pass.index.bodies.get(id);
        if (legacy) await this.backend.delete(legacy.key, { ifMatch: legacy.etag });
      }
    } catch (e) {
      if (e instanceof StorageError && isFatal(e)) throw e;
    }
  }

  private async clearPending(id: Uuid, pending: PendingBody): Promise<void> {
    await this.stateStore.deletePendingBody(id, pending.version);
    delete this.state.pendingBodyVersions[id];
    delete this.state.pendingPushes[id];
    await this.saveState();
  }

  /** Resolves a pending body version left by an earlier pass (spec §3.4.9 "Resolving a pending entry"). */
  private async resolvePending(id: Uuid, pass: Pass): Promise<'skip' | 'continue'> {
    const pending = this.state.pendingBodyVersions[id];
    if (!pending) return 'continue';
    const listed = pass.index.metas.get(id)?.etag;
    const live = pending.ifMatch !== undefined ? listed === pending.ifMatch : listed === undefined && !pass.index.tombstones.has(id);
    const phase = pending.phase === 'committing' ? 'inDoubt' : pending.phase;
    if (phase === 'uploading') {
      if (live) {
        const sealed = await this.stateStore.getPendingBody(id, pending.version);
        if (sealed) {
          await this.uploadAndCommit(id, pending, sealed, pass);
          return 'skip';
        }
      }
      const version = pass.index.docBodies.get(id)?.get(pending.version);
      if (version) {
        try {
          await this.backend.delete(version.key, (await this.backend.atomicConditionalDelete()) ? { ifMatch: version.etag } : {});
        } catch (e) {
          if (e instanceof StorageError && isFatal(e)) throw e;
        }
      }
      await this.clearPending(id, pending);
      return 'continue';
    }
    if (live) {
      await this.commit(id, pending, false, pass);
      return 'skip';
    }
    // The meta moved on: if it references our version, resolveConflict's same-revision branch adopts it.
    await this.stateStore.deletePendingBody(id, pending.version);
    delete this.state.pendingBodyVersions[id];
    await this.saveState();
    return 'continue';
  }

  /** Returns false (skipped) when the remote is mid-upload or the local record changed during the pass. */
  private async pull(id: Uuid, kind: RecordKind, expectedLocalRevision: Uuid | undefined, pass: Pass): Promise<boolean> {
    const remote = await this.fetchRemote(id, kind, pass);
    if (!remote.payload || (await this.currentRevision(id)) !== expectedLocalRevision) {
      pass.report.skipped += 1;
      return false;
    }
    try {
      await this.adopt(remote.payload, remote.etag, remote.envelope);
    } catch (e) {
      if (e instanceof RecordRefused) {
        await this.refuse(id, remote.etag, e.message, pass);
        return false;
      }
      throw e;
    }
    pass.report.pulled += 1;
    return true;
  }

  private async refuse(id: Uuid, metaETag: string, reason: string, pass: Pass): Promise<void> {
    this.state.refusedRemotes[id] = { metaETag, reason };
    await this.saveState();
    pass.report.skipped += 1;
    pass.report.errors.push(`${id}: ${reason}`);
  }

  private async adopt(payload: RecordPayload, etag: string, envelope: RemoteEnvelope): Promise<void> {
    await this.local.apply(payload);
    const base: Base = { revision: payload.revision, remoteMetaETag: etag };
    if (envelope.bodyVersion) base.bodyVersion = envelope.bodyVersion;
    this.state.bases[payload.id] = base;
    delete this.state.pendingPushes[payload.id];
    await this.saveState();
  }

  private async resolveConflict(id: Uuid, localRecord: LocalRecord, pass: Pass): Promise<void> {
    const kind = localRecord.kind;
    const remote = await this.fetchRemote(id, kind, pass);
    const envelope = remote.envelope;

    if (envelope.revision === localRecord.revision) {
      // Our own write from an interrupted pass: finish it instead of copying ourselves.
      let bodyETag = remote.bodyETag;
      if (!remote.payload && !this.docMode) {
        const payload = await this.local.export(id, kind);
        if (payload.revision !== envelope.revision) {
          await this.push(id, kind, remote.etag, pass);
          return;
        }
        if (payload.body) bodyETag = await this.backend.put(keys.noteBody(id), await this.seal(payload.body, keys.noteBody(id)), {});
      }
      const owned = envelope.deviceID === this.deviceID;
      const base: Base = { revision: envelope.revision, remoteMetaETag: remote.etag };
      if (owned && bodyETag !== undefined && !this.docMode) base.bodyETag = bodyETag;
      if (envelope.bodyVersion) base.bodyVersion = envelope.bodyVersion;
      this.state.bases[id] = base;
      delete this.state.pendingPushes[id];
      await this.saveState();
      return;
    }

    const base = this.state.bases[id];
    if (base && base.revision === envelope.revision) {
      await this.push(id, kind, remote.etag, pass);
      return;
    }

    if (envelope.deviceID === this.deviceID && (base !== undefined || this.state.pendingPushes[id] === envelope.revision || !remote.payload)) {
      await this.push(id, kind, remote.etag, pass);
      return;
    }

    if (kind === 'notebook') {
      const localMod = toDouble2001(localRecord.modifiedAt);
      const remoteWins = envelope.modifiedAt !== localMod ? envelope.modifiedAt > localMod : envelope.deviceID > this.deviceID;
      pass.report.conflicts += 1;
      if (remoteWins) {
        if (!remote.payload || (await this.currentRevision(id)) !== localRecord.revision) {
          pass.report.skipped += 1;
          return;
        }
        try {
          await this.adopt(remote.payload, remote.etag, envelope);
        } catch (e) {
          if (e instanceof RecordRefused) return this.refuse(id, remote.etag, e.message, pass);
          throw e;
        }
        pass.report.pulled += 1;
      } else {
        await this.push(id, kind, remote.etag, pass);
      }
      return;
    }

    if (!remote.payload) {
      pass.report.skipped += 1;
      return;
    }
    if (this.docMode && !remote.payload.body) {
      // The remote is a legacy or locked note the web can't read. Keep the local content as a copy and take the
      // remote, rather than overwrite a body we can't see.
      const mine = await this.local.export(id, kind);
      if (mine.body && !mine.carriedBody) {
        await this.local.importConflictCopy(mine, this.deviceName);
        pass.importedCopies = true;
      }
      pass.report.conflicts += 1;
      await this.adopt(remote.payload, remote.etag, envelope);
      pass.report.pulled += 1;
      return;
    }
    try {
      await this.local.importConflictCopy(remote.payload, envelope.deviceName);
    } catch (e) {
      if (e instanceof RecordRefused) return this.refuse(id, remote.etag, e.message, pass);
      throw e;
    }
    // Base becomes the remote version just preserved, so the next pass sees a plain push and never copies it again.
    const nextBase: Base = { revision: envelope.revision, remoteMetaETag: remote.etag };
    if (envelope.bodyVersion) nextBase.bodyVersion = envelope.bodyVersion;
    this.state.bases[id] = nextBase;
    await this.saveState();
    pass.report.conflicts += 1;
    pass.importedCopies = true;
    await this.push(id, kind, remote.etag, pass);
  }

  /** v1 stores: the meta is still ours, so the body slot is ours too; put it back unconditionally. */
  private async repushBody(id: Uuid, base: Base, pass: Pass): Promise<void> {
    const payload = await this.local.export(id, 'note');
    if (payload.revision !== base.revision || !payload.body) return;
    const etag = await this.backend.put(keys.noteBody(id), await this.seal(payload.body, keys.noteBody(id)), {});
    const current = this.state.bases[id];
    if (current) current.bodyETag = etag;
    await this.saveState();
    pass.report.pushed += 1;
  }

  /** Tombstone first, then a conditional meta delete; a lost race withdraws the tombstone (row 9). */
  private async pushDeletion(id: Uuid, deletion: LocalDeletion, metaETag: string | undefined, pass: Pass): Promise<void> {
    const tombstoneKey = keys.tombstone(id);
    const tombstone: Tombstone = { id, kind: deletion.kind, deletedAt: toDouble2001(deletion.deletedAt), deviceID: this.deviceID };
    if (metaETag !== undefined) tombstone.deletedMetaETag = metaETag;
    const tombstoneETag = await this.backend.put(tombstoneKey, await this.seal(encodeJson(tombstone), tombstoneKey), {});
    pass.touchedTombstones.add(id);
    if (metaETag !== undefined) {
      try {
        await this.backend.delete(keys.metaKey(id, deletion.kind), { ifMatch: metaETag });
      } catch (e) {
        if (e instanceof StorageError && e.kind === 'preconditionFailed') {
          try {
            await this.backend.delete(tombstoneKey, { ifMatch: tombstoneETag });
          } catch (err) {
            if (!(err instanceof StorageError && (err.kind === 'notFound' || err.kind === 'preconditionFailed'))) throw err;
          }
          pass.report.skipped += 1;
          return;
        }
        if (!(e instanceof StorageError && e.kind === 'notFound')) throw e;
      }
    }
    if (deletion.kind === 'note' && (metaETag !== undefined || pass.index.bodies.has(id) || pass.index.docBodies.has(id))) {
      await this.deleteBodies(id, pass);
    }
    this.state.tombstoneDates[id] = tombstone.deletedAt;
    delete this.state.bases[id];
    delete this.state.pendingPushes[id];
    await this.saveState();
    await this.local.clearDeletion(id);
    pass.report.deleted += 1;
  }

  private async deleteBodies(id: Uuid, pass: Pass): Promise<void> {
    if (pass.index.bodies.has(id) || !this.docMode) await this.deleteIfPresent(keys.noteBody(id));
    for (const version of pass.index.docBodies.get(id)?.values() ?? []) await this.deleteIfPresent(version.key);
  }

  private async sweepTombstones(pass: Pass): Promise<void> {
    const cutoff = toDouble2001(this.now()) - TOMBSTONE_RETENTION_DAYS * 86400;
    let changed = false;
    for (const id of [...pass.index.tombstones.keys()].sort()) {
      if (pass.touchedTombstones.has(id)) continue;
      const deletedAt = this.state.tombstoneDates[id];
      if (deletedAt === undefined || deletedAt >= cutoff) continue;
      await this.deleteIfPresent(keys.tombstone(id));
      delete this.state.tombstoneDates[id];
      changed = true;
    }
    const live = new Set([...pass.index.tombstones.keys(), ...pass.touchedTombstones]);
    for (const id of Object.keys(this.state.tombstoneDates)) {
      if (!live.has(id)) {
        delete this.state.tombstoneDates[id];
        changed = true;
      }
    }
    if (changed) await this.saveState();
  }

  private async writeDeviceRecordIfDue(): Promise<void> {
    const now = this.now().getTime();
    const last = this.state.lastDeviceWrite;
    if (last !== undefined && now - last < DEVICE_WRITE_INTERVAL_S * 1000 && now >= last) return;
    await this.writeDeviceRecord(this.state.lastDeviceAck);
    this.state.lastDeviceWrite = now;
    await this.saveState();
  }

  private async writeDeviceRecord(rekeyAck: string | undefined): Promise<void> {
    const info: DeviceInfo = {
      deviceID: this.deviceID,
      name: this.deviceName,
      lastSync: toDouble2001(this.now()),
      platform: 'web',
      supportedFeatures: SUPPORTED_FEATURE_NAMES,
    };
    if (this.appVersion) info.appVersion = this.appVersion;
    if (rekeyAck) info.rekeyAck = rekeyAck;
    const key = keys.device(this.deviceID);
    await this.backend.put(key, await this.seal(encodeJson(info), key), {});
  }

  /** Every device record, newest first (Settings → Devices). */
  async devices(): Promise<DeviceInfo[]> {
    const out: DeviceInfo[] = [];
    for (const object of await this.backend.list(`${ROOT}devices/`)) {
      try {
        out.push(decodeDevice(await this.open((await this.backend.get(object.key)).data, object.key)));
      } catch {
        // unreadable records are skipped
      }
    }
    return out.sort((a, b) => b.lastSync - a.lastSync);
  }

  // MARK: remote helpers

  private async fetchEnvelope(id: Uuid, kind: RecordKind): Promise<{ envelope: RemoteEnvelope; etag: string }> {
    const key = keys.metaKey(id, kind);
    const { data, etag } = await this.backend.get(key);
    const envelope = decodeEnvelope(await this.open(data, key), this.session.features.has('locked-notes'));
    if (envelope.id !== id || envelope.kind !== kind) throw new StorageError('invalidResponse', `envelope at ${key} describes another record`);
    return { envelope, etag };
  }

  private async fetchRemote(id: Uuid, kind: RecordKind, pass: Pass): Promise<FetchedRemote> {
    const { envelope, etag } = await this.fetchEnvelope(id, kind);
    const payload: RecordPayload = {
      id,
      kind,
      revision: envelope.revision,
      modifiedAt: fromDouble2001(envelope.modifiedAt),
      deviceID: envelope.deviceID,
      meta: b64decode(envelope.meta),
    };
    if (kind === 'notebook' || envelope.bodySHA256 === undefined) return { envelope, etag, payload };
    const carried: CarriedBody = { bodySHA256: envelope.bodySHA256 };
    if (envelope.bodyFormat !== undefined) carried.bodyFormat = envelope.bodyFormat;
    if (envelope.bodyVersion !== undefined) carried.bodyVersion = envelope.bodyVersion;

    if (envelope.bodyFormat === BODY_FORMAT_DOC_V1 && envelope.bodyVersion) {
      const listed = pass.index.docBodies.get(id)?.get(envelope.bodyVersion);
      if (!listed) return { envelope, etag };
      let sealed: { data: Bytes; etag: string };
      try {
        sealed = await this.backend.get(listed.key);
      } catch (e) {
        if (e instanceof StorageError && e.kind === 'notFound') return { envelope, etag };
        throw e;
      }
      const opened = await this.open(sealed.data, listed.key);
      if ((await sha256Hex(opened)) !== envelope.bodySHA256) return { envelope, etag };
      return { envelope, etag, bodyETag: sealed.etag, payload: { ...payload, body: opened, bodyFormat: BODY_FORMAT_DOC_V1, carriedBody: carried } };
    }
    if (this.docMode) {
      // Legacy RTFD or locked: the web never downloads or converts these bodies; it carries their fields.
      return { envelope, etag, payload: { ...payload, carriedBody: carried } };
    }
    let sealed: { data: Bytes; etag: string };
    try {
      sealed = await this.backend.get(keys.noteBody(id));
    } catch (e) {
      if (e instanceof StorageError && e.kind === 'notFound') return { envelope, etag };
      throw e;
    }
    const opened = await this.open(sealed.data, keys.noteBody(id));
    if ((await sha256Hex(opened)) !== envelope.bodySHA256) return { envelope, etag };
    return { envelope, etag, bodyETag: sealed.etag, payload: { ...payload, body: opened } };
  }

  private async fetchTombstone(id: Uuid): Promise<Tombstone | undefined> {
    const key = keys.tombstone(id);
    const tombstone = decodeTombstone(await this.open((await this.backend.get(key)).data, key));
    if (!tombstone) return undefined;
    if (tombstone.id !== id) throw new StorageError('invalidResponse', `tombstone at ${key} describes another record`);
    if (this.state.tombstoneDates[id] !== tombstone.deletedAt) {
      this.state.tombstoneDates[id] = tombstone.deletedAt;
      await this.saveState();
    }
    return tombstone;
  }

  private forgetTombstoneDate(id: Uuid, pass: Pass): void {
    pass.touchedTombstones.add(id);
    delete this.state.tombstoneDates[id];
  }

  private async deleteIfPresent(key: string): Promise<void> {
    try {
      await this.backend.delete(key);
    } catch (e) {
      if (!(e instanceof StorageError && e.kind === 'notFound')) throw e;
    }
  }

  private async currentRevision(id: Uuid): Promise<Uuid | undefined> {
    return (await this.local.revision(id, 'note')) ?? (await this.local.revision(id, 'notebook'));
  }

  private seal(plain: Uint8Array, key: string): Promise<Bytes> {
    return this.session.cipher.seal(plain, context(key));
  }

  private open(sealed: Uint8Array, key: string): Promise<Bytes> {
    return this.session.cipher.open(sealed, context(key));
  }

  private saveState(): Promise<void> {
    return this.stateStore.save(this.state);
  }
}
