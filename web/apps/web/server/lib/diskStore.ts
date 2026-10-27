import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, readdir, readFile, rename, rm, rmdir, stat, unlink } from 'node:fs/promises';
import { join, relative, resolve, sep } from 'node:path';
import { isCanonicalUuid, isListablePrefix, isValidKey } from '@noteit/core';
import type { ObjectStore } from './store';

export interface StoredObject {
  key: string;
  etag: string;
  size: number;
  lastModified: number;
}

export type PutResult = { etag: string } | 'preconditionFailed';
export type DeleteResult = 'ok' | 'notFound' | 'preconditionFailed';

export class InvalidKeyError extends Error {}

/** Disk driver: one directory per user, ETag = hex MD5 of the bytes, conditionals atomic under a per-key mutex. */
export class DiskStore implements ObjectStore {
  readonly kind = 'disk';
  readonly usersRoot: string;
  private readonly tmpDir: string;
  private readonly locks = new Map<string, Promise<void>>();
  private readonly etagCache = new Map<string, { mtimeMs: number; size: number; etag: string }>();

  constructor(readonly dataDir: string) {
    this.usersRoot = resolve(dataDir, 'users');
    this.tmpDir = resolve(dataDir, 'tmp');
  }

  started(): boolean {
    return true;
  }

  ready(): boolean {
    return true;
  }

  close(): void {}

  async init(): Promise<void> {
    await mkdir(this.usersRoot, { recursive: true, mode: 0o700 });
    await rm(this.tmpDir, { recursive: true, force: true });
    await mkdir(this.tmpDir, { recursive: true, mode: 0o700 });
  }

  /** The namespace root of one user. The id must be a canonical UUID; nothing else ever names a directory. */
  userRoot(userId: string): string {
    if (!isCanonicalUuid(userId)) throw new InvalidKeyError('bad user id');
    return join(this.usersRoot, userId);
  }

  /**
   * The single choke point from a key to a path: the key must satisfy the layout grammar (no empty, `.` or `..`
   * segments, only [A-Za-z0-9._-]), and the resolved path must still be inside the user's root.
   */
  pathFor(userId: string, key: string): string {
    if (!isValidKey(key)) throw new InvalidKeyError(`invalid key ${JSON.stringify(key)}`);
    const root = this.userRoot(userId);
    const path = resolve(root, ...key.split('/'));
    if (!path.startsWith(root + sep)) throw new InvalidKeyError('key escapes the namespace');
    return path;
  }

  private async withLock<T>(id: string, fn: () => Promise<T>): Promise<T> {
    const previous = this.locks.get(id) ?? Promise.resolve();
    let release!: () => void;
    const current = new Promise<void>((r) => (release = r));
    const chained = previous.then(() => current);
    this.locks.set(id, chained);
    await previous;
    try {
      return await fn();
    } finally {
      release();
      if (this.locks.get(id) === chained) this.locks.delete(id);
    }
  }

  private async etagOf(path: string): Promise<{ etag: string; size: number; lastModified: number } | null> {
    let st;
    try {
      st = await lstat(path);
    } catch {
      return null;
    }
    if (!st.isFile()) return null;
    const cached = this.etagCache.get(path);
    if (cached && cached.mtimeMs === st.mtimeMs && cached.size === st.size) return { etag: cached.etag, size: st.size, lastModified: Math.floor(st.mtimeMs) };
    const etag = createHash('md5').update(await readFile(path)).digest('hex');
    this.etagCache.set(path, { mtimeMs: st.mtimeMs, size: st.size, etag });
    return { etag, size: st.size, lastModified: Math.floor(st.mtimeMs) };
  }

  async head(userId: string, key: string): Promise<{ etag: string; size: number; lastModified: number } | null> {
    return this.etagOf(this.pathFor(userId, key));
  }

  async get(userId: string, key: string): Promise<{ data: Uint8Array; etag: string; lastModified: number } | null> {
    const path = this.pathFor(userId, key);
    return this.withLock(path, async () => {
      const meta = await this.etagOf(path);
      if (!meta) return null;
      const data = await readFile(path);
      return { data: new Uint8Array(data), etag: createHash('md5').update(data).digest('hex'), lastModified: meta.lastModified };
    });
  }

  async put(userId: string, key: string, data: Uint8Array, cond: { ifMatch?: string; ifNoneMatch?: boolean }): Promise<PutResult> {
    const path = this.pathFor(userId, key);
    return this.withLock(path, async () => {
      const current = await this.etagOf(path);
      if (cond.ifNoneMatch && current) return 'preconditionFailed';
      if (cond.ifMatch !== undefined && current?.etag !== cond.ifMatch) return 'preconditionFailed';
      await mkdir(resolve(path, '..'), { recursive: true, mode: 0o700 });
      const tmp = join(this.tmpDir, randomUUID());
      const fh = await open(tmp, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
      try {
        await fh.writeFile(data);
        await fh.sync();
      } finally {
        await fh.close();
      }
      try {
        await rename(tmp, path);
      } catch (e) {
        await unlink(tmp).catch(() => undefined);
        throw e;
      }
      const etag = createHash('md5').update(data).digest('hex');
      const st = await stat(path);
      this.etagCache.set(path, { mtimeMs: st.mtimeMs, size: st.size, etag });
      return { etag };
    });
  }

  async delete(userId: string, key: string, cond: { ifMatch?: string }): Promise<DeleteResult> {
    const path = this.pathFor(userId, key);
    return this.withLock(path, async () => {
      const current = await this.etagOf(path);
      if (!current) return 'notFound';
      if (cond.ifMatch !== undefined && current.etag !== cond.ifMatch) return 'preconditionFailed';
      await unlink(path);
      this.etagCache.delete(path);
      await this.pruneEmptyDirs(userId, resolve(path, '..'));
      return 'ok';
    });
  }

  private async pruneEmptyDirs(userId: string, dir: string): Promise<void> {
    const root = this.userRoot(userId);
    let current = dir;
    while (current.startsWith(root + sep)) {
      try {
        await rmdir(current);
      } catch {
        return;
      }
      current = resolve(current, '..');
    }
  }

  /** Every object under `prefix`, sorted by key (UTF-8 byte order; keys are ASCII). */
  async list(userId: string, prefix: string): Promise<StoredObject[]> {
    if (prefix !== '' && !isListablePrefix(prefix)) throw new InvalidKeyError(`invalid prefix ${JSON.stringify(prefix)}`);
    const root = this.userRoot(userId);
    const out: StoredObject[] = [];
    const walk = async (dir: string): Promise<void> => {
      let entries;
      try {
        entries = await readdir(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const entry of entries) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) await walk(full);
        else if (entry.isFile()) {
          const key = relative(root, full).split(sep).join('/');
          if (!key.startsWith(prefix) || !isValidKey(key)) continue;
          const meta = await this.etagOf(full);
          if (meta) out.push({ key, ...meta });
        }
      }
    };
    // Start at the deepest directory the prefix names, never above the user's root.
    const dirPart = prefix.slice(0, prefix.lastIndexOf('/') + 1);
    const start = dirPart ? resolve(root, ...dirPart.split('/').filter(Boolean)) : root;
    if (start !== root && !start.startsWith(root + sep)) throw new InvalidKeyError('prefix escapes the namespace');
    await walk(start);
    return out.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  }

  async usage(userId: string): Promise<{ bytes: number; objects: number }> {
    const all = await this.list(userId, '');
    return { bytes: all.reduce((n, o) => n + o.size, 0), objects: all.length };
  }

  async deleteNamespace(userId: string): Promise<void> {
    await rm(this.userRoot(userId), { recursive: true, force: true });
  }
}
