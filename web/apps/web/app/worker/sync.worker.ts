/// <reference lib="webworker" />
import {
  connect,
  decodeManifest,
  encodeJson,
  HttpProxyBackend,
  newUuid,
  openSession,
  type StoreSession,
  StorageError,
  storeExists,
  SyncEngine,
  SyncError,
  utf8,
} from '@noteit/core';
import type { BodyContainer } from '@noteit/doc';
import { Idb } from './idb';
import { WebLocalStore, WebStateStore } from './localStore';
import type { DeviceView, OpenedNote, Snapshot, SyncStatus, UnlockResult, WorkerEvent } from './types';

declare const self: DedicatedWorkerGlobalScope;

const DEBOUNCE_MS = 2_000;
const MAX_DELAY_MS = 10_000;
const VISIBLE_INTERVAL_MS = 60_000;
const HIDDEN_INTERVAL_MS = 600_000;
const LEGACY_RECHECK_MS = 60_000;

let db: Idb | undefined;
let userId = '';
let baseUrl = '';
let deviceID = '';
let deviceName = '';
let backend: HttpProxyBackend | undefined;
let local: WebLocalStore | undefined;
let state: WebStateStore | undefined;
let engine: SyncEngine | undefined;
let pendingPassphrase: string | undefined;
let channel: BroadcastChannel | undefined;
let visible = true;
let debounce: ReturnType<typeof setTimeout> | undefined;
let firstDirtyAt: number | undefined;
let interval: ReturnType<typeof setInterval> | undefined;
let legacyTimer: ReturnType<typeof setInterval> | undefined;
let running: Promise<void> | undefined;

const status: SyncStatus = { phase: 'locked', recordErrors: [], pending: 0 };

function emit(e: WorkerEvent): void {
  self.postMessage({ event: e });
}

async function setStatus(change: Partial<SyncStatus>): Promise<void> {
  Object.assign(status, change);
  if (local && state) status.pending = local.pendingCount((await state.load()).bases);
  emit({ type: 'status', status: { ...status } });
}

function defaultDeviceName(): string {
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
  const os = /Mac OS X/.test(ua) ? 'macOS' : /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iOS' : /Linux/.test(ua) ? 'Linux' : 'Web';
  return `Web — ${browser} on ${os}`;
}

// MARK: lifecycle

async function init(args: { userId: string; baseUrl: string }): Promise<{ deviceName: string; hasCache: boolean; hasStore?: boolean }> {
  userId = args.userId;
  baseUrl = args.baseUrl;
  db?.close();
  db = await Idb.open(`noteit-${userId}`);
  deviceID = (await db.get<string>('kv', 'deviceID')) ?? '';
  if (!deviceID) {
    deviceID = newUuid();
    await db.put('kv', 'deviceID', deviceID);
  }
  deviceName = (await db.get<string>('kv', 'deviceName')) ?? defaultDeviceName();
  backend = new HttpProxyBackend({ baseUrl, fetch: (i, init) => fetch(i, { ...init, credentials: 'same-origin' }) });
  channel?.close();
  channel = new BroadcastChannel(`noteit-${userId}`);
  // Another tab of this browser wrote to the shared library: reload, so this tab's editor and list see it now.
  channel.onmessage = async (m: MessageEvent<{ type: string }>) => {
    if (m.data.type === 'changed' && local) {
      await local.ensureFresh();
      emit({ type: 'changed' });
      void setStatus({});
    }
  };
  // Whether the account has a library yet, so a new account sees "Encrypt Your Notes" rather than an unlock screen
  // that would only discard the passphrase. Unknown (offline) falls back to the unlock screen.
  let hasStore: boolean | undefined;
  try {
    hasStore = await storeExists(backend);
  } catch {
    hasStore = undefined;
  }
  return { deviceName, hasCache: (await db.get('kv', 'manifest')) !== undefined, ...(hasStore === undefined ? {} : { hasStore }) };
}

function errorResult(e: unknown): UnlockResult {
  if (e instanceof SyncError) return { status: 'error', kind: e.kind, message: e.message };
  if (e instanceof StorageError) return { status: 'error', kind: e.kind, message: e.message };
  return { status: 'error', kind: 'unknown', message: e instanceof Error ? e.message : String(e) };
}

/** Opens the store (creating it when asked); falls back to the cached manifest when the server can't be reached. */
async function unlock(args: { passphrase: string; create: boolean }): Promise<UnlockResult> {
  if (!db || !backend) throw new Error('not initialized');
  let session: StoreSession;
  let created = false;
  try {
    const result = await connect(backend, { passphrase: args.passphrase, createIfMissing: args.create });
    session = result.session;
    created = result.created;
    await db.put('kv', 'manifest', { json: new TextDecoder().decode(encodeJson(session.manifest)), etag: session.manifestETag });
  } catch (e) {
    if (e instanceof SyncError && e.kind === 'legacyStore') {
      pendingPassphrase = args.passphrase;
      await setStatus({ phase: 'legacy' });
      startLegacyRecheck();
      return { status: 'legacy' };
    }
    if (e instanceof SyncError && e.kind === 'storeMissing') return { status: 'noStore' };
    const cached = await db.get<{ json: string; etag: string }>('kv', 'manifest');
    if (!(e instanceof StorageError && e.kind === 'network') || !cached) return errorResult(e);
    try {
      session = await openSession(decodeManifest(utf8(cached.json)), cached.etag, { passphrase: args.passphrase });
    } catch (offline) {
      return errorResult(offline);
    }
  }
  stopLegacyRecheck();
  pendingPassphrase = undefined;
  const keyID = session.keyID ?? 'plain';
  if ((await db.get<string>('kv', 'keyID')) !== keyID) {
    // Another store or key: the old cache can't be opened, start clean.
    await db.clear('records');
    await db.clear('pending');
    await db.delete('kv', 'deletions');
    await db.delete('kv', 'syncState');
    await db.put('kv', 'keyID', keyID);
  }
  const locks = (navigator as unknown as { locks?: LockManager }).locks;
  const exclusive = <T,>(fn: () => Promise<T>): Promise<T> => (locks ? (locks.request(`noteit-local-${userId}`, fn) as Promise<T>) : fn());
  local = new WebLocalStore(db, session.cipher, deviceID, () => new Date(), exclusive, deviceName);
  state = new WebStateStore(db, session.cipher);
  await local.load();
  await local.purgeExpired();
  local.onChange = () => markDirty();
  engine = new SyncEngine({ backend, session, local, state, deviceID, deviceName, appVersion: 'web' });
  await setStatus({ phase: 'idle' });
  startInterval();
  void syncNow();
  return { status: 'ok', created };
}

function startLegacyRecheck(): void {
  stopLegacyRecheck();
  legacyTimer = setInterval(() => void recheckLegacy(), LEGACY_RECHECK_MS);
}
function stopLegacyRecheck(): void {
  if (legacyTimer) clearInterval(legacyTimer);
  legacyTimer = undefined;
}
/** Re-checks a store without `noteit-doc`; continues on its own once a Mac has added the feature. */
async function recheckLegacy(): Promise<UnlockResult | undefined> {
  if (!pendingPassphrase) return undefined;
  const result = await unlock({ passphrase: pendingPassphrase, create: false });
  if (result.status === 'ok') emit({ type: 'changed' });
  return result;
}

function lock(): void {
  stopLegacyRecheck();
  if (interval) clearInterval(interval);
  if (debounce) clearTimeout(debounce);
  engine = undefined;
  local = undefined;
  state = undefined;
  pendingPassphrase = undefined;
  void setStatus({ phase: 'locked', recordErrors: [] });
}

async function forgetDevice(): Promise<void> {
  lock();
  db?.close();
  db = undefined;
  await Idb.delete(`noteit-${userId}`);
}

// MARK: scheduling

function startInterval(): void {
  if (interval) clearInterval(interval);
  interval = setInterval(() => void syncNow(), visible ? VISIBLE_INTERVAL_MS : HIDDEN_INTERVAL_MS);
}

function markDirty(): void {
  channel?.postMessage({ type: 'changed' });
  emit({ type: 'changed' });
  void setStatus({});
  const now = Date.now();
  firstDirtyAt ??= now;
  if (debounce) clearTimeout(debounce);
  const wait = Math.max(0, Math.min(DEBOUNCE_MS, firstDirtyAt + MAX_DELAY_MS - now));
  debounce = setTimeout(() => {
    firstDirtyAt = undefined;
    void syncNow();
  }, wait);
}

/** One pass at a time per tab; Web Locks keep tabs of the same account from running passes together. */
async function syncNow(): Promise<void> {
  if (!engine) return;
  if (running) return running;
  const pass = async () => {
    if (!engine) return;
    await setStatus({ phase: 'syncing' });
    try {
      const report = await engine.sync();
      const recordErrors = report.errors.map((message) => {
        const id = /^([0-9A-F-]{36}):/.exec(message)?.[1];
        return id ? { id, message: message.slice(38) } : { message };
      });
      await setStatus({ phase: 'idle', lastSync: Date.now(), recordErrors, detail: undefined });
      if (report.pulled + report.deleted + report.conflicts > 0) {
        channel?.postMessage({ type: 'changed' });
        emit({ type: 'changed' });
      }
    } catch (e) {
      if (e instanceof SyncError && e.kind === 'legacyStore') {
        await setStatus({ phase: 'legacy' });
        return;
      }
      if (e instanceof SyncError && (e.kind === 'keyChanged' || e.kind === 'wrongPassphrase')) {
        lock();
        await setStatus({ phase: 'locked', detail: 'The passphrase changed on another device. Unlock again.' });
        return;
      }
      const offline = e instanceof StorageError && e.kind === 'network';
      const unauthorized = e instanceof StorageError && e.kind === 'unauthorized';
      await setStatus({ phase: offline ? 'offline' : 'error', detail: unauthorized ? 'signedOut' : e instanceof Error ? e.message : String(e) });
    }
  };
  const locks = (navigator as unknown as { locks?: LockManager }).locks;
  running = (locks ? locks.request(`noteit-sync-${userId}`, pass).then(() => undefined) : pass()).finally(() => {
    running = undefined;
  });
  return running;
}

// MARK: RPC

function needLocal(): WebLocalStore {
  if (!local) throw new Error('locked');
  return local;
}

/** Requests still running; `close` waits for them so a save flushed on pagehide still reaches IndexedDB. */
let inflight = 0;
let idle: (() => void) | undefined;

/** pagehide: stop syncing and close IndexedDB, so the next page load (a reload) never waits on this connection. */
async function close(): Promise<void> {
  if (inflight > 1) await new Promise<void>((resolve) => (idle = resolve));
  if (interval) clearInterval(interval);
  if (debounce) clearTimeout(debounce);
  channel?.close();
  channel = undefined;
  db?.close();
}

const api = {
  init,
  close,
  unlock,
  recheckLegacy,
  lock: async () => lock(),
  forgetDevice,
  syncNow,
  setVisible: async (v: boolean) => {
    visible = v;
    if (engine) {
      startInterval();
      if (v) void syncNow();
    }
  },
  status: async () => ({ ...status }),
  snapshot: async (): Promise<Snapshot> => needLocal().snapshot(),
  search: async (q: string) => needLocal().search(q),
  getNote: async (id: string): Promise<OpenedNote | undefined> => needLocal().getNote(id),
  links: async (id: string) => needLocal().links(id),
  tasks: async () => needLocal().tasks(),
  setTaskChecked: async (id: string, block: number, checked: boolean) => needLocal().setTaskChecked(id, block, checked),
  createNote: async (opts: { notebookID?: string; container?: BodyContainer; createdAt?: string; updatedAt?: string; isPinned?: boolean }) => needLocal().createNote(opts),
  saveNote: async (id: string, container: BodyContainer, baseRevision?: string) => needLocal().saveNote(id, container, baseRevision),
  updateNoteMeta: async (id: string, change: { isPinned?: boolean; notebookID?: string | null; trashed?: boolean }) => needLocal().updateNoteMeta(id, change),
  deleteForever: async (id: string) => needLocal().deleteForever(id),
  createNotebook: async (opts: { name: string; colorHex: string; symbol: string; parent?: string }) => needLocal().createNotebook(opts),
  updateNotebook: async (id: string, change: { name?: string; colorHex?: string; symbol?: string; parent?: string | null }) => needLocal().updateNotebook(id, change),
  deleteNotebook: async (id: string) => needLocal().deleteNotebook(id),
  createSmartFolder: async (opts: { name: string; query: string; symbol?: string }) => needLocal().createSmartFolder(opts),
  updateSmartFolder: async (id: string, change: { name?: string; query?: string; symbol?: string }) => needLocal().updateSmartFolder(id, change),
  deleteSmartFolder: async (id: string) => needLocal().deleteSmartFolder(id),
  liveReminders: async () => needLocal().liveReminders(),
  /** Without sync (no engine yet) the reminder is shown: a duplicate is better than a missed one. */
  claimReminder: async (id: string, at: number) => (engine ? engine.claimReminder(id, new Date(at)) : 'unavailable'),
  sweepReminderClaims: async () => (engine ? engine.sweepReminderClaims(7 * 86_400) : 0),
  editTag: async (edit: { type: 'rename'; from: string; to: string } | { type: 'delete'; tag: string }) => needLocal().editTag(edit),
  devices: async (): Promise<DeviceView[]> => {
    if (!engine) return [];
    return (await engine.devices()).map((d) => ({ deviceID: d.deviceID, name: d.name, lastSync: (d.lastSync + 978307200) * 1000, ...(d.platform ? { platform: d.platform } : {}), current: d.deviceID === deviceID }));
  },
  setDeviceName: async (name: string) => {
    deviceName = name.trim() || defaultDeviceName();
    await db?.put('kv', 'deviceName', deviceName);
    return deviceName;
  },
};

export type WorkerApi = typeof api;

self.onmessage = async (m: MessageEvent<{ id: number; method: keyof WorkerApi; args: unknown[] }>) => {
  const { id, method, args } = m.data;
  inflight += 1;
  try {
    const fn = api[method] as (...a: unknown[]) => Promise<unknown>;
    const result = await fn(...args);
    self.postMessage({ id, result });
  } catch (e) {
    self.postMessage({ id, error: e instanceof Error ? e.message : String(e) });
  } finally {
    inflight -= 1;
    if (inflight <= 1 && idle) {
      const done = idle;
      idle = undefined;
      done();
    }
  }
};
