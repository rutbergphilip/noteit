import { mkdir, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { AccountStore, ApiFailure, type User } from './accounts';
import { loadConfig, type ServerConfig } from './config';
import { DiskStore } from './diskStore';
import { S3Store } from './s3Store';
import type { ObjectStore } from './store';
import { Mutex } from './files';
import { BootstrapToken, RateLimiter, SessionSigner } from './sessions';

/** Per-user usage, recounted from disk on first use and then kept in step with every write. */
export class Quotas {
  private readonly usage = new Map<string, Promise<{ bytes: number; objects: number }>>();
  private readonly locks = new Map<string, Mutex>();
  constructor(private readonly store: ObjectStore) {}

  /**
   * Every write of one user runs head → admit → put → applied inside this, so concurrent PUTs can't each admit
   * against the same stale usage and overshoot the quota together.
   */
  exclusive<T>(userId: string, fn: () => Promise<T>): Promise<T> {
    let m = this.locks.get(userId);
    if (!m) this.locks.set(userId, (m = new Mutex()));
    return m.run(async () => {
      try {
        return await fn();
      } catch (e) {
        // A failed or timed-out store write may still have landed: recount from the store next time.
        this.forget(userId);
        throw e;
      }
    });
  }

  current(userId: string): Promise<{ bytes: number; objects: number }> {
    let u = this.usage.get(userId);
    if (!u) {
      u = this.store.usage(userId);
      this.usage.set(userId, u);
      u.catch(() => this.usage.delete(userId));
    }
    return u;
  }

  /** Admission for a write replacing an object of `previousSize` (undefined: a new object). Throws 507. */
  async admit(user: User, previousSize: number | undefined, size: number): Promise<void> {
    const u = await this.current(user.id);
    const bytes = u.bytes - (previousSize ?? 0) + size;
    const objects = u.objects + (previousSize === undefined ? 1 : 0);
    if (bytes > user.quotaBytes || objects > user.maxObjects) throw new ApiFailure(507, 'quotaExceeded', 'This account is out of storage.');
  }

  async applied(userId: string, previousSize: number | undefined, size: number | undefined): Promise<void> {
    const u = await this.current(userId);
    u.bytes += (size ?? 0) - (previousSize ?? 0);
    u.objects += (size === undefined ? 0 : 1) - (previousSize === undefined ? 0 : 1);
  }

  forget(userId: string): void {
    this.usage.delete(userId);
  }
}

export interface ServerContext {
  cfg: ServerConfig;
  store: ObjectStore;
  accounts: AccountStore;
  sessions: SessionSigner;
  bootstrap: BootstrapToken;
  quotas: Quotas;
  loginLimiter: RateLimiter;
  setupLimiter: RateLimiter;
  /** Serializes per-user writes so quota accounting stays exact. */
  log: (msg: string) => void;
}

export function createStore(cfg: ServerConfig, log: (msg: string) => void, fetchImpl?: typeof fetch): ObjectStore {
  if (cfg.store === 's3' && cfg.s3) return new S3Store({ ...cfg.s3, timeoutMs: cfg.storeTimeoutMs }, log, fetchImpl);
  return new DiskStore(cfg.dataDir);
}

export async function createContext(
  cfg: ServerConfig = loadConfig(),
  log: (msg: string) => void = console.log,
  store: ObjectStore = createStore(cfg, log),
): Promise<ServerContext> {
  await mkdir(cfg.dataDir, { recursive: true, mode: 0o700 });
  await store.init();
  const accounts = new AccountStore(cfg.dataDir);
  await accounts.load();
  // Finish deletions interrupted by a restart.
  // Finish deletions interrupted by a restart (a later start retries if the upstream is unreachable now).
  for (const user of store.started() ? accounts.users.filter((u) => u.status === 'deleting') : []) {
    try {
      await store.deleteNamespace(user.id);
    } catch (e) {
      log(`NoteIt: finishing the deletion of ${user.id} failed (${(e as Error).message}); it is retried on the next start`);
      continue;
    }
    await accounts.mutate((f) => {
      f.users = f.users.filter((u) => u.id !== user.id);
    });
  }
  const bootstrap = new BootstrapToken(cfg.dataDir, cfg.setupToken);
  await bootstrap.load(accounts.isEmpty, log);
  if (!accounts.isEmpty) await unlink(join(cfg.dataDir, 'setup-token')).catch(() => undefined);
  return {
    cfg,
    store,
    accounts,
    sessions: await SessionSigner.create(cfg.dataDir, cfg.sessionSecret),
    bootstrap,
    quotas: new Quotas(store),
    loginLimiter: new RateLimiter(10, 60_000),
    setupLimiter: new RateLimiter(10, 60_000),
    log,
  };
}

let shared: Promise<ServerContext> | undefined;
export function serverContext(): Promise<ServerContext> {
  shared ??= createContext();
  return shared;
}
