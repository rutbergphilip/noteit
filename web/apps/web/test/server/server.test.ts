import { readdir } from 'node:fs/promises';
import { request } from 'node:http';
import { join } from 'node:path';
import {
  connect,
  HttpProxyBackend,
  isValidKey,
  keys,
  MemoryStateStore,
  newUuid,
  S3Backend,
  StorageError,
  SyncEngine,
  utf8,
  fromUtf8,
  type LocalDeletion,
  type LocalRecord,
  type RecordPayload,
  type SyncLocalStore,
} from '@noteit/core';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { action, browser, type Harness, SETUP_TOKEN, startServer } from './harness';

const PASS = 'a sync passphrase never sent to the server';

/** Minimal local store for driving the engine end to end. */
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

function rawRequest(url: string, method: string, path: string, headers: Record<string, string> = {}): Promise<{ status: number; body: string }> {
  const u = new URL(url);
  return new Promise((resolve, reject) => {
    const req = request({ host: u.hostname, port: u.port, method, path, headers }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

const docBody = (text: string) => utf8(JSON.stringify({ format: 'noteit-doc', version: 1, doc: { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text }] }] }, attachments: {} }));

describe('NoteIt server', () => {
  let h: Harness;
  let admin: ReturnType<typeof browser>;

  beforeAll(async () => {
    h = await startServer();
    admin = browser(h.url);
  });
  afterAll(async () => h.close());

  it('gates everything behind first-admin setup', async () => {
    expect((await action(admin, 'server-info', undefined, { method: 'GET' })).data.needsSetup).toBe(true);
    expect((await action(admin, 'session', undefined, { method: 'GET' })).data).toBeNull();
    expect((await admin.fetch('/api/storage/list?prefix=noteit/')).status).toBe(503);
    expect((await action(admin, 'account/create-s3-key', {})).serverError?.code).toBe('unauthorized');
    const wrong = await action(admin, 'setup', { token: 'wrong', username: 'admin', password: 'long enough password' });
    expect(wrong.businessError?.code).toBe('invalidSetupToken');
    expect(wrong.validationErrors?.token).toBeDefined();
    const short = await action(admin, 'setup', { token: SETUP_TOKEN, username: 'A B', password: 'short' });
    expect(Object.keys(short.validationErrors ?? {}).sort()).toEqual(['password', 'username']);
    const res = await admin.fetch('/api/_actions/setup', { method: 'POST', body: JSON.stringify({ token: SETUP_TOKEN, username: 'admin', password: 'long enough password' }) });
    expect(res.status).toBe(200);
    expect((await res.json()).data.user.role).toBe('admin');
    expect(admin.cookie()).toMatch(/^noteit_session=/);
    expect(res.headers.get('set-cookie')).toMatch(/HttpOnly/i);
    expect(res.headers.get('set-cookie')).toMatch(/SameSite=Strict/i);
    expect((await action(admin, 'setup', { token: SETUP_TOKEN, username: 'x2', password: 'long enough password' })).businessError?.code).toBe('alreadySetUp');
    expect((await action(admin, 'server-info', undefined, { method: 'GET' })).data.needsSetup).toBe(false);
    const session = await action(admin, 'session', undefined, { method: 'GET' });
    expect(session.data.user.role).toBe('admin');
  });

  it('sends security headers and enforces CSRF on writes', async () => {
    const res = await fetch(`${h.url}/api/health`);
    expect(res.headers.get('content-security-policy')).toContain("default-src 'self'");
    expect(res.headers.get('x-content-type-options')).toBe('nosniff');
    // Actions: JSON only (a cross-site page can't send it without a preflight), same Origin, same-origin fetch site.
    const evil = await action(admin, 'sign-out', {}, { headers: { origin: 'https://evil.example' } });
    expect(evil.status).toBe(403);
    expect(evil.serverError?.code).toBe('forbidden');
    expect((await action(admin, 'sign-out', {}, { headers: { origin: '' } })).status).toBe(403);
    expect((await action(admin, 'sign-out', {}, { headers: { 'sec-fetch-site': 'cross-site' } })).status).toBe(403);
    const form = await admin.fetch('/api/_actions/sign-out', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'a=1' });
    expect(form.status).toBe(415);
    const text = await admin.fetch('/api/_actions/admin/create-invite', { method: 'POST', headers: { 'content-type': 'text/plain' }, body: '{}' });
    expect(text.status).toBe(415);
    expect(h.ctx.accounts.invites).toHaveLength(0);
    // None of those signed us out.
    expect((await action(admin, 'session', undefined, { method: 'GET' })).data.user.username).toBe('admin');
    // The data plane keeps its X-NoteIt header check.
    const put = (headers: Record<string, string>) => admin.fetch('/api/storage/object/noteit/v1/devices/Z.json', { method: 'PUT', headers: { 'content-type': 'application/octet-stream', ...headers }, body: 'x' });
    expect((await put({ 'x-noteit': '0' })).status).toBe(403);
    expect((await put({ origin: 'https://evil.example' })).status).toBe(403);
  });

  it('checks auth, admin role and the forced password change in action middleware', async () => {
    const anon = browser(h.url);
    expect((await action(anon, 'account/s3-keys', undefined, { method: 'GET' })).serverError?.code).toBe('unauthorized');
    expect((await action(anon, 'admin/create-invite', {})).serverError?.code).toBe('unauthorized');
    const created = await action(admin, 'admin/create-user', { username: 'carol' });
    expect(created.data.user.mustChangePassword).toBe(true);
    expect((await action(admin, 'admin/create-user', { username: 'Carol' })).validationErrors?.username).toEqual(['That username is taken.']);
    const carol = browser(h.url);
    expect((await action(carol, 'sign-in', { username: 'carol', password: created.data.temporaryPassword })).data.user.mustChangePassword).toBe(true);
    expect((await action(carol, 'account/create-s3-key', {})).serverError?.code).toBe('passwordChangeRequired');
    expect((await carol.fetch('/api/storage/list?prefix=noteit/')).status).toBe(403);
    expect((await action(carol, 'account/change-password', { current: 'not it at all', next: 'carols new password' })).businessError?.code).toBe('wrongPassword');
    expect((await action(carol, 'account/change-password', { current: created.data.temporaryPassword, next: 'short' })).validationErrors?.next).toBeDefined();
    expect((await action(carol, 'account/change-password', { current: created.data.temporaryPassword, next: 'carols new password' })).data).toBe(true);
    expect((await action(carol, 'account/s3-keys', undefined, { method: 'GET' })).data).toEqual([]);
    expect((await action(carol, 'admin/users', undefined, { method: 'GET' })).serverError?.code).toBe('forbidden');
    const id = h.ctx.accounts.byUsername('carol')!.id;
    expect((await action(admin, 'admin/delete-user', { id, confirmUsername: 'nope' })).businessError?.code).toBe('confirmMismatch');
    expect((await action(admin, 'admin/delete-user', { id, confirmUsername: 'carol' })).data).toBe(true);
    expect((await action(carol, 'session', undefined, { method: 'GET' })).data).toBeNull();
  });

  it('rejects bad logins with a uniform error', async () => {
    const anon = browser(h.url);
    const r1 = await action(anon, 'sign-in', { username: 'admin', password: 'wrong password!' });
    const r2 = await action(anon, 'sign-in', { username: 'nobody', password: 'wrong password!' });
    expect(r1.businessError?.code).toBe('invalidCredentials');
    expect(r1).toEqual(r2);
    expect(anon.cookie()).toBeUndefined();
    expect((await anon.fetch('/api/storage/list?prefix=noteit/')).status).toBe(401);
  });

  it('syncs two browsers through /api/storage and stores only ciphertext', async () => {
    const backend = new HttpProxyBackend({ baseUrl: h.url, fetch: admin.fetch });
    const { session, created } = await connect(backend, { passphrase: PASS, createIfMissing: true });
    expect(created).toBe(true);
    const a = new Local();
    const b = new Local();
    const engineA = new SyncEngine({ backend, session, local: a, state: new MemoryStateStore(), deviceID: 'WEB-A', deviceName: 'A' });
    const engineB = new SyncEngine({ backend, session: (await connect(backend, { passphrase: PASS, createIfMissing: false })).session, local: b, state: new MemoryStateStore(), deviceID: 'WEB-B', deviceName: 'B' });
    const id = newUuid();
    a.items.set(id, { id, kind: 'note', revision: newUuid(), modifiedAt: new Date(), deviceID: 'WEB-A', meta: utf8('{"title":"secret plans"}'), body: docBody('secret plans'), bodyFormat: 'noteit-doc/1' });
    expect((await engineA.sync()).errors).toEqual([]);
    expect((await engineB.sync()).errors).toEqual([]);
    expect(fromUtf8(b.items.get(id)!.meta)).toBe('{"title":"secret plans"}');

    const user = h.ctx.accounts.byUsername('admin')!;
    const files = await h.ctx.store.list(user.id, 'noteit/');
    expect(files.some((f) => f.key.startsWith('noteit/v1/bodies/'))).toBe(true);
    for (const f of files) {
      if (f.key === keys.manifest) continue;
      const obj = await h.ctx.store.get(user.id, f.key);
      expect(Buffer.from(obj!.data).toString('latin1')).not.toContain('secret plans');
    }
  });

  it('never lets a key leave the namespace', async () => {
    const cookie = admin.cookie()!;
    const headers = { cookie, origin: h.url, 'x-noteit': '1' };
    const attempts = [
      '/api/storage/object/noteit/v1/../../../../etc/passwd',
      '/api/storage/object/noteit/v1/%2e%2e/%2e%2e/escape.json',
      '/api/storage/object/noteit/v1/notes/..%2F..%2Fescape.meta',
      '/api/storage/object/noteit%2Fv1%2Fmanifest.json',
      '/api/storage/object/noteit/v1/notes/x%5C..%5Cy.meta',
      '/api/storage/object/noteit/v1/notes/%00.meta',
      '/api/storage/object/noteit/v1/notes//x.meta',
      '/api/storage/object/noteit/v1/unknown/x.json',
      '/api/storage/object/',
    ];
    for (const path of attempts) {
      for (const method of ['PUT', 'GET', 'DELETE']) {
        const res = await rawRequest(h.url, method, path, headers);
        expect([400, 404], `${method} ${path} → ${res.status}`).toContain(res.status);
        expect(res.status, `${method} ${path}`).not.toBe(200);
      }
    }
    for (const prefix of ['../', 'noteit/../../', '', 'noteit/v1/notes', '/etc/']) {
      const res = await rawRequest(h.url, 'GET', `/api/storage/list?prefix=${encodeURIComponent(prefix)}`, headers);
      expect(res.status, prefix).toBe(400);
    }
    // Nothing was written outside users/<id>/.
    expect((await readdir(h.dataDir)).sort()).toEqual(['accounts.json', 'session-secret', 'tmp', 'users']);
    const user = h.ctx.accounts.byUsername('admin')!;
    expect(await readdir(join(h.dataDir, 'users'))).toEqual([user.id]);
    for (const f of await h.ctx.store.list(user.id, 'noteit/')) expect(isValidKey(f.key)).toBe(true);
  });

  it('serves the S3 subset with per-user keys, SigV4 and conditional requests', async () => {
    const created = (await action(admin, 'account/create-s3-key', { label: 'Mac' })).data;
    expect(created.accessKeyId).toMatch(/^NIK[A-Z2-7]{17}$/);
    const cfg = { endpoint: `${h.url}/s3`, bucket: 'noteit', region: 'us-east-1', accessKeyId: created.accessKeyId, secretAccessKey: created.secretAccessKey, pathStyle: true };
    const s3 = new S3Backend(cfg);
    // The native canary: If-None-Match, a bogus If-Match and a bogus conditional delete must all be refused.
    expect(await s3.atomicConditionalWrites()).toBe(true);
    expect(await s3.atomicConditionalDelete()).toBe(true);
    // The store the browser created is visible to the S3 client (same namespace).
    const listed = await s3.list('noteit/v1/');
    expect(listed.some((o) => o.key === keys.manifest)).toBe(true);
    // A native-style device joins and pulls the browser's note over /s3.
    const { session } = await connect(s3, { passphrase: PASS, createIfMissing: false });
    const mac = new Local();
    const report = await new SyncEngine({ backend: s3, session, local: mac, state: new MemoryStateStore(), deviceID: 'MAC-1', deviceName: 'Mac' }).sync();
    expect(report.errors).toEqual([]);
    expect([...mac.items.values()].map((p) => fromUtf8(p.meta))).toContain('{"title":"secret plans"}');

    const key = `noteit/.canary/${newUuid()}`;
    const etag = await s3.put(key, utf8('x'), { ifNoneMatch: true });
    await expect(s3.put(key, utf8('y'), { ifNoneMatch: true })).rejects.toMatchObject({ kind: 'preconditionFailed' });
    await expect(s3.put(key, utf8('y'), { ifMatch: 'nope' })).rejects.toMatchObject({ kind: 'preconditionFailed' });
    await s3.put(key, utf8('y'), { ifMatch: etag });
    await expect(s3.delete(key, { ifMatch: etag })).rejects.toMatchObject({ kind: 'preconditionFailed' });
    await s3.delete(key);

    const wrong = new S3Backend({ ...cfg, secretAccessKey: 'not-the-secret' });
    await expect(wrong.list('noteit/')).rejects.toMatchObject({ kind: 'unauthorized' });
    const unknown = new S3Backend({ ...cfg, accessKeyId: 'NIKAAAAAAAAAAAAAAAAA' });
    await expect(unknown.list('noteit/')).rejects.toMatchObject({ kind: 'unauthorized' });
    const skewed = new S3Backend(cfg, undefined, () => new Date(Date.now() - 3_600_000));
    await expect(skewed.list('noteit/')).rejects.toMatchObject({ kind: 'clockSkew' });
  });

  it('lists with delimiters, paging and the ListObjects v1 refusal', async () => {
    const created = (await action(admin, 'account/create-s3-key', { label: 'rclone' })).data;
    const s3 = new S3Backend({ endpoint: `${h.url}/s3`, bucket: 'noteit', region: 'us-east-1', accessKeyId: created.accessKeyId, secretAccessKey: created.secretAccessKey, pathStyle: true });
    const url = s3.makeURL(undefined, [['list-type', '2'], ['prefix', 'noteit/v1/'], ['delimiter', '/'], ['max-keys', '2']]);
    const { signRequest, EMPTY_PAYLOAD_SHA256 } = await import('@noteit/core');
    const send = async (u: URL) => {
      const headers = await signRequest({ method: 'GET', url: u, headers: {}, payloadHash: EMPTY_PAYLOAD_SHA256, accessKeyId: created.accessKeyId, secretAccessKey: created.secretAccessKey, region: 'us-east-1', date: new Date() });
      return fetch(u, { headers });
    };
    const page1 = await (await send(url)).text();
    expect(page1).toContain('<IsTruncated>true</IsTruncated>');
    expect(page1).toContain('<CommonPrefixes><Prefix>noteit/v1/bodies/</Prefix></CommonPrefixes>');
    const token = /<NextContinuationToken>([^<]+)</.exec(page1)![1]!;
    const page2 = await (await send(s3.makeURL(undefined, [['list-type', '2'], ['prefix', 'noteit/v1/'], ['delimiter', '/'], ['continuation-token', token]]))).text();
    expect(page2).not.toContain('noteit/v1/bodies/');
    expect(page2).toContain('<Key>noteit/v1/manifest.json</Key>');
    const v1 = await send(s3.makeURL(undefined, [['prefix', 'noteit/']]));
    expect(v1.status).toBe(501);
    const otherBucket = await send(new URL(`${h.url}/s3/other/?list-type=2`));
    expect(otherBucket.status).toBe(404);
    const escape = await send(new URL(`${h.url}/s3/noteit/noteit/v1/notes/..%2F..%2Fx.meta`));
    expect(escape.status).toBe(400);
  });

  it('isolates users: invites, separate namespaces and S3 keys', async () => {
    const invite = (await action(admin, 'admin/create-invite', { role: 'user' })).data;
    const bob = browser(h.url);
    expect((await action(bob, 'redeem-invite', { token: invite.token, username: 'bob', password: 'bobs long password' })).data.user.username).toBe('bob');
    expect((await action(bob, 'redeem-invite', { token: invite.token, username: 'bob2', password: 'bobs long password' })).businessError?.code).toBe('inviteInvalid');
    const bobBackend = new HttpProxyBackend({ baseUrl: h.url, fetch: bob.fetch });
    expect(await bobBackend.list('noteit/')).toEqual([]);
    expect((await action(bob, 'admin/users', undefined, { method: 'GET' })).serverError?.code).toBe('forbidden');
    const key = (await action(bob, 'account/create-s3-key', { label: 'b' })).data;
    const bobS3 = new S3Backend({ endpoint: `${h.url}/s3`, bucket: 'noteit', region: 'us-east-1', accessKeyId: key.accessKeyId, secretAccessKey: key.secretAccessKey, pathStyle: true });
    expect(await bobS3.list('noteit/')).toEqual([]);
    await expect(connect(bobS3, { passphrase: PASS, createIfMissing: false })).rejects.toMatchObject({ kind: 'storeMissing' });
  });

  it('enforces quotas', async () => {
    const users = (await action(admin, 'admin/users', undefined, { method: 'GET' })).data.users as { id: string; username: string }[];
    const bob = users.find((u) => u.username === 'bob')!;
    expect((await action(admin, 'admin/update-user', { id: bob.id, quotaBytes: 1000 })).data).toBe(true);
    const login = browser(h.url);
    await action(login, 'sign-in', { username: 'bob', password: 'bobs long password' });
    const backend = new HttpProxyBackend({ baseUrl: h.url, fetch: login.fetch });
    await backend.put('noteit/v1/devices/X.json', new Uint8Array(500));
    await expect(backend.put('noteit/v1/devices/Y.json', new Uint8Array(600))).rejects.toMatchObject({ kind: 'quotaExceeded' });
    await expect(backend.put('noteit/v1/devices/X.json', new Uint8Array(900))).resolves.toBeTypeOf('string');
  });

  it('refuses the last admin being demoted and disabled users', async () => {
    const me = h.ctx.accounts.byUsername('admin')!;
    expect((await action(admin, 'admin/update-user', { id: me.id, role: 'user' })).businessError?.code).toBe('lastAdmin');
    expect(h.ctx.accounts.byId(me.id)!.role).toBe('admin');
    const bob = h.ctx.accounts.byUsername('bob')!;
    const bobKey = bob.s3Keys[0]!;
    await action(admin, 'admin/update-user', { id: bob.id, status: 'disabled' });
    const s3 = new S3Backend({ endpoint: `${h.url}/s3`, bucket: 'noteit', region: 'us-east-1', accessKeyId: bobKey.accessKeyId, secretAccessKey: bobKey.secretAccessKey, pathStyle: true });
    await expect(s3.list('noteit/')).rejects.toBeInstanceOf(StorageError);
  });
});
