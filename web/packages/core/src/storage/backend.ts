import type { Bytes } from '../bytes.js';
import { StorageError } from '../errors.js';
import { isListablePrefix, isValidKey, LEGACY_ROOT, ROOT } from '../layout.js';

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

/**
 * Every backend refuses a key outside the layout grammar (layout.isValidKey) before any I/O, so no key with empty,
 * `.` or `..` segments, `%`, `\` or other characters can reach a URL path or a file path. Throws invalidResponse.
 */
export function assertValidKey(key: string): void {
  if (!isValidKey(key)) throw new StorageError('invalidResponse', `invalid key ${JSON.stringify(key)}`);
}

/** Reads may also name an Inkwell key whose `noteit/v1/` twin is valid (RemoteMigration's source); writes never. */
export function assertReadableKey(key: string): void {
  if (key.startsWith(LEGACY_ROOT) && isValidKey(ROOT + key.slice(LEGACY_ROOT.length))) return;
  assertValidKey(key);
}

/** Listing prefixes follow layout.isListablePrefix. */
export function assertListablePrefix(prefix: string): void {
  if (!isListablePrefix(prefix)) throw new StorageError('invalidResponse', `invalid prefix ${JSON.stringify(prefix)}`);
}

/** Strips `W/` and one pair of quotes. */
export function unquoteETag(etag: string): string {
  let e = etag.trim();
  if (e.startsWith('W/')) e = e.slice(2);
  if (e.length >= 2 && e.startsWith('"') && e.endsWith('"')) e = e.slice(1, -1);
  return e;
}
