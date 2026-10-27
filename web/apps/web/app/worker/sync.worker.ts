/// <reference lib="webworker" />
import {
  type CleanupReport,
  connect,
  decodeManifest,
  encodeJson,
  HttpProxyBackend,
  newUuid,
  openSession,
  randomBytes,
  sha256Hex,
  S3Backend,
  type StorageBackend,
  type StoreSession,
  type SyncCipher,
  StorageError,
  storeExists,
  SyncEngine,
  SyncError,
  utf8,
} from '@noteit/core';
import type { BodyContainer } from '@noteit/doc';
import { corsCheck, type CorsResult } from './corsCheck';
import { type DirectCredentials, normalizeCredentials, openCredentials, sealCredentials, VaultError, type VaultRecord } from './credentialVault';
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
let backend: StorageBackend | undefined;
/** Direct mode (spec §6.4): the browser talks to the user's bucket with the vault's key; no NoteIt server. */
let direct = false;
let directCreds: DirectCredentials | undefined;
let local: WebLocalStore | undefined;
let state: WebStateStore | undefined;
/** The unlocked store's cipher, for the unload journal's key. */
let cipher: SyncCipher | undefined;
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

async function init(args: { userId: string; baseUrl: string; direct?: boolean }): Promise<{ deviceName: string; hasCache: boolean; hasStore?: boolean; hasVault?: boolean }> {
  userId = args.userId;
  baseUrl = args.baseUrl;
  direct = !!args.direct;
  db?.close();
  db = await Idb.open(`noteit-${userId}`);
  deviceID = (await db.get<string>('kv', 'deviceID')) ?? '';
  if (!deviceID) {
    deviceID = newUuid();
    await db.put('kv', 'deviceID', deviceID);
  }
  deviceName = (await db.get<string>('kv', 'deviceName')) ?? defaultDeviceName();
  backend = direct ? undefined : new HttpProxyBackend({ baseUrl, fetch: (i, init) => fetch(i, { ...init, credentials: 'same-origin' }) });
  directCreds = undefined;
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
  const hasCache = (await db.get('kv', 'manifest')) !== undefined;
  // Direct mode: the bucket and its key are sealed in the vault until the passphrase opens it.
  if (direct) return { deviceName, hasCache, hasVault: (await db.get('kv', 'vault')) !== undefined };
  // Whether the account has a library yet, so a new account sees "Encrypt Your Notes" rather than an unlock screen
  // that would only discard the passphrase. Unknown (offline) falls back to the unlock screen.
  let hasStore: boolean | undefined;
  try {
    hasStore = await storeExists(backend!);
  } catch {
    hasStore = undefined;
  }
  return { deviceName, hasCache, ...(hasStore === undefined ? {} : { hasStore }) };
}

// MARK: direct mode

function s3For(creds: DirectCredentials): S3Backend {
  const c = normalizeCredentials(creds);
  return new S3Backend({ endpoint: c.endpoint, region: c.region, bucket: c.bucket, prefix: c.prefix, pathStyle: c.pathStyle, accessKeyId: c.accessKeyId, secretAccessKey: c.secretAccessKey });
}

/** The connect wizard's check (spec §6.4): CORS and credentials, then whether the bucket already holds a store. */
async function checkDirect(creds: DirectCredentials): Promise<{ cors: CorsResult; hasStore?: boolean }> {
  let s3: S3Backend;
  try {
    s3 = s3For(creds);
  } catch (e) {
    return { cors: { ok: false, problem: 'bucket', hint: 'That key prefix or endpoint is not valid.', detail: e instanceof Error ? e.message : String(e) } };
  }
  const cors = await corsCheck(s3);
  if (!cors.ok) return { cors };
  return { cors, hasStore: await storeExists(s3) };
}

/** Finishes the wizard: opens (or creates) the store, and only then seals the vault, replacing any older one. */
async function connectDirect(args: { creds: DirectCredentials; passphrase: string; create: boolean }): Promise<UnlockResult> {
  if (!db || !direct) throw new Error('not initialized');
  backend = s3For(args.creds);
  const result = await unlock({ passphrase: args.passphrase, create: args.create });
  // A store without noteit-doc yet (legacy) is still this bucket: keep it, and the recheck continues on its own.
  if (result.status !== 'ok' && result.status !== 'legacy') return result;
  directCreds = normalizeCredentials(args.creds);
  await db.put('kv', 'vault', await sealCredentials(args.passphrase, directCreds));
  return result;
}

/**
 * Unlock in direct mode: the vault, then the store, both with the passphrase. After a passphrase change on another
 * device the vault still opens with the previous one: pass it as `vaultPassphrase` and the current one as
 * `passphrase`, and the vault is resealed under the current one once it opens the store. Never writes to the store.
 */
async function unlockDirect(args: { passphrase: string; vaultPassphrase?: string }): Promise<UnlockResult> {
  if (!db || !direct) throw new Error('not initialized');
  const record = await db.get<VaultRecord>('kv', 'vault');
  if (!record) return { status: 'error', kind: 'noVault', message: 'This browser has no bucket set up.' };
  let creds: DirectCredentials;
  try {
    creds = await openCredentials(args.vaultPassphrase ?? args.passphrase, record);
  } catch (e) {
    if (e instanceof VaultError && e.kind === 'wrongPassphrase') return { status: 'error', kind: args.vaultPassphrase !== undefined ? 'wrongPreviousPassphrase' : 'wrongPassphrase', message: 'Wrong passphrase' };
    throw e;
  }
  backend = s3For(creds);
  const result = await unlock({ passphrase: args.passphrase, create: false });
  if (result.status === 'error' && result.kind === 'wrongPassphrase' && args.vaultPassphrase === undefined) {
    // The vault opened, so this was the passphrase this browser knew; the store has another one now.
    return { status: 'error', kind: 'passphraseChanged', message: 'Your sync passphrase was changed on another device. Enter the current one.' };
  }
  if (result.status !== 'ok') return result;
  directCreds = creds;
  if (args.vaultPassphrase !== undefined && args.vaultPassphrase !== args.passphrase) {
    // Write the new record first; it replaces the old one in the same put.
    await db.put('kv', 'vault', await sealCredentials(args.passphrase, creds));
  }
  return result;
}

/** What Settings shows about the bucket (never the secret). */
async function directInfo(): Promise<{ endpoint: string; bucket: string; prefix: string; region: string; writes: boolean; deletes: boolean } | undefined> {
  if (!directCreds || !(backend instanceof S3Backend)) return undefined;
  await backend.verifyConditionals();
  const { endpoint, bucket, prefix, region } = directCreds;
  return { endpoint, bucket, prefix, region, ...backend.capabilities };
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
  cipher = session.cipher;
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
  cipher = undefined;
  pendingPassphrase = undefined;
  if (direct) {
    backend = undefined;
    directCreds = undefined;
  }
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
      const detail = unauthorized ? (direct ? 'The bucket refused the access key. Check it in the bucket provider, then set up this browser again.' : 'signedOut') : e instanceof Error ? e.message : String(e);
      await setStatus({ phase: offline ? 'offline' : 'error', detail });
    }
  };
  const locks = (navigator as unknown as { locks?: LockManager }).locks;
  running = (locks ? locks.request(`noteit-sync-${userId}`, pass).then(() => undefined) : pass()).finally(() => {
    running = undefined;
  });
  return running;
}

// MARK: RPC

const JOURNAL_KEY_CONTEXT = 'web-unload-journal-key';

/**
 * The key the page seals its unload journal with (utils/unloadJournal.ts). It is kept in IndexedDB sealed by the store
 * key, so it can only be read while the library is unlocked; a new store or key makes a new one.
 */
async function journalKey(): Promise<Uint8Array> {
  if (!db || !cipher) throw new Error('locked');
  const sealed = await db.get<Uint8Array>('kv', 'journalKey');
  if (sealed) {
    try {
      return await cipher.open(sealed, JOURNAL_KEY_CONTEXT);
    } catch {
      // Sealed by another store key: replaced below.
    }
  }
  const raw = randomBytes(32);
  await db.put('kv', 'journalKey', await cipher.seal(raw, JOURNAL_KEY_CONTEXT));
  return raw;
}

/** Digests of the docs this browser saved lately, per note, so a replayed journal entry that did land is skipped. */
const SAVED_DIGESTS = 20;
const docDigest = async (container: BodyContainer) => (await sha256Hex(utf8(JSON.stringify(container.doc)))).slice(0, 32);

async function saveNote(id: string, container: BodyContainer, baseRevision?: string): Promise<{ revision: string; conflictCopy?: string }> {
  const digest = await docDigest(container);
  const saved = await needLocal().saveNote(id, container, baseRevision);
  if (db) {
    const recent = (await db.get<string[]>('kv', `saved:${id}`)) ?? [];
    await db.put('kv', `saved:${id}`, [digest, ...recent.filter((d) => d !== digest)].slice(0, SAVED_DIGESTS));
  }
  return saved;
}

/**
 * Saves an edit from the unload journal through the normal save path, unless this browser already saved exactly that
 * doc (the save landed before the page went away): replaying it then would turn later edits into a conflict copy.
 */
async function replayUnsaved(id: string, container: BodyContainer, baseRevision?: string): Promise<{ replayed: boolean; conflictCopy?: string }> {
  const recent = (await db?.get<string[]>('kv', `saved:${id}`)) ?? [];
  if (recent.includes(await docDigest(container))) return { replayed: false };
  const saved = await saveNote(id, container, baseRevision);
  return { replayed: true, ...(saved.conflictCopy ? { conflictCopy: saved.conflictCopy } : {}) };
}

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
  checkDirect,
  connectDirect,
  unlockDirect,
  directInfo,
  recheckLegacy,
  lock: async () => lock(),
  journalKey,
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
  searchDecorations: async (query: string, ids: string[]) => needLocal().searchDecorations(query, ids),
  tasks: async (query = '') => needLocal().tasks(query),
  setTaskChecked: async (id: string, block: number, checked: boolean) => needLocal().setTaskChecked(id, block, checked),
  createNote: async (opts: { id?: string; notebookID?: string; container?: BodyContainer; createdAt?: string; updatedAt?: string; isPinned?: boolean }) => needLocal().createNote(opts),
  saveNote,
  replayUnsaved,
  updateNoteMeta: async (id: string, change: { isPinned?: boolean; notebookID?: string | null; trashed?: boolean }) => needLocal().updateNoteMeta(id, change),
  deleteForever: async (id: string) => needLocal().deleteForever(id),
  createNotebook: async (opts: { name: string; colorHex: string; symbol: string; parent?: string }) => needLocal().createNotebook(opts),
  updateNotebook: async (id: string, change: { name?: string; colorHex?: string; symbol?: string; parent?: string | null }) => needLocal().updateNotebook(id, change),
  deleteNotebook: async (id: string) => needLocal().deleteNotebook(id),
  createSmartFolder: async (opts: { name: string; query: string; symbol?: string }) => needLocal().createSmartFolder(opts),
  updateSmartFolder: async (id: string, change: { name?: string; query?: string; symbol?: string }) => needLocal().updateSmartFolder(id, change),
  deleteSmartFolder: async (id: string) => needLocal().deleteSmartFolder(id),
  unlinkedMentions: async (id: string) => needLocal().unlinkedMentions(id),
  linkMentions: async (id: string, sources: string[]) => needLocal().linkMentions(id, sources),
  linkRenameCandidates: async (id: string, oldTitle: string, exclude?: string) => needLocal().linkRenameCandidates(id, oldTitle, exclude),
  rewriteLinkText: async (id: string, oldTitle: string, newTitle: string, exclude?: string) => needLocal().rewriteLinkText(id, oldTitle, newTitle, exclude),
  undoLinkRewrite: async (notes: { id: string; revision: string; before: BodyContainer }[]) => needLocal().undoLinkRewrite(notes),
  liveReminders: async () => needLocal().liveReminders(),
  /** Without sync (no engine yet) the reminder is shown: a duplicate is better than a missed one. */
  claimReminder: async (id: string, at: number) => (engine ? engine.claimReminder(id, new Date(at)) : 'unavailable'),
  sweepReminderClaims: async () => (engine ? engine.sweepReminderClaims(7 * 86_400) : 0),
  editTag: async (edit: { type: 'rename'; from: string; to: string } | { type: 'delete'; tag: string }) => needLocal().editTag(edit),
  devices: async (): Promise<DeviceView[]> => {
    if (!engine) return [];
    return (await engine.devices()).map((d) => ({ deviceID: d.deviceID, name: d.name, lastSync: (d.lastSync + 978307200) * 1000, ...(d.platform ? { platform: d.platform } : {}), current: d.deviceID === deviceID }));
  },
  /** Whether the storage has atomic conditional writes (S3 checks this with its canary). */
  cleanupAvailable: async () => (engine ? engine.cleanupAvailable() : false),
  /** "Clean Up Unused Storage…", only after the user confirmed it; held under the sync lock like a pass. */
  cleanUpUnusedStorage: async () => {
    const e = engine;
    if (!e) throw new Error('locked');
    if (running) await running.catch(() => undefined);
    const locks = (navigator as unknown as { locks?: LockManager }).locks;
    const run = () => e.cleanUpUnusedStorage();
    const report = await (locks ? (locks.request(`noteit-sync-${userId}`, run) as unknown as Promise<CleanupReport>) : run());
    // The cleanup ran a full pass first.
    await setStatus({ lastSync: Date.now() });
    return report;
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
