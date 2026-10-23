import type { RecordKind } from './layout.js';
import type { Uuid } from './uuid.js';

export type SyncAction = 'none' | 'push' | 'pull' | 'pushDeletion' | 'applyRemoteDeletion' | 'conflict' | 'resurrectPush' | 'forgetBase';

export interface LocalRecord {
  id: Uuid;
  kind: RecordKind;
  revision: Uuid;
  modifiedAt: Date;
}

export interface PlannerTombstone {
  deletedAt: Date;
  deletedMetaETag?: string;
}

export interface RemoteInfo {
  metaETag?: string;
  tombstone?: PlannerTombstone;
}

export interface Base {
  revision: Uuid;
  remoteMetaETag: string;
  replacedMetaETag?: string;
  bodyETag?: string;
  bodyVersion?: Uuid;
  /** The listed ETag of the body `bodyVersion` names (v2 stores). */
  docBodyETag?: string;
}

/** Exact port of SyncPlanner.decide (SyncPlanner.swift), row numbers as there. */
export function decide(
  local: Pick<LocalRecord, 'revision' | 'modifiedAt'> | undefined,
  localDeletedAt: Date | undefined,
  remote: RemoteInfo,
  base: Pick<Base, 'revision' | 'remoteMetaETag' | 'replacedMetaETag'> | undefined,
): SyncAction {
  const hasRemote = remote.metaETag !== undefined;

  if (local) {
    if (hasRemote) {
      if (!base) return 'conflict'; // 7
      const localChanged = local.revision !== base.revision;
      const remoteChanged = remote.metaETag !== base.remoteMetaETag;
      if (!localChanged && !remoteChanged) return 'none'; // 3
      if (localChanged && !remoteChanged) return 'push'; // 4
      if (!localChanged && remoteChanged) return 'pull'; // 5
      return 'conflict'; // 6
    }
    const tombstone = remote.tombstone;
    if (tombstone) {
      if (base) {
        const seen = tombstone.deletedMetaETag;
        if (seen !== undefined && seen !== base.remoteMetaETag && seen === base.replacedMetaETag) return 'resurrectPush';
        return local.revision !== base.revision ? 'resurrectPush' : 'applyRemoteDeletion'; // 12, 11
      }
      return local.modifiedAt.getTime() > tombstone.deletedAt.getTime() ? 'resurrectPush' : 'applyRemoteDeletion'; // 11
    }
    if (!base) return 'push'; // 1
    return local.revision !== base.revision ? 'push' : 'applyRemoteDeletion'; // 13
  }

  if (localDeletedAt !== undefined) {
    if (hasRemote && base) return remote.metaETag === base.remoteMetaETag ? 'pushDeletion' : 'pull'; // 8, 9
    if (remote.tombstone) return 'forgetBase'; // 15
    if (!hasRemote) return 'pushDeletion'; // 10
    return 'pull'; // 17
  }

  if (hasRemote && !base) return 'pull'; // 2
  if (remote.tombstone) return 'forgetBase'; // 14
  if (hasRemote) return 'pull'; // deviation: base, no journal entry
  if (base) return 'forgetBase'; // 16
  return 'none';
}
