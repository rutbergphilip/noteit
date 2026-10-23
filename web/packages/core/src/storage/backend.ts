import type { Bytes } from '../bytes.js';

/** lastModified: ms since the epoch, when the backend reports it. */
export interface RemoteObject {
  key: string;
  etag: string;
  size: number;
  lastModified?: number;
}

export interface PutOptions {
  ifMatch?: string;
  ifNoneMatch?: boolean;
}

export interface StorageBackend {
  list(prefix: string): Promise<RemoteObject[]>;
  get(key: string): Promise<{ data: Bytes; etag: string }>;
  /** Returns the new ETag, unquoted. */
  put(key: string, data: Uint8Array, opts?: PutOptions): Promise<string>;
  delete(key: string, opts?: { ifMatch?: string }): Promise<void>;
  probe(): Promise<void>;
  atomicConditionalWrites(): Promise<boolean>;
  atomicConditionalDelete(): Promise<boolean>;
}

/** Strips `W/` and one pair of quotes. */
export function unquoteETag(etag: string): string {
  let e = etag.trim();
  if (e.startsWith('W/')) e = e.slice(2);
  if (e.length >= 2 && e.startsWith('"') && e.endsWith('"')) e = e.slice(1, -1);
  return e;
}
