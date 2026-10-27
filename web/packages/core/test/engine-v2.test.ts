import { describe, expect, it } from 'vitest';
import {
  b64encode,
  connect,
  decodeEnvelope,
  encodeJson,
  fromUtf8,
  InMemoryBackend,
  keys,
  MemoryStateStore,
  newUuid,
  sha256Hex,
  StorageError,
  SyncEngine,
  SyncError,
  utf8,
  AesGcmCipher,
  type StoreSession,
  BODY_FORMAT_DOC_V1,
  toDouble2001,
} from '../src/index.js';
import { FakeLocal } from './fake-local.js';

const PASS = 'correct horse battery staple';

async function setup() {
  let clock = new Date('2026-03-01T10:00:00Z');
  const backend = new InMemoryBackend({ now: () => clock });
  const { session, created } = await connect(backend, { passphrase: PASS, createIfMissing: true, now: () => clock });
  expect(created).toBe(true);
  const device = async (name: string) => {
    const { session: s } = await connect(backend, { passphrase: PASS, createIfMissing: false });
    const local = new FakeLocal(`DEV-${name}`, BODY_FORMAT_DOC_V1);
    const state = new MemoryStateStore();
    const engine = new SyncEngine({ backend, session: s, local, state, deviceID: `DEV-${name}`, deviceName: name, now: () => clock });
    return { local, engine, state };
  };
  return { backend, session, device, tick: (s: number) => (clock = new Date(clock.getTime() + s * 1000)), now: () => clock };
}

const docBody = (text: string) => utf8(JSON.stringify({ format: 'noteit-doc', version: 1, doc: { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text }] }] }, attachments: {} }));
const bodyKeys = (b: InMemoryBackend) => [...b.objects.keys()].filter((k) => k.startsWith('noteit/v1/bodies/'));

describe('connect', () => {
  it('creates a noteit-doc store and rejects a wrong passphrase', async () => {
    const { backend } = await setup();
    const manifest = JSON.parse(fromUtf8((await backend.get(keys.manifest)).data));
    expect(manifest.formatVersion).toBe(2);
    expect(manifest.features).toEqual(['noteit-doc']);
    await expect(connect(backend, { passphrase: 'nope', createIfMissing: false })).rejects.toMatchObject({ kind: 'wrongPassphrase' });
  });

  it('reports a legacy store after checking the passphrase, without writing', async () => {
    const backend = new InMemoryBackend();
    const { session } = await connect(backend, { passphrase: PASS, createIfMissing: true });
    const m = { ...session.manifest, formatVersion: 1 } as Record<string, unknown>;
    delete m.features;
    await backend.put(keys.manifest, encodeJson(m));
    const before = backend.log.length;
    await expect(connect(backend, { passphrase: PASS, createIfMissing: false })).rejects.toMatchObject({ kind: 'legacyStore' });
    await expect(connect(backend, { passphrase: 'wrong', createIfMissing: false })).rejects.toMatchObject({ kind: 'wrongPassphrase' });
    expect(backend.log.length).toBe(before);
  });

  it('copies an Inkwell store to noteit/v1/', async () => {
    const backend = new InMemoryBackend();
    const src = new InMemoryBackend();
    await connect(src, { passphrase: PASS, createIfMissing: true });
    for (const [k, v] of src.objects) backend.objects.set(k.replace('noteit/v1/', 'inkwell/v1/'), v);
    // Stray or hostile names in the legacy store are never copied.
    const junk = { data: utf8('x'), etag: 'j', lastModified: 0 };
    backend.objects.set('inkwell/v1/notes/../../escape.meta', junk);
    backend.objects.set('inkwell/v1/notes/6a1c8e8c-3f55-4c3a-9f7e-1d2b3c4d5e6f.meta', junk);
    backend.objects.set('inkwell/v1/unknown/x.json', junk);
    const { created } = await connect(backend, { passphrase: PASS, createIfMissing: true });
    expect(created).toBe(false);
    expect(backend.objects.has(keys.manifest)).toBe(true);
    expect(backend.objects.has('inkwell/v1/manifest.json')).toBe(true);
    const copied = [...backend.objects.keys()].filter((k) => k.startsWith('noteit/'));
    expect(copied).toEqual([keys.manifest]);
  });
});

describe('engine in a noteit-doc store', () => {
  it('publishes versioned bodies and propagates edits, deleting the superseded version', async () => {
    const { backend, device, now, tick } = await setup();
    const a = await device('A');
    const b = await device('B');
    const id = newUuid();
    a.local.upsert({ id, kind: 'note', revision: newUuid(), modifiedAt: now(), meta: { title: 'One' }, body: docBody('One') });
    await a.engine.sync();
    expect(bodyKeys(backend)).toHaveLength(1);
    expect(bodyKeys(backend)[0]).toMatch(new RegExp(`^noteit/v1/bodies/${id}\\.[0-9A-F-]{36}\\.new\\.body$`));
    expect(backend.objects.has(keys.noteBody(id))).toBe(false);

    await b.engine.sync();
    expect(fromUtf8(b.local.items.get(id)!.body!)).toBe(fromUtf8(docBody('One')));

    tick(60);
    b.local.upsert({ ...b.local.items.get(id)!, revision: newUuid(), modifiedAt: now(), meta: { title: 'Two' }, body: docBody('Two') });
    await b.engine.sync();
    const keysAfter = bodyKeys(backend);
    expect(keysAfter).toHaveLength(1);
    expect(keysAfter[0]).not.toMatch(/\.new\.body$/);
    await a.engine.sync();
    expect(a.local.items.get(id)!.meta.title).toBe('Two');

    // The meta names the version and the sha of the plaintext.
    const sealed = backend.objects.get(keys.noteMeta(id))!.data;
    const env = decodeEnvelope(await a.engine.session.cipher.open(sealed, `notes/${id}.meta`));
    expect(env.bodyFormat).toBe('noteit-doc/1');
    expect(keysAfter[0]).toContain(env.bodyVersion);
    expect(env.bodySHA256).toBe(await sha256Hex(docBody('Two')));
  });

  it('takes another device’s meta refresh without downloading the body or making a conflict copy', async () => {
    const { backend, device, now, tick } = await setup();
    const a = await device('A');
    const b = await device('B');
    const id = newUuid();
    a.local.upsert({ id, kind: 'note', revision: newUuid(), modifiedAt: now(), meta: { title: 'Kept' }, body: docBody('Kept') });
    await a.engine.sync();
    await b.engine.sync();

    // A Mac's stranded-body recovery: the same envelope plaintext sealed again, If-Match the listed ETag.
    const key = `notes/${id}.meta`;
    const { data, etag } = await backend.get(keys.noteMeta(id));
    const plain = await a.engine.session.cipher.open(data, key);
    const refreshed = await backend.put(keys.noteMeta(id), await a.engine.session.cipher.seal(plain, key), { ifMatch: etag });
    expect(refreshed).not.toBe(etag);

    const gets: string[] = [];
    const get = backend.get.bind(backend);
    backend.get = async (k: string) => {
      gets.push(k);
      return get(k);
    };
    const report = await b.engine.sync();
    expect(report.pulled).toBe(0);
    expect(gets.filter((k) => k.includes('/bodies/'))).toEqual([]);
    expect((await b.state.load()).bases[id]?.remoteMetaETag).toBe(refreshed);

    // An edit made before the refresh was seen is pushed against the new ETag, with no conflict copy.
    tick(10);
    a.local.upsert({ ...a.local.items.get(id)!, revision: newUuid(), meta: { title: 'Edited' }, body: docBody('Edited') });
    const pushed = await a.engine.sync();
    expect(pushed.conflicts).toBe(0);
    await b.engine.sync();
    expect([...b.local.items.values()].map((r) => r.meta.title)).toEqual(['Edited']);
  });

  it('makes a conflict copy when two devices edit the same note', async () => {
    const { device, now, tick } = await setup();
    const a = await device('A');
    const b = await device('B');
    const id = newUuid();
    a.local.upsert({ id, kind: 'note', revision: newUuid(), modifiedAt: now(), meta: { title: 'Shared' }, body: docBody('Shared') });
    await a.engine.sync();
    await b.engine.sync();
    tick(10);
    a.local.upsert({ ...a.local.items.get(id)!, revision: newUuid(), meta: { title: 'From A' }, body: docBody('From A') });
    b.local.upsert({ ...b.local.items.get(id)!, revision: newUuid(), meta: { title: 'From B' }, body: docBody('From B') });
    await a.engine.sync();
    const report = await b.engine.sync();
    expect(report.conflicts).toBe(1);
    await a.engine.sync();
    const titles = (l: FakeLocal) => [...l.items.values()].map((r) => r.meta.title).sort();
    expect(titles(a.local)).toEqual(['From A (conflict — A)', 'From B']);
    expect(titles(b.local)).toEqual(titles(a.local));
  });

  it('recovers from a lost commit response without a conflict copy or a second version', async () => {
    const { backend, device, now } = await setup();
    const a = await device('A');
    const b = await device('B');
    const id = newUuid();
    a.local.upsert({ id, kind: 'note', revision: newUuid(), modifiedAt: now(), meta: { title: 'X' }, body: docBody('X') });
    backend.landThenFail('put', /\.meta$/);
    const r1 = await a.engine.sync();
    expect(r1.pushed).toBe(0);
    expect((await a.state.load()).pendingBodyVersions[id]?.phase).toBe('inDoubt');
    const r2 = await a.engine.sync();
    expect(r2.conflicts).toBe(0);
    expect((await a.state.load()).pendingBodyVersions[id]).toBeUndefined();
    expect(bodyKeys(backend)).toHaveLength(1);
    await b.engine.sync();
    expect(b.local.items.get(id)?.meta.title).toBe('X');
  });

  it('re-uploads the same version after a failed body upload', async () => {
    const { backend, device, now } = await setup();
    const a = await device('A');
    const id = newUuid();
    a.local.upsert({ id, kind: 'note', revision: newUuid(), modifiedAt: now(), meta: { title: 'Y' }, body: docBody('Y') });
    backend.failNext('put', new StorageError('network', 'down'));
    await a.engine.sync();
    const pending = (await a.state.load()).pendingBodyVersions[id];
    expect(pending?.phase).toBe('uploading');
    await a.engine.sync();
    expect(bodyKeys(backend)).toEqual([keys.docBody(id, pending!.version, 'new')]);
    expect(backend.objects.has(keys.noteMeta(id))).toBe(true);
  });

  it('propagates deletions and removes every body version', async () => {
    const { backend, device, now } = await setup();
    const a = await device('A');
    const b = await device('B');
    const id = newUuid();
    a.local.upsert({ id, kind: 'note', revision: newUuid(), modifiedAt: now(), meta: { title: 'Gone' }, body: docBody('Gone') });
    await a.engine.sync();
    await b.engine.sync();
    a.local.remove(id, now());
    await a.engine.sync();
    expect(bodyKeys(backend)).toEqual([]);
    expect(backend.objects.has(keys.tombstone(id))).toBe(true);
    await b.engine.sync();
    expect(b.local.items.has(id)).toBe(false);
  });

  it('carries a legacy note through a meta-only write and never touches its body', async () => {
    const { backend, session, device, now } = await setup();
    const id = newUuid();
    const meta = utf8(JSON.stringify({ title: 'Old Mac note' }));
    const legacyBody = utf8('rtfd\0\0\0\0 bytes');
    const env = { id, kind: 'note' as const, revision: newUuid(), modifiedAt: toDouble2001(now()), deviceID: 'MAC', deviceName: 'Mac', meta: b64encode(meta), bodySHA256: await sha256Hex(legacyBody) };
    const cipher = session.cipher as AesGcmCipher;
    await backend.put(keys.noteBody(id), await cipher.seal(legacyBody, `notes/${id}.body`));
    await backend.put(keys.noteMeta(id), await cipher.seal(encodeJson(env), `notes/${id}.meta`));
    const a = await device('A');
    await a.engine.sync();
    const rec = a.local.items.get(id)!;
    expect(rec.body).toBeUndefined();
    expect(rec.carried).toEqual({ bodySHA256: env.bodySHA256 });
    const bodyETag = backend.objects.get(keys.noteBody(id))!.etag;
    a.local.upsert({ ...rec, revision: newUuid(), meta: { title: 'Old Mac note', isPinned: true } });
    await a.engine.sync();
    const out = decodeEnvelope(await cipher.open(backend.objects.get(keys.noteMeta(id))!.data, `notes/${id}.meta`));
    expect(out.bodyFormat).toBeUndefined();
    expect(out.bodySHA256).toBe(env.bodySHA256);
    expect(backend.objects.get(keys.noteBody(id))!.etag).toBe(bodyETag);
  });

  it('stops on a foreign rekey after acknowledging it', async () => {
    const { backend, session, device } = await setup();
    const a = await device('A');
    const m = { ...session.manifest, rekey: { toKeyID: 'abcd', fromKeyID: session.keyID, startedAt: toDouble2001(new Date()), updatedAt: toDouble2001(new Date()), deviceID: 'MAC', deviceName: 'Mac' } };
    await backend.put(keys.manifest, encodeJson(m));
    await expect(a.engine.sync()).rejects.toBeInstanceOf(SyncError);
    const dev = JSON.parse(fromUtf8(await (a.engine.session as StoreSession).cipher.open(backend.objects.get(keys.device('DEV-A'))!.data, 'devices/DEV-A.json')));
    expect(dev.rekeyAck).toBe('abcd');
    expect(dev.platform).toBe('web');
  });
});
