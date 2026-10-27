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
  async bump() {
    const before = (this.s('kv').get('generation') as number | undefined) ?? 0;
    this.s('kv').set('generation', before + 1);
    return before;
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

  it('creates a note with an id handed out ahead, as an import that links its notes does', async () => {
    const { s } = await store();
    const id = await s.createNote({ id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', container: text('Imported') });
    expect(id).toBe('AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE');
    expect(s.snapshot().notes[0]?.id).toBe(id);
    await expect(s.createNote({ id, container: text('Again') })).rejects.toThrow();
    await expect(s.createNote({ id: 'not-a-uuid', container: text('Bad') })).rejects.toThrow();
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

  it('filters tasks by the search language per line and leaves out templates (native Search Tasks)', async () => {
    const { s } = await store();
    const task = (t: string, checked = false) => ({ type: 'listItem' as const, attrs: { kind: 'task' as const, level: 0, checked }, content: [{ type: 'text' as const, text: t }] });
    const doc = (...content: ReturnType<typeof task>[]): BodyContainer => ({ ...emptyContainer(), doc: { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Chores #home' }] }, ...content] } });
    await s.createNote({ container: doc(task('buy milk #shop'), task('call mum @due(2026-10-21)'), task('milk done', true)) });
    const templates = await s.createNotebook({ name: 'Templates', colorHex: '#8E8E93', symbol: 'doc.on.doc' });
    await s.createNote({ container: doc(task('template milk')), notebookID: templates });
    expect(s.tasks().map((t) => t.text)).toEqual(['buy milk #shop', 'call mum', 'milk done']);
    expect(s.tasks('milk').map((t) => t.text)).toEqual(['buy milk #shop', 'milk done']);
    // The note's tags count for each of its lines, as native TaskSearchDocument does.
    expect(s.tasks('tag:shop').length).toBe(3);
    expect(s.tasks('tag:home has:due').map((t) => t.text)).toEqual(['call mum']);
    expect(s.tasks('is:done').map((t) => t.text)).toEqual(['milk done']);
  });

  it("reads a notebook's synced default template", async () => {
    const { s } = await store();
    const id = newUuid();
    const tpl = newUuid();
    const meta = { id, name: 'Work', colorHex: '#8E8E93', symbol: 'folder', sortIndex: 0, parent: null, defaultTemplateID: tpl };
    await s.apply({ id, kind: 'notebook', revision: newUuid(), modifiedAt: new Date(), deviceID: 'MAC', meta: utf8(JSON.stringify(meta)) });
    expect(s.snapshot().notebooks[0]?.defaultTemplateID).toBe(tpl);
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

  it('syncs smart folders (native SmartFolder records): create, edit, last writer wins, delete', async () => {
    const backend = new InMemoryBackend();
    const pass = 'smart folders everywhere';
    const a = await connect(backend, { passphrase: pass, createIfMissing: true });
    const b = await connect(backend, { passphrase: pass, createIfMissing: false });
    const la = new WebLocalStore(new MemoryKV(), a.session.cipher, 'A');
    const lb = new WebLocalStore(new MemoryKV(), b.session.cipher, 'B');
    const ea = new SyncEngine({ backend, session: a.session, local: la, state: new MemoryStateStore(), deviceID: 'A', deviceName: 'Browser A' });
    const eb = new SyncEngine({ backend, session: b.session, local: lb, state: new MemoryStateStore(), deviceID: 'B', deviceName: 'Browser B' });
    const id = await la.createSmartFolder({ name: 'Due soon', query: 'is:todo due:this-week' });
    expect((await backend.list('noteit/v1/smart-folders/')).map((o) => o.key)).toEqual([]);
    await ea.sync();
    expect((await backend.list('noteit/v1/smart-folders/')).map((o) => o.key)).toEqual([`noteit/v1/smart-folders/${id}.json`]);
    await eb.sync();
    expect(lb.snapshot().smartFolders).toEqual([{ id, name: 'Due soon', query: 'is:todo due:this-week', symbol: 'folder.badge.gearshape', sortIndex: 0 }]);
    const raw = JSON.parse(fromUtf8((await lb.export(id)).meta)) as Record<string, unknown>;
    expect(Object.keys(raw).sort()).toEqual(['id', 'modifiedAt', 'name', 'query', 'revision', 'sortIndex', 'symbol']);
    await lb.updateSmartFolder(id, { name: 'This week' });
    await eb.sync();
    await ea.sync();
    expect(la.snapshot().smartFolders[0]?.name).toBe('This week');
    await expect(la.createSmartFolder({ name: ' ', query: 'x' })).rejects.toThrow(/name/);
    await la.deleteSmartFolder(id);
    await ea.sync();
    await eb.sync();
    expect(lb.snapshot().smartFolders).toEqual([]);
  });

  describe('two tabs on one library', () => {
    it('never overwrites the other tab: a save from an older base keeps the other version as a conflict copy', async () => {
      const kv = new MemoryKV();
      const a = await store(kv);
      const b = await store(kv);
      const id = await a.s.createNote({ container: text('Plan\nfrom A') });
      await b.s.ensureFresh();
      const base = b.s.getNote(id)!.row.revision;
      // Tab A saves first; tab B's editor still has the old base.
      await a.s.saveNote(id, text('Plan\nA edit'), base);
      const saved = await b.s.saveNote(id, text('Plan\nB edit'), base);
      expect(saved.conflictCopy).toBeDefined();
      await a.s.ensureFresh();
      const notes = a.s.snapshot().notes;
      expect(notes).toHaveLength(2);
      const original = a.s.getNote(id)!;
      const copy = a.s.getNote(saved.conflictCopy!)!;
      expect(JSON.stringify(original.container!.doc)).toContain('B edit');
      expect(JSON.stringify(copy.container!.doc)).toContain('A edit');
      expect(copy.row).toMatchObject({ conflictOriginalID: id, conflictSource: 'this browser' });
      // From the current base, a save is a plain edit.
      const again = await a.s.saveNote(id, text('Plan\nB edit, more'), original.row.revision);
      expect(again.conflictCopy).toBeUndefined();
    });

    it("sees the other tab's writes before listing records for a pass", async () => {
      const kv = new MemoryKV();
      const a = await store(kv);
      const b = await store(kv);
      const id = await a.s.createNote({ container: text('One') });
      const listed = await b.s.records();
      expect(listed.map((r) => r.id)).toEqual([id]);
    });

    it('defers a pull over a record edited since the pass read it (native localEditInProgress)', async () => {
      const kv = new MemoryKV();
      const a = await store(kv);
      const id = await a.s.createNote({ container: text('One') });
      const [seen] = await a.s.records();
      const payload = await a.s.export(id);
      await a.s.saveNote(id, text('One, edited'), seen!.revision);
      await expect(a.s.apply({ ...payload, revision: newUuid() })).rejects.toThrow(/local edit in progress/);
    });
  });
});

describe('notebook parent (interop with native Notebook)', () => {
  it('always writes `parent`, null at the top level, as native does; moves keep it and refuse cycles', async () => {
    const { s, kv, cipher } = await store();
    const top = await s.createNotebook({ name: 'Work', colorHex: '#007AFF', symbol: 'tray' });
    const child = await s.createNotebook({ name: 'Clients', colorHex: '#007AFF', symbol: 'tray', parent: top });
    const raw = async (id: string) => JSON.parse(fromUtf8(utf8((JSON.parse(fromUtf8(await cipher.open((await kv.get<Uint8Array>('records', id))!, `local/records/${id}`))) as { meta: string }).meta))) as Record<string, unknown>;
    expect(await raw(top)).toHaveProperty('parent', null);
    expect(await raw(child)).toHaveProperty('parent', top);
    await s.updateNotebook(top, { name: 'Work 2' });
    expect(await raw(top)).toHaveProperty('parent', null);
    await s.updateNotebook(child, { parent: null });
    expect(await raw(child)).toHaveProperty('parent', null);
    await s.updateNotebook(child, { parent: top });
    await expect(s.updateNotebook(top, { parent: child })).rejects.toThrow(/inside itself/);
  });
});

describe('tag rename, merge and delete', () => {
  it('rewrites every editable note and smart folder searches; trash is left alone', async () => {
    const { s } = await store();
    const a = await s.createNote({ container: text('A #work/acme') });
    await s.createNote({ container: text('B #job and #work') });
    const trashed = await s.createNote({ container: text('C #work') });
    await s.updateNoteMeta(trashed, { trashed: true });
    const folder = await s.createSmartFolder({ name: 'Work', query: 'tag:work is:todo' });
    expect(await s.editTag({ type: 'rename', from: 'work', to: 'job' })).toEqual({ changed: 2, skipped: 0, inTrash: 1 });
    const tags = s.snapshot().notes.filter((n) => !n.deletedAt).flatMap((n) => n.tags).sort();
    expect(tags).toEqual(['job', 'job/acme']); // B's #job and #work merged
    expect(s.snapshot().smartFolders.find((f) => f.id === folder)?.query).toBe('tag:job is:todo');
    await s.editTag({ type: 'delete', tag: 'job' });
    expect(s.getNote(a)!.row.title).toBe('A');
    await expect(s.editTag({ type: 'rename', from: 'x', to: 'bad name' })).rejects.toThrow(/letters/);
  });
});

describe('unlinked mentions', () => {
  it('lists notes that mention the title without linking it, and links them', async () => {
    const { s } = await store();
    const target = await s.createNote({ container: text('Grocery Plan\nlist') });
    const mention = await s.createNote({ container: text('Monday\nsee the grocery plan today') });
    await s.createNote({ container: text('Unrelated\nnothing') });
    expect(s.unlinkedMentions(target).map((m) => m.id)).toEqual([mention]);
    expect(await s.linkMentions(target, [mention])).toBe(1);
    expect(s.unlinkedMentions(target)).toEqual([]);
    expect(s.links(target).backlinks.map((b) => b.id)).toEqual([mention]);
  });
});

describe('update links on rename', () => {
  const linking = (title: string, href: string, shown: string): BodyContainer => ({
    ...emptyContainer(),
    doc: { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: title }] }, { type: 'paragraph', content: [{ type: 'text', text: shown, marks: [{ type: 'link', attrs: { href } }] }] }] },
  });

  it('rewrites link text in other notes, skips the excluded one, and undoes unless edited since', async () => {
    const { s } = await store();
    const target = await s.createNote({ container: text('Atlas') });
    const href = `noteit://note/${target.toUpperCase()}`;
    const a = await s.createNote({ container: linking('A', href, 'Atlas') });
    const b = await s.createNote({ container: linking('B', href, 'atlas') });
    await s.createNote({ container: linking('Alias', href, 'Atlas map') });
    expect(s.linkRenameCandidates(target, 'Atlas', b)).toEqual([a]);
    const r = await s.rewriteLinkText(target, 'Atlas', 'Globe');
    expect(r.updated).toBe(2);
    expect(r.skipped).toBe(0);
    expect(s.links(target).backlinks.length).toBe(3);
    expect((s.getNote(a)!.container!.doc.content[1] as { content: { text: string }[] }).content[0]!.text).toBe('Globe');
    await s.saveNote(b, linking('B edited', href, 'Globe'));
    expect(await s.undoLinkRewrite(r.notes)).toBe(1);
    expect((s.getNote(a)!.container!.doc.content[1] as { content: { text: string }[] }).content[0]!.text).toBe('Atlas');
  });
});
