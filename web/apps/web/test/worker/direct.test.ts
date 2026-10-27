import {
  CANARY_PREFIX,
  connect,
  type LocalDeletion,
  type LocalRecord,
  MemoryStateStore,
  type RecordPayload,
  S3Backend,
  type SyncLocalStore,
  SyncEngine,
  newUuid,
  utf8,
} from '@noteit/core';
import { describe, expect, it } from 'vitest';
import { parseClientConfig, loadClientConfig, ClientConfigError } from '../../app/utils/clientConfig';
import { awsCors, b2CorsRules, CORS_HEADERS, corsExamples, r2Cors } from '../../app/utils/corsExamples';
import { corsCheck } from '../../app/worker/corsCheck';
import { type DirectCredentials, openCredentials, sealCredentials, VAULT_AAD, VaultError } from '../../app/worker/credentialVault';
import { FakeS3, type FakeS3Faults } from '../server/fakeS3';

const CREDS: DirectCredentials = { endpoint: 'https://s3.example.com', region: 'eu-north-1', bucket: 'upstream', prefix: 'notes', pathStyle: true, accessKeyId: 'AKIDEXAMPLE1234', secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY' };

function s3(fake: FakeS3, opts: { prefix?: string; fetch?: typeof fetch; now?: () => Date } = {}): S3Backend {
  return new S3Backend({ ...CREDS, prefix: opts.prefix ?? 'notes' }, opts.fetch ?? fake.fetch, opts.now, [0, 0]);
}

describe('noteit-client.json', () => {
  it('accepts the two modes and refuses anything else', () => {
    expect(parseClientConfig({ mode: 'server' })).toEqual({ mode: 'server' });
    expect(parseClientConfig({ mode: 'direct' })).toEqual({ mode: 'direct' });
    expect(parseClientConfig({ mode: 'direct', sourceUrl: 'https://example.com/src' })).toEqual({ mode: 'direct', sourceUrl: 'https://example.com/src' });
    for (const bad of [null, [], 'direct', {}, { mode: 'static' }, { mode: 'direct', extra: 1 }, { mode: 'direct', sourceUrl: 'http://x' }, { mode: 'server', sourceUrl: 'https://x' }]) {
      expect(() => parseClientConfig(bad), JSON.stringify(bad)).toThrow(ClientConfigError);
    }
  });

  it('treats a missing file as a configuration error and an unreachable server as down', async () => {
    await expect(loadClientConfig((async () => new Response('nope', { status: 404 })) as typeof fetch)).rejects.toMatchObject({ network: false });
    await expect(loadClientConfig((async () => new Response('{bad')) as typeof fetch)).rejects.toMatchObject({ network: false });
    await expect(loadClientConfig((async () => Promise.reject(new TypeError('down'))) as typeof fetch)).rejects.toMatchObject({ network: true });
    expect(await loadClientConfig((async () => Response.json({ mode: 'direct' })) as typeof fetch)).toEqual({ mode: 'direct' });
  });
});

describe('credential vault', () => {
  it('seals and opens with the passphrase, with a fresh salt each time', async () => {
    const a = await sealCredentials('correct horse', CREDS);
    const b = await sealCredentials('correct horse', CREDS);
    expect(a.v).toBe(1);
    expect(a.salt).toHaveLength(16);
    expect(a.iv).toHaveLength(12);
    expect(Buffer.from(a.salt).equals(Buffer.from(b.salt))).toBe(false);
    expect(await openCredentials('correct horse', a)).toEqual(CREDS);
    const plain = Buffer.from(a.ciphertext).toString('latin1');
    expect(plain).not.toContain(CREDS.accessKeyId);
    expect(plain).not.toContain(CREDS.secretAccessKey);
  });

  it('fails a wrong passphrase and another AAD with wrongPassphrase', async () => {
    const r = await sealCredentials('correct horse', CREDS);
    await expect(openCredentials('wrong horse', r)).rejects.toEqual(new VaultError('wrongPassphrase'));
    await expect(openCredentials('correct horse', r, 'local/credentials/v2')).rejects.toEqual(new VaultError('wrongPassphrase'));
    expect(VAULT_AAD).toBe('local/credentials/v1');
    await expect(openCredentials('correct horse', { ...r, v: 2 } as never)).rejects.toEqual(new VaultError('invalidRecord'));
  });
});

describe('S3Backend canary (spec §6.4)', () => {
  const cases: [string, FakeS3Faults, { writes: boolean; deletes: boolean }][] = [
    ['a compliant provider', {}, { writes: true, deletes: true }],
    ['one that ignores If-None-Match', { ignoreIfNoneMatch: true }, { writes: false, deletes: true }],
    ['one that ignores If-Match on PUT', { ignoreIfMatch: true }, { writes: false, deletes: true }],
    ['one that reissues an ETag for different bytes', { reuseETag: true }, { writes: false, deletes: true }],
    ['one where the old ETag still matches', { acceptOldETag: true }, { writes: false, deletes: true }],
    ['one that ignores If-Match on DELETE', { ignoreDeleteIfMatch: true }, { writes: true, deletes: false }],
    ['one that rejects the right If-Match DELETE', { rejectDeleteIfMatch: true }, { writes: true, deletes: false }],
    ['one that answers 501 to conditional requests', { notImplemented: true }, { writes: false, deletes: false }],
  ];
  for (const [name, faults, expected] of cases) {
    it(`marks ${name}`, async () => {
      const fake = new FakeS3('upstream', faults);
      const b = s3(fake);
      expect(await b.atomicConditionalWrites()).toBe(expected.writes);
      expect(await b.atomicConditionalDelete()).toBe(expected.deletes);
      expect(b.capabilities).toEqual(expected);
      // The canary never stays behind.
      expect([...fake.objects.keys()].filter((k) => k.includes('.canary/'))).toEqual([]);
    });
  }

  it('marks nothing when the canary fails, and runs again next time', async () => {
    const fake = new FakeS3();
    fake.down = true;
    const b = s3(fake);
    expect(await b.atomicConditionalWrites()).toBe(false);
    fake.down = false;
    expect(await b.atomicConditionalWrites()).toBe(true);
  });

  it('refuses a conditional delete without sending one when deletes are unsupported', async () => {
    const fake = new FakeS3('upstream', { ignoreDeleteIfMatch: true });
    const b = s3(fake);
    await b.put('noteit/v1/manifest.json', utf8('{}'));
    await b.verifyConditionals();
    const before = fake.requests.length;
    await expect(b.delete('noteit/v1/manifest.json', { ifMatch: 'x' })).rejects.toMatchObject({ kind: 'conditionalDeleteUnsupported' });
    expect(fake.requests.length).toBe(before);
  });

  it("deletes other clients' canaries only once they are 10 minutes old", async () => {
    const fake = new FakeS3();
    const old = new Date(Date.now() - 11 * 60_000);
    fake.objects.set(`notes/${CANARY_PREFIX}${newUuid()}`, { data: utf8('x'), etag: 'a', history: [], lastModified: old });
    const young = `notes/${CANARY_PREFIX}${newUuid()}`;
    fake.objects.set(young, { data: utf8('x'), etag: 'b', history: [], lastModified: new Date() });
    await s3(fake).verifyConditionals();
    expect([...fake.objects.keys()]).toEqual([young]);
  });

  it('sends every request uncached, without credentials and without following redirects', async () => {
    const fake = new FakeS3();
    const inits: RequestInit[] = [];
    const spy = ((i: RequestInfo | URL, init: RequestInit) => {
      inits.push(init);
      return fake.fetch(i, init);
    }) as typeof fetch;
    await s3(fake, { fetch: spy }).verifyConditionals();
    expect(inits.length).toBeGreaterThan(5);
    for (const init of inits) expect(init).toMatchObject({ cache: 'no-store', credentials: 'omit', redirect: 'error' });
  });
});

describe('connect wizard CORS check', () => {
  /** A FakeS3 behind a "browser" that turns chosen requests into CORS failures (a TypeError, no status). */
  function browserFetch(fake: FakeS3, block: { list?: boolean; put?: boolean; hideETag?: boolean }): typeof fetch {
    return (async (input: RequestInfo | URL, init: RequestInit = {}) => {
      const method = (init.method ?? 'GET').toUpperCase();
      const isList = new URL(String(input)).searchParams.has('list-type');
      if (block.list && isList) throw new TypeError('Failed to fetch');
      if (block.put && method === 'PUT') throw new TypeError('Failed to fetch');
      const res = await fake.fetch(input, init);
      if (!block.hideETag) return res;
      const headers = new Headers(res.headers);
      headers.delete('etag');
      return new Response(res.body, { status: res.status, headers });
    }) as typeof fetch;
  }

  it('passes on a compliant bucket and reports what the provider honours', async () => {
    const fake = new FakeS3();
    expect(await corsCheck(s3(fake))).toEqual({ ok: true, writes: true, deletes: true });
    expect(fake.objects.size).toBe(0);
    const weak = new FakeS3('upstream', { ignoreDeleteIfMatch: true });
    expect(await corsCheck(s3(weak))).toEqual({ ok: true, writes: true, deletes: false });
  });

  it('names the step that failed and always deletes its canary', async () => {
    const list = new FakeS3();
    expect(await corsCheck(s3(list, { fetch: browserFetch(list, { list: true }) }))).toMatchObject({ ok: false, problem: 'originNotAllowed' });
    const put = new FakeS3();
    expect(await corsCheck(s3(put, { fetch: browserFetch(put, { put: true }) }))).toMatchObject({ ok: false, problem: 'putNotAllowed' });
    const etag = new FakeS3();
    const result = await corsCheck(s3(etag, { fetch: browserFetch(etag, { hideETag: true }) }));
    expect(result).toMatchObject({ ok: false, problem: 'etagNotExposed' });
    expect(etag.objects.size).toBe(0);
    // A provider whose CORS rules leave out DELETE: the canary can't finish.
    const del = new FakeS3();
    const noDelete = (async (i: RequestInfo | URL, init: RequestInit = {}) => {
      if ((init.method ?? 'GET').toUpperCase() === 'DELETE') throw new TypeError('Failed to fetch');
      return del.fetch(i, init);
    }) as typeof fetch;
    expect(await corsCheck(s3(del, { fetch: noDelete }))).toMatchObject({ ok: false, problem: 'conditionalNotAllowed' });
    const creds = new FakeS3();
    const denied = (async (i: RequestInfo | URL, init: RequestInit) => new Response('<Error><Code>InvalidAccessKeyId</Code><Message>no</Message></Error>', { status: 403 })) as typeof fetch;
    expect(await corsCheck(s3(creds, { fetch: denied }))).toMatchObject({ ok: false, problem: 'unauthorized' });
  });
});

describe('provider CORS examples', () => {
  it('allow the methods and headers direct mode sends, and expose ETag', () => {
    const origin = 'https://notes.example.com';
    const aws = JSON.parse(awsCors(origin)).CORSRules[0];
    const r2 = JSON.parse(r2Cors(origin))[0];
    for (const rule of [aws, r2]) {
      expect(rule.AllowedOrigins).toEqual([origin]);
      expect(rule.AllowedMethods).toEqual(expect.arrayContaining(['GET', 'PUT', 'HEAD', 'DELETE']));
      expect(rule.AllowedHeaders).toEqual(expect.arrayContaining(['authorization', 'if-match', 'if-none-match', 'x-amz-date', 'x-amz-content-sha256']));
      expect(rule.ExposeHeaders).toEqual(['ETag']);
    }
    const b2 = JSON.parse(b2CorsRules(origin))[0];
    expect(b2.allowedOperations).toEqual(['s3_get', 's3_head', 's3_put', 's3_delete']);
    expect(b2.exposeHeaders).toEqual(['ETag']);
    expect(b2.allowedHeaders).toEqual(CORS_HEADERS);
    expect(corsExamples(origin).map((e) => e.id)).toEqual(['aws', 'r2', 'minio', 'b2']);
  });
});

class Local implements SyncLocalStore {
  items = new Map<string, RecordPayload>();
  async records(): Promise<LocalRecord[]> {
    return [...this.items.values()].map((p) => ({ id: p.id, kind: p.kind, revision: p.revision, modifiedAt: p.modifiedAt }));
  }
  async deletions() {
    return new Map<string, LocalDeletion>();
  }
  async export(id: string) {
    return this.items.get(id)!;
  }
  async apply(p: RecordPayload) {
    this.items.set(p.id, p);
  }
  async applyDeletion(id: string) {
    this.items.delete(id);
  }
  async importConflictCopy() {}
  async clearDeletion() {}
  async revision(id: string) {
    return this.items.get(id)?.revision;
  }
  async passDidFinish() {}
}

describe('direct mode end to end', () => {
  it('two browsers share one bucket prefix with the vault, and only ciphertext lands in it', async () => {
    const fake = new FakeS3();
    // Browser A runs the wizard: CORS check, then a new store, then the vault.
    const a = s3(fake);
    expect((await corsCheck(a)).ok).toBe(true);
    const { session: sa, created } = await connect(a, { passphrase: 'shared sync passphrase', createIfMissing: true });
    expect(created).toBe(true);
    const vault = await sealCredentials('shared sync passphrase', CREDS);
    // A reload opens the vault, then the store, with the one passphrase.
    const reopened = await openCredentials('shared sync passphrase', vault);
    const a2 = new S3Backend(reopened, fake.fetch, undefined, [0, 0]);
    const localA = new Local();
    const id = newUuid();
    const body = utf8(JSON.stringify({ format: 'noteit-doc', version: 1, doc: { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Secret plan' }] }] }, attachments: {} }));
    localA.items.set(id, { id, kind: 'note', revision: newUuid(), modifiedAt: new Date(), deviceID: 'A', meta: utf8('{"title":"Secret plan"}'), body, bodyFormat: 'noteit-doc/1' });
    const engineA = new SyncEngine({ backend: a2, session: sa, local: localA, state: new MemoryStateStore(), deviceID: 'A', deviceName: 'Web A', appVersion: 'web' });
    const pushed = await engineA.sync();
    expect(pushed.errors).toEqual([]);

    const b = s3(fake);
    const { session: sb } = await connect(b, { passphrase: 'shared sync passphrase', createIfMissing: false });
    const localB = new Local();
    await new SyncEngine({ backend: b, session: sb, local: localB, state: new MemoryStateStore(), deviceID: 'B', deviceName: 'Web B', appVersion: 'web' }).sync();
    expect([...localB.items.keys()]).toContain(id);

    expect([...fake.objects.keys()].every((k) => k.startsWith('notes/noteit/'))).toBe(true);
    for (const [key, o] of fake.objects) expect(Buffer.from(o.data).toString('latin1'), key).not.toContain('Secret plan');
  });
});
