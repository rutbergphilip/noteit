import type { Bytes } from './bytes.js';
import type { RemoteEnvelope } from './formats.js';
import type { Base } from './planner.js';
import type { Uuid } from './uuid.js';

export interface PendingBody {
  version: Uuid;
  tag: string;
  phase: 'uploading' | 'committing' | 'inDoubt';
  envelope: RemoteEnvelope;
  /** The meta ETag the commit is conditional on; absent for `new` (If-None-Match). */
  ifMatch?: string;
}

/** Device-local sync state (never uploaded), the web's shape of Swift SyncState. */
export interface SyncState {
  bases: Record<Uuid, Base>;
  tombstoneDates: Record<Uuid, number>;
  pendingPushes: Record<Uuid, Uuid>;
  pendingBodyVersions: Record<Uuid, PendingBody>;
  refusedRemotes: Record<Uuid, { metaETag: string; reason: string }>;
  lastDeviceWrite?: number;
  lastDeviceAck?: string;
  passCount: number;
}

export const emptySyncState = (): SyncState => ({
  bases: {},
  tombstoneDates: {},
  pendingPushes: {},
  pendingBodyVersions: {},
  refusedRemotes: {},
  passCount: 0,
});

export interface SyncStateStore {
  load(): Promise<SyncState>;
  save(s: SyncState): Promise<void>;
  /** Sealed body bytes of a pending version (spec §3.4.9 step 1), written before the entry, removed with it. */
  putPendingBody(id: Uuid, version: Uuid, sealed: Bytes): Promise<void>;
  getPendingBody(id: Uuid, version: Uuid): Promise<Bytes | undefined>;
  deletePendingBody(id: Uuid, version: Uuid): Promise<void>;
}

export class MemoryStateStore implements SyncStateStore {
  private state: string = JSON.stringify(emptySyncState());
  private pending = new Map<string, Bytes>();

  async load(): Promise<SyncState> {
    return { ...emptySyncState(), ...(JSON.parse(this.state) as SyncState) };
  }
  async save(s: SyncState): Promise<void> {
    this.state = JSON.stringify(s);
  }
  async putPendingBody(id: Uuid, version: Uuid, sealed: Bytes): Promise<void> {
    this.pending.set(`${id}.${version}`, sealed);
  }
  async getPendingBody(id: Uuid, version: Uuid): Promise<Bytes | undefined> {
    return this.pending.get(`${id}.${version}`);
  }
  async deletePendingBody(id: Uuid, version: Uuid): Promise<void> {
    this.pending.delete(`${id}.${version}`);
  }
}

export const TOMBSTONE_RETENTION_DAYS = 30;
export const DEVICE_WRITE_INTERVAL_S = 600;
