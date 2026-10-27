import { connect, fromUtf8, HttpProxyBackend, MemoryStateStore, newUuid, S3Backend, SyncEngine, utf8, type RecordPayload } from '@noteit/core';
import { afterEach, describe, expect, it } from 'vitest';
import { loadConfig } from '../../server/lib/config';
import { S3Store, UpstreamCapabilityError } from '../../server/lib/s3Store';
import { StoreUnavailable } from '../../server/lib/store';
import { FakeS3, type FakeS3Faults } from './fakeS3';
import { action, browser, type Harness, SETUP_TOKEN, startServer } from './harness';

const USER = '0D4E5A9C-3F2B-4C61-9A7E-2B8D6F1E4C3A';
const OTHER = 'A1B2C3D4-E5F6-4789-8ABC-DEF012345678';
const cfg = { endpoint: 'http://upstream.test', region: 'us-east-1', bucket: 'upstream', prefix: 'noteit-server', pathStyle: true, accessKeyId: 'AK', secretAccessKey: 'SK', timeoutMs: 5000 };

const stores: S3Store[] = [];
function store(fake: FakeS3, log: (m: string) => void = () => undefined, retryMs = 20): S3Store {
  const s = new S3Store(cfg, log, fake.fetch, retryMs);
  stores.push(s);
  return s;
}
afterEach(() => stores.splice(0).forEach((s) => s.close()));

const until = async (cond: () => boolean | Promise<boolean>, ms = 3000) => {
  const end = Date.now() + ms;
  while (!(await cond())) {
    if (Date.now() > end) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 10));
  }
};

describe('S3Store startup canary', () => {
  it('passes on a compliant upstream and leaves nothing behind', async () => {
    const fake = new FakeS3();
    const s = store(fake);
    await s.init();
    expect(s.started()).toBe(true);
    expect(s.ready()).toBe(true);
    expect(fake.objects.size).toBe(0);
    expect(fake.requests.every((r) => r.key === undefined || r.key.startsWith('noteit-server/server-canary/'))).toBe(true);
  });

  const cases: [FakeS3Faults, RegExp][] = [
    [{ ignoreIfNoneMatch: true }, /ignores If-None-Match on PUT/],
    [{ ignoreIfMatch: true }, /ignores If-Match on PUT/],
    [{ notImplemented: true }, /does not implement conditional requests/],
    [{ reuseETag: true }, /reissued an ETag/],
    [{ acceptOldETag: true }, /still accepts the old ETag/],
    [{ ignoreDeleteIfMatch: true }, /ignores If-Match on DELETE/],
    [{ rejectDeleteIfMatch: true }, /rejects a correct If-Match on DELETE/],
  ];
  for (const [faults, message] of cases) {
    it(`refuses to start when ${message.source}`, async () => {
      const fake = new FakeS3('upstream', faults);
      await expect(store(fake).init()).rejects.toThrow(UpstreamCapabilityError);
      await expect(store(new FakeS3('upstream', faults)).init()).rejects.toThrow(message);
      expect(fake.objects.size).toBe(0);
    });
  }

  it('keeps retrying an unreachable upstream until it answers', async () => {
    const fake = new FakeS3();
    fake.down = true;
    const logs: string[] = [];
    const s = store(fake, (m) => logs.push(m));
    await s.init();
    expect(s.started()).toBe(false);
    expect(s.ready()).toBe(false);
    expect(logs.join('\n')).toMatch(/unreachable .*retrying/);
    fake.down = false;
    await until(() => s.started());
    expect(s.ready()).toBe(true);
  });
});

describe('S3Store', () => {
  it('keeps each user under <prefix>/users/<USER-UUID>/ and lists only that namespace', async () => {
    const fake = new FakeS3();
    const s = store(fake);
    await s.init();
    const put = await s.put(USER, 'noteit/v1/manifest.json', utf8('m'), { ifNoneMatch: true });
    expect(put).toEqual({ etag: expect.stringMatching(/^[0-9a-f]{32}$/) });
    await s.put(OTHER, 'noteit/v1/notes/X.meta', utf8('other'), {});
    expect([...fake.objects.keys()].sort()).toEqual([`noteit-server/users/${USER}/noteit/v1/manifest.json`, `noteit-server/users/${OTHER}/noteit/v1/notes/X.meta`]);
    expect((await s.list(USER, 'noteit/')).map((o) => o.key)).toEqual(['noteit/v1/manifest.json']);
    expect(await s.usage(USER)).toEqual({ bytes: 1, objects: 1 });
    await expect(s.list('not-a-uuid', 'noteit/')).rejects.toThrow(/bad user id/);
    await expect(s.get(USER, '../escape')).rejects.toThrow(/invalid key/);
  });

  it('maps conditional writes and deletes like the disk driver', async () => {
    const s = store(new FakeS3());
    await s.init();
    const key = 'noteit/v1/notes/0D4E5A9C-3F2B-4C61-9A7E-2B8D6F1E4C3A.meta';
    const first = await s.put(USER, key, utf8('a'), { ifNoneMatch: true });
    if (first === 'preconditionFailed') throw new Error('unexpected');
    expect(await s.put(USER, key, utf8('b'), { ifNoneMatch: true })).toBe('preconditionFailed');
    expect(await s.put(USER, key, utf8('b'), { ifMatch: 'ffffffffffffffffffffffffffffffff' })).toBe('preconditionFailed');
    const second = await s.put(USER, key, utf8('b'), { ifMatch: first.etag });
    expect(second).not.toBe('preconditionFailed');
    expect((await s.head(USER, key))?.size).toBe(1);
    expect(fromUtf8((await s.get(USER, key))!.data)).toBe('b');
    expect(await s.delete(USER, key, { ifMatch: first.etag })).toBe('preconditionFailed');
    expect(await s.delete(USER, key, {})).toBe('ok');
    expect(await s.delete(USER, key, {})).toBe('notFound');
    expect(await s.get(USER, key)).toBeNull();
  });

  it('pages through long listings', async () => {
    const fake = new FakeS3();
    fake.pageSize = 3;
    const s = store(fake);
    await s.init();
    for (let i = 0; i < 7; i++) await s.put(USER, `noteit/v1/devices/D${i}.json`, utf8(String(i)), {});
    expect((await s.list(USER, 'noteit/v1/devices/')).map((o) => o.key)).toHaveLength(7);
  });

  it('sends a conditional write once and reports a lost response as unavailable', async () => {
    const fake = new FakeS3();
    const s = store(fake);
    await s.init();
    fake.requests.length = 0;
    fake.dropNextPutResponse = true;
    await expect(s.put(USER, 'noteit/v1/manifest.json', utf8('m'), { ifNoneMatch: true })).rejects.toThrow(StoreUnavailable);
    expect(fake.requests.filter((r) => r.method === 'PUT')).toHaveLength(1);
  });

  it('turns unready after three failed requests and recovers through the probe', async () => {
    const fake = new FakeS3();
    const s = store(fake);
    await s.init();
    fake.down = true;
    for (let i = 0; i < 3; i++) await expect(s.head(USER, 'noteit/v1/manifest.json')).rejects.toThrow(StoreUnavailable);
    expect(s.ready()).toBe(false);
    expect(s.started()).toBe(true);
    fake.down = false;
    await until(() => s.ready());
  });

  it('reads its settings from the environment', () => {
    const c = loadConfig({
      NOTEIT_STORE: 's3',
      NOTEIT_S3_ENDPOINT: 'https://s3.example.com',
      NOTEIT_S3_BUCKET: 'b',
      NOTEIT_S3_ACCESS_KEY_ID: 'AK',
      NOTEIT_S3_SECRET_ACCESS_KEY: 'SK',
      NOTEIT_S3_PATH_STYLE: 'false',
      NOTEIT_STORE_TIMEOUT_S: '30',
    });
    expect(c.store).toBe('s3');
    expect(c.s3).toMatchObject({ endpoint: 'https://s3.example.com', bucket: 'b', region: 'us-east-1', prefix: '', pathStyle: false });
    expect(c.storeTimeoutMs).toBe(30_000);
    expect(() => loadConfig({ NOTEIT_STORE: 's3' })).toThrow(/NOTEIT_S3_ENDPOINT is required/);
    expect(() => loadConfig({ NOTEIT_STORE: 'nfs' })).toThrow(/NOTEIT_STORE must be disk or s3/);
  });
});

describe('NoteIt server on an upstream S3 store', () => {
  let h: Harness | undefined;
  afterEach(async () => {
    await h?.close();
    h = undefined;
  });

  const env = { NOTEIT_STORE: 's3', NOTEIT_S3_ENDPOINT: cfg.endpoint, NOTEIT_S3_BUCKET: cfg.bucket, NOTEIT_S3_ACCESS_KEY_ID: 'AK', NOTEIT_S3_SECRET_ACCESS_KEY: 'SK' };

  async function setUp(fake: FakeS3) {
    h = await startServer(env, { store: store(fake) });
    const admin = browser(h.url);
    return { h, admin };
  }

  it('answers 503 until the upstream is reachable, with liveness always up', async () => {
    const fake = new FakeS3();
    fake.down = true;
    const { h, admin } = await setUp(fake);
    expect((await fetch(`${h.url}/api/health/live`)).status).toBe(200);
    const health = await fetch(`${h.url}/api/health`);
    expect(health.status).toBe(503);
    expect(await health.json()).toEqual({ ok: false, mode: 'server', reason: 'storeUnavailable' });
    expect((await admin.fetch('/api/storage/list?prefix=noteit/')).status).toBe(503);
    expect((await fetch(`${h.url}/s3/noteit?list-type=2`)).status).toBe(503);
    fake.down = false;
    await until(async () => (await fetch(`${h.url}/api/health`)).status === 200);
    expect(await (await fetch(`${h.url}/api/health`)).json()).toEqual({ ok: true, mode: 'server', needsSetup: true });
  });

  it('syncs through /api/storage and /s3 with the bytes in the upstream bucket', async () => {
    const fake = new FakeS3();
    const { h, admin } = await setUp(fake);
    expect((await action(admin, 'setup', { token: SETUP_TOKEN, username: 'admin', password: 'correct horse battery staple' })).data).toBeTruthy();
    const backend = new HttpProxyBackend({ baseUrl: h.url, fetch: admin.fetch });
    const { session } = await connect(backend, { passphrase: 'an upstream passphrase', createIfMissing: true });
    const items = new Map<string, RecordPayload>();
    const local = {
      records: async () => [...items.values()].map((p) => ({ id: p.id, kind: p.kind, revision: p.revision, modifiedAt: p.modifiedAt })),
      deletions: async () => new Map(),
      export: async (id: string) => items.get(id)!,
      apply: async (p: RecordPayload) => void items.set(p.id, p),
      applyDeletion: async (id: string) => void items.delete(id),
      importConflictCopy: async () => undefined,
      clearDeletion: async () => undefined,
      revision: async (id: string) => items.get(id)?.revision,
      passDidFinish: async () => undefined,
    };
    const id = newUuid();
    const body = utf8(JSON.stringify({ format: 'noteit-doc', version: 1, doc: { type: 'doc', content: [] }, attachments: {} }));
    items.set(id, { id, kind: 'note', revision: newUuid(), modifiedAt: new Date(), deviceID: 'WEB', meta: utf8('{"title":"upstream"}'), body, bodyFormat: 'noteit-doc/1' });
    const engine = new SyncEngine({ backend, session, local, state: new MemoryStateStore(), deviceID: 'WEB', deviceName: 'Web' });
    expect((await engine.sync()).errors).toEqual([]);

    const user = h.ctx.accounts.byUsername('admin')!;
    const upstreamKeys = [...fake.objects.keys()];
    expect(upstreamKeys.length).toBeGreaterThan(2);
    expect(upstreamKeys.every((k) => k.startsWith(`noteit-server/users/${user.id}/noteit/v1/`))).toBe(true);
    expect(upstreamKeys.some((k) => k.startsWith(`noteit-server/users/${user.id}/noteit/v1/bodies/`))).toBe(true);

    // The Mac's path: the S3 subset, with the client S3Backend's own canary passing through to the upstream.
    const key = (await action(admin, 'account/create-s3-key', { label: 'Mac' })).data;
    const s3 = new S3Backend({ endpoint: `${h.url}/s3`, bucket: 'noteit', region: 'us-east-1', accessKeyId: key.accessKeyId, secretAccessKey: key.secretAccessKey, pathStyle: true });
    expect(await s3.atomicConditionalWrites()).toBe(true);
    expect(await s3.atomicConditionalDelete()).toBe(true);
    const listed = await s3.list('noteit/v1/');
    expect(listed.map((o) => o.key).sort()).toEqual((await h.ctx.store.list(user.id, 'noteit/v1/')).map((o) => o.key));
  });

  it('answers 502 storeUnavailable when the upstream drops mid-request', async () => {
    const fake = new FakeS3();
    const { h, admin } = await setUp(fake);
    await action(admin, 'setup', { token: SETUP_TOKEN, username: 'admin', password: 'correct horse battery staple' });
    fake.down = true;
    const res = await admin.fetch('/api/storage/list?prefix=noteit/');
    expect(res.status).toBe(502);
    expect((await res.json()).error).toBe('storeUnavailable');
  });
});
