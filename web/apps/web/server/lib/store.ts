import type { DeleteResult, PutResult, StoredObject } from './diskStore';

export type { DeleteResult, PutResult, StoredObject } from './diskStore';

/**
 * A store driver (spec §6.2): every method takes the user's id, and keys are namespaced under it, so a driver has
 * no un-namespaced entry point. ETags are unquoted. `disk` (diskStore.ts) or upstream `s3` (s3Store.ts).
 */
export interface ObjectStore {
  readonly kind: 'disk' | 's3';
  /** Opens the store; throws when it can never work (an upstream without atomic conditional requests). */
  init(): Promise<void>;
  /** False until the store has been reached once; every route but the health checks answers 503 until then. */
  started(): boolean;
  /** Readiness for /api/health. */
  ready(): boolean;
  head(userId: string, key: string): Promise<{ etag: string; size: number; lastModified: number } | null>;
  get(userId: string, key: string): Promise<{ data: Uint8Array; etag: string; lastModified: number } | null>;
  put(userId: string, key: string, data: Uint8Array, cond: { ifMatch?: string; ifNoneMatch?: boolean }): Promise<PutResult>;
  delete(userId: string, key: string, cond: { ifMatch?: string }): Promise<DeleteResult>;
  /** Every object under `prefix`, sorted by key. */
  list(userId: string, prefix: string): Promise<StoredObject[]>;
  usage(userId: string): Promise<{ bytes: number; objects: number }>;
  deleteNamespace(userId: string): Promise<void>;
  /** Stops background work (the upstream probe). */
  close(): void;
}

/** The upstream store failed (network error, timeout, 5xx) or is misconfigured: 502 storeUnavailable. */
export class StoreUnavailable extends Error {}
