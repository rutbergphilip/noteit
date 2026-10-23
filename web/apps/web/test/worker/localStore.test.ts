import { AesGcmCipher, fromUtf8, importAesKey, InMemoryBackend, connect, MemoryStateStore, SyncEngine, utf8, newUuid } from '@noteit/core';
import { emptyContainer, type BodyContainer } from '@noteit/doc';
import { describe, expect, it } from 'vitest';
import type { StoreName } from '../../app/worker/idb';
import { type KeyValue, WebLocalStore } from '../../app/worker/localStore';

class MemoryKV implements KeyValue {
  stores = new Map<StoreName, Map<string, unknown>>();
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
}

const text = (s: string): BodyContainer => ({ ...emptyContainer(), doc: { type: 'doc', content: s.split('\n').map((line) => (line ? { type: 'paragraph', content: [{ type: 'text', text: line }] } : { type: 'paragraph' })) } });

async function store(kv = new MemoryKV()) {
  const cipher = new AesGcmCipher(await importAesKey(new Uint8Array(32).fill(7)));
  const s = new WebLocalStore(kv, cipher, 'WEB');
  await s.load();
  return { s, kv, cipher };
}

describe('WebLocalStore', () => {
  it('seals every record at rest and derives list rows from the body', async () => {
    const { s, kv } = await store();
    const id = await s.createNote({ container: text('Groceries #home\nMilk, eggs') });
    const row = s.snapshot().notes[0]!;
    expect(row).toMatchObject({ id, title: 'Groceries #home', preview: 'Milk, eggs', tags: ['home'], kind: 'doc' });
    for (const [, sealed] of await kv.all<Uint8Array>('records')) expect(Buffer.from(sealed).toString('latin1')).not.toContain('Groceries');
    const reopened = await store(kv);
    expect(reopened.s.snapshot().notes[0]?.title).toBe('Groceries #home');
    expect(reopened.s.search('MILK')).toEqual([id]);
  });

  it('searches with the native search language, and lists links and tasks', async () => {
    const { s } = await store();
    const target = await s.createNote({ container: text('Budget #work/acme') });
    const task = (t: string, checked: boolean) => ({ type: 'listItem' as const, attrs: { kind: 'task' as const, level: 0, checked }, content: [{ type: 'text' as const, text: t }] });
    const source = await s.createNote({
      container: {
        ...emptyContainer(),
        doc: {
          type: 'doc',
          content: [
            { type: 'paragraph', content: [{ type: 'text', text: 'Plan, see ' }, { type: 'text', text: 'Budget', marks: [{ type: 'link', attrs: { href: `noteit://note/${target.toUpperCase()}` } }] }] },
            task('pay @due(2026-10-21)', false),
            task('done', true),
          ],
        },
      },
    });
    expect(s.search('tag:work')).toEqual([target]);
    expect(s.search('is:todo')).toEqual([source]);
    expect(s.search('has:due -tag:work')).toEqual([source]);
    expect(s.search('budget OR plan').sort()).toEqual([target, source].sort());
    expect(s.links(target).backlinks).toEqual([{ id: source, title: 'Plan, see Budget', context: 'Plan, see Budget' }]);
    expect(s.links(source).outgoing).toEqual([{ id: target, title: 'Budget #work/acme', text: 'Budget', exists: true }]);
    expect(s.tasks().map((t) => [t.text, t.checked])).toEqual([
      ['pay', false],
      ['done', true],
    ]);
    await s.setTaskChecked(source, 1, true);
    expect(s.search('is:done')).toEqual([source]);
  });

  it('keeps meta keys it does not own through edits (RawMetaOverlay)', async () => {
    const { s } = await store();
    const id = newUuid();
    const meta = { id, title: 'x', preview: '', tags: [], isPinned: false, createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z', futureKey: { a: 1 }, conflictSource: 'Mac' };
    await s.apply({ id, kind: 'note', revision: newUuid(), modifiedAt: new Date(), deviceID: 'MAC', meta: utf8(JSON.stringify(meta)), body: utf8(JSON.stringify(text('x'))), bodyFormat: 'noteit-doc/1' });
    await s.saveNote(id, text('Edited'));
    const exported = JSON.parse(fromUtf8((await s.export(id)).meta));
    expect(exported.futureKey).toEqual({ a: 1 });
    expect(exported.conflictSource).toBeUndefined();
    expect(exported.title).toBe('Edited');
  });

  it('carries legacy notes as meta-only records and never pretends to edit them', async () => {
    const { s } = await store();
    const id = newUuid();
    const meta = { id, title: 'Old note', preview: 'from a Mac', tags: [], isPinned: false, createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z' };
    await s.apply({ id, kind: 'note', revision: newUuid(), modifiedAt: new Date(), deviceID: 'MAC', meta: utf8(JSON.stringify(meta)), carriedBody: { bodySHA256: 'abc' } });
    expect(s.getNote(id)?.readOnly).toBe('legacy');
    await expect(s.saveNote(id, text('nope'))).rejects.toThrow();
    await s.updateNoteMeta(id, { isPinned: true });
    const p = await s.export(id);
    expect(p.body).toBeUndefined();
    expect(p.carriedBody).toEqual({ bodySHA256: 'abc' });
  });

  it('makes conflict copies with the native title suffix and a link to the original', async () => {
    const { s } = await store();
    const id = newUuid();
    const meta = { id, title: 'Plan', preview: '', tags: [], isPinned: true, createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z' };
    await s.importConflictCopy({ id, kind: 'note', revision: newUuid(), modifiedAt: new Date('2026-02-03T04:05:00Z'), deviceID: 'MAC', meta: utf8(JSON.stringify(meta)), body: utf8(JSON.stringify(text('Plan\nmore'))), bodyFormat: 'noteit-doc/1' }, 'Work Mac');
    const copy = s.snapshot().notes[0]!;
    expect(copy.id).not.toBe(id);
    expect(copy.title).toMatch(/^Plan \(conflict — Work Mac, .+\)$/);
    expect(copy).toMatchObject({ conflictSource: 'Work Mac', conflictOriginalID: id, isPinned: true });
  });

  it('moves a deleted notebook\'s notes to Recently Deleted and recovers into Inbox', async () => {
    const { s } = await store();
    const inbox = await s.createNotebook({ name: 'Inbox', colorHex: '#0A84FF', symbol: 'tray' });
    const work = await s.createNotebook({ name: 'Work', colorHex: '#30D158', symbol: 'briefcase' });
    const id = await s.createNote({ notebookID: work, container: text('Retro') });
    await s.deleteNotebook(work);
    expect(s.snapshot().notes[0]?.deletedAt).toBeDefined();
    expect((await s.deletions()).has(work)).toBe(true);
    await s.updateNoteMeta(id, { trashed: false });
    expect(s.snapshot().notes[0]).toMatchObject({ notebookID: inbox });
    expect(s.snapshot().notes[0]?.deletedAt).toBeUndefined();
  });

  it('syncs between two browsers through the engine', async () => {
    const backend = new InMemoryBackend();
    const pass = 'two browsers one library';
    const a = await connect(backend, { passphrase: pass, createIfMissing: true });
    const b = await connect(backend, { passphrase: pass, createIfMissing: false });
    const la = new WebLocalStore(new MemoryKV(), a.session.cipher, 'A');
    const lb = new WebLocalStore(new MemoryKV(), b.session.cipher, 'B');
    const ea = new SyncEngine({ backend, session: a.session, local: la, state: new MemoryStateStore(), deviceID: 'A', deviceName: 'Browser A' });
    const eb = new SyncEngine({ backend, session: b.session, local: lb, state: new MemoryStateStore(), deviceID: 'B', deviceName: 'Browser B' });
    const nb = await la.createNotebook({ name: 'Ideas', colorHex: '#FF9F0A', symbol: 'lightbulb' });
    const id = await la.createNote({ notebookID: nb, container: text('Shared idea') });
    await ea.sync();
    await eb.sync();
    expect(lb.snapshot().notes[0]).toMatchObject({ id, title: 'Shared idea', notebookID: nb });
    await la.saveNote(id, text('From A'));
    await lb.saveNote(id, text('From B'));
    await ea.sync();
    expect((await eb.sync()).conflicts).toBe(1);
    await ea.sync();
    const titles = (l: WebLocalStore) => l.snapshot().notes.map((n) => n.title).sort();
    expect(titles(la)).toEqual(titles(lb));
    expect(titles(la)[0]).toMatch(/^From A \(conflict — Browser A, .+\)$/);
    expect(titles(la)).toContain('From B');
  });
});
