/**
 * Interop harness, web half (scripts/interop_tests.sh). Skipped unless NOTEIT_INTEROP_URL and NOTEIT_INTEROP_DIR are
 * set. It drives the web app's real worker code (WebLocalStore + @noteit/core's SyncEngine over HttpProxyBackend)
 * against a running server, the way the browser's sync worker does, and takes turns with the Swift half
 * (Tests/NoteItTests/LiveInteropTests.swift, the real NoteStore + NoteStoreSyncAdapter over the server's /s3) through
 * marker files in NOTEIT_INTEROP_DIR:
 *
 *   web-1  setup, an S3 key for the Mac, an encrypted store; notebook, notes, tags, tasks with @due and @remind,
 *          a pinned note and a smart folder; synced                         → config.json, web.json
 *   mac-1  the Mac pulls and checks them field by field; edits, checks a task, adds, renames and deletes
 *   web-2  the web pulls and checks the Mac's changes; edits "Plan" without syncing
 *   mac-2  the Mac edits "Plan" too and syncs first
 *   web-3  the web syncs: one conflict copy, both edits kept
 *   mac-3  the Mac pulls: the same single conflict copy
 */
import { existsSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { connect, HttpProxyBackend, SyncEngine } from '@noteit/core';
import { type BodyContainer, emptyContainer, type NoteItDoc } from '@noteit/doc';
import { describe, expect, it } from 'vitest';
import type { StoreName } from '../../app/worker/idb';
import { type KeyValue, WebLocalStore, WebStateStore } from '../../app/worker/localStore';

const URL_ = process.env.NOTEIT_INTEROP_URL;
const DIR = process.env.NOTEIT_INTEROP_DIR;
const SETUP_TOKEN = process.env.NOTEIT_INTEROP_SETUP_TOKEN ?? 'interop-setup-token-0123';
const PASSPHRASE = 'interop passphrase across implementations';
const STEP_TIMEOUT_MS = Number(process.env.NOTEIT_INTEROP_STEP_TIMEOUT_MS ?? 600_000);

class MemoryKV implements KeyValue {
  private stores = new Map<StoreName, Map<string, unknown>>();
  private s(n: StoreName) {
    let m = this.stores.get(n);
    if (!m) this.stores.set(n, (m = new Map()));
    return m;
  }
  async get<T>(n: StoreName, k: string) {
    return this.s(n).get(k) as T | undefined;
  }
  async all<T>(n: StoreName) {
    return [...this.s(n).entries()] as [string, T][];
  }
  async put(n: StoreName, k: string, v: unknown) {
    this.s(n).set(k, v);
  }
  async delete(n: StoreName, k: string) {
    this.s(n).delete(k);
  }
  async clear(n: StoreName) {
    this.s(n).clear();
  }
  async bump() {
    const before = (this.s('kv').get('generation') as number | undefined) ?? 0;
    this.s('kv').set('generation', before + 1);
    return before;
  }
}

/** A same-origin browser tab: keeps the session cookie, sends Origin. Drops request options undici doesn't take. */
function tab(base: string) {
  let cookie: string | undefined;
  const f = async (input: RequestInfo | URL, init: RequestInit = {}): Promise<Response> => {
    const headers = new Headers(init.headers);
    if (cookie) headers.set('cookie', cookie);
    headers.set('origin', base);
    const { cache: _c, credentials: _cr, ...rest } = init;
    const url = typeof input === 'string' && input.startsWith('/') ? base + input : input;
    const res = await fetch(url, { ...rest, headers });
    const set = res.headers.get('set-cookie');
    if (set) cookie = set.split(';')[0];
    return res;
  };
  const action = async <T>(name: string, input?: unknown, method: 'GET' | 'POST' = 'POST'): Promise<T> => {
    const res = await f(`/api/_actions/${name}`, method === 'GET' ? {} : { method, headers: { 'content-type': 'application/json' }, body: JSON.stringify(input ?? {}) });
    const body = (await res.json()) as { data?: T; serverError?: unknown; businessError?: unknown; validationErrors?: unknown };
    if (body.data === undefined) throw new Error(`${name}: ${JSON.stringify(body)}`);
    return body.data;
  };
  return { fetch: f as typeof fetch, action };
}

const para = (...runs: (string | { text: string; bold?: boolean })[]): NoteItDoc['content'][number] => ({
  type: 'paragraph',
  content: runs.map((r) => (typeof r === 'string' ? { type: 'text', text: r } : { type: 'text', text: r.text, ...(r.bold ? { marks: [{ type: 'bold' }] } : {}) })),
});
const task = (text: string, checked: boolean): NoteItDoc['content'][number] => ({ type: 'listItem', attrs: { kind: 'task', level: 0, checked }, content: [{ type: 'text', text }] }) as NoteItDoc['content'][number];
const doc = (...content: NoteItDoc['content']): BodyContainer => ({ ...emptyContainer(), doc: { type: 'doc', content } });
const plainText = (c: BodyContainer | undefined) => JSON.stringify(c?.doc ?? {});

async function waitFor(marker: string): Promise<void> {
  const file = join(DIR!, `${marker}.done`);
  const started = Date.now();
  while (!existsSync(file)) {
    if (existsSync(join(DIR!, 'mac.failed'))) throw new Error('the Swift half failed; see its log');
    if (Date.now() - started > STEP_TIMEOUT_MS) throw new Error(`timed out waiting for ${marker}`);
    await new Promise((r) => setTimeout(r, 250));
  }
}
const done = (marker: string) => writeFile(join(DIR!, `${marker}.done`), new Date().toISOString());

describe.skipIf(!URL_ || !DIR)('interop: web ⇄ Mac through the server (web half)', () => {
  it('round-trips notes, notebooks, tags, tasks, reminders, a smart folder and a conflict', { timeout: STEP_TIMEOUT_MS * 4 }, async () => {
    try {
      await run();
    } catch (e) {
      await writeFile(join(DIR!, 'web.failed'), String(e instanceof Error ? (e.stack ?? e.message) : e));
      throw e;
    }
  });
});

async function run(): Promise<void> {
  const base = URL_!.replace(/\/$/, '');
  const t = tab(base);

  // MARK: web-1 — the first admin, an S3 key for the Mac, the store and content.
  await t.action('setup', { token: SETUP_TOKEN, username: 'interop', password: 'interop-password-1' });
  const key = await t.action<{ accessKeyId: string; secretAccessKey: string }>('account/create-s3-key', { label: 'Mac interop' });
  await writeFile(join(DIR!, 'config.json'), JSON.stringify({ endpoint: `${base}/s3`, bucket: 'noteit', region: 'us-east-1', accessKeyId: key.accessKeyId, secretAccessKey: key.secretAccessKey, passphrase: PASSPHRASE }));

  const backend = new HttpProxyBackend({ baseUrl: base, fetch: t.fetch });
  const { session, created } = await connect(backend, { passphrase: PASSPHRASE, createIfMissing: true });
  expect(created).toBe(true);
  expect([...session.features]).toContain('noteit-doc');
  const kv = new MemoryKV();
  const local = new WebLocalStore(kv, session.cipher, 'WEB-INTEROP', () => new Date(), undefined, 'Web Interop');
  await local.load();
  const engine = new SyncEngine({ backend, session, local, state: new WebStateStore(kv, session.cipher), deviceID: 'WEB-INTEROP', deviceName: 'Web Interop', appVersion: 'web-interop' });
  const sync = async () => {
    const report = await engine.sync();
    expect(report.errors, report.errors.join('\n')).toEqual([]);
    return report;
  };

  const work = await local.createNotebook({ name: 'Work', colorHex: '#FF9500', symbol: 'briefcase' });
  const plan = await local.createNote({
    notebookID: work,
    container: doc(
      para('Plan #project'),
      para('Ship the ', { text: 'release', bold: true }, ' on time'),
      task('ship it @due(2026-11-02)', false),
      task('write notes', true),
      task('call Sam @remind(2026-11-01 09:00)', false),
    ),
  });
  await local.updateNoteMeta(plan, { isPinned: true });
  const loose = await local.createNote({ container: doc(para('Loose #misc'), para('no notebook')) });
  const folder = await local.createSmartFolder({ name: 'Projects', query: 'tag:project' });
  await sync();
  await writeFile(join(DIR!, 'web.json'), JSON.stringify({ work, plan, loose, folder }));
  await done('web-1');

  // MARK: web-2 — the Mac's changes arrive; then an edit to Plan that the web doesn't sync yet.
  await waitFor('mac-1');
  const mac = JSON.parse(await readFile(join(DIR!, 'mac.json'), 'utf8')) as { fromMac: string };
  await sync();
  let snap = local.snapshot();
  const planRow = snap.notes.find((n) => n.id === plan)!;
  expect(planRow.title).toBe('Plan #project');
  expect(planRow.isPinned).toBe(true);
  expect(planRow.notebookID).toBe(work);
  expect(plainText(local.getNote(plan)?.container)).toContain('edited on mac');
  const fromMac = snap.notes.find((n) => n.id === mac.fromMac);
  expect(fromMac, JSON.stringify(snap.notes.map((n) => n.title))).toBeTruthy();
  expect(fromMac!.title).toBe('From Mac #mac');
  expect(fromMac!.tags).toEqual(['mac']);
  expect(fromMac!.notebookID).toBe(work);
  expect(plainText(local.getNote(mac.fromMac)?.container)).toContain('Hello web');
  expect(snap.notes.find((n) => n.id === loose), 'Loose was deleted on the Mac (a tombstone)').toBeUndefined();
  expect(snap.smartFolders.find((f) => f.id === folder)?.query).toBe('tag:project OR tag:mac');
  expect(snap.notebooks.find((n) => n.id === work)?.name).toBe('Work (Mac)');
  // The Mac checked "ship it" in Tasks.
  expect(local.tasks().find((x) => x.text.startsWith('ship it'))?.checked).toBe(true);

  const opened = local.getNote(plan)!;
  const withWebEdit: BodyContainer = { ...opened.container!, doc: { ...opened.container!.doc, content: [...opened.container!.doc.content, para('web concurrent edit')] } };
  await local.saveNote(plan, withWebEdit, opened.row.revision);
  await done('web-2');

  // MARK: web-3 — the Mac synced its own edit first: the web's pass keeps both, as one conflict copy.
  await waitFor('mac-2');
  const report = await sync();
  await sync();
  snap = local.snapshot();
  expect(report.conflicts, JSON.stringify(report)).toBe(1);
  const copies = snap.notes.filter((n) => n.conflictSource && !n.deletedAt);
  expect(copies, JSON.stringify(snap.notes.map((n) => [n.title, n.conflictSource]))).toHaveLength(1);
  const texts = snap.notes.filter((n) => !n.deletedAt).map((n) => plainText(local.getNote(n.id)?.container)).join('\n');
  expect(texts).toContain('web concurrent edit');
  expect(texts).toContain('mac concurrent edit');
  await writeFile(join(DIR!, 'web-conflict.json'), JSON.stringify({ copy: copies[0]!.id, source: copies[0]!.conflictSource, original: copies[0]!.conflictOriginalID }));
  await done('web-3');
  await waitFor('mac-3');
}
