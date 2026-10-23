import { request } from 'node:http';
import { EMPTY_PAYLOAD_SHA256, signRequest, UNSIGNED_PAYLOAD } from '@noteit/core';
import type { H3Event } from 'h3';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { loadConfig } from '../../server/lib/config';
import { clientIp } from '../../server/lib/http';
import { browser, type Harness, SETUP_TOKEN, startServer } from './harness';

const MB = 1024 * 1024;

/** Sends a request whose body is written in chunks (Transfer-Encoding: chunked unless a length is given). */
function send(
  url: string,
  method: string,
  path: string,
  headers: Record<string, string>,
  chunks: Buffer[] = [],
): Promise<{ status: number; body: string }> {
  const u = new URL(url);
  return new Promise((resolve, reject) => {
    const req = request({ host: u.hostname, port: u.port, method, path, headers }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body }));
    });
    req.on('error', (e: NodeJS.ErrnoException) => (e.code === 'ECONNRESET' || e.code === 'EPIPE' ? resolve({ status: -1, body: '' }) : reject(e)));
    (async () => {
      for (const c of chunks) {
        if (!req.write(c)) await new Promise((r) => req.once('drain', r));
      }
      req.end();
    })().catch(() => undefined);
  });
}

describe('server hardening', () => {
  let h: Harness;
  let admin: ReturnType<typeof browser>;
  let key: { accessKeyId: string; secretAccessKey: string };

  beforeAll(async () => {
    h = await startServer({ NOTEIT_MAX_OBJECT_MB: '1' });
    admin = browser(h.url);
    await admin.fetch('/api/setup', { method: 'POST', body: JSON.stringify({ token: SETUP_TOKEN, username: 'admin', password: 'long enough password' }) });
    key = await (await admin.fetch('/api/account/s3-keys', { method: 'POST', body: JSON.stringify({ label: 't' }) })).json();
  });
  afterAll(async () => h.close());

  const s3Headers = async (method: string, path: string, payloadHash: string, extra: Record<string, string> = {}) => ({
    ...extra,
    ...(await signRequest({ method, url: new URL(h.url + path), headers: extra, payloadHash, accessKeyId: key.accessKeyId, secretAccessKey: key.secretAccessKey, region: 'us-east-1', date: new Date() })),
  });

  describe('request bodies', () => {
    it('refuses an unauthenticated S3 PUT before reading its body', async () => {
      const res = await send(h.url, 'PUT', '/s3/noteit/noteit/v1/devices/A.json', { 'content-length': String(10 * 1024 * MB), authorization: 'AWS4-HMAC-SHA256 Credential=NIKAAAAAAAAAAAAAAAAA/20260101/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=' + '0'.repeat(64) });
      expect(res.status).toBe(403);
      expect(res.body).toContain('InvalidAccessKeyId');
    });

    it('refuses an S3 PUT with a bad signature without reading its body', async () => {
      const headers = await s3Headers('PUT', '/s3/noteit/noteit/v1/devices/A.json', UNSIGNED_PAYLOAD);
      headers.authorization = headers.authorization!.replace(/Signature=[0-9a-f]+/, `Signature=${'1'.repeat(64)}`);
      const res = await send(h.url, 'PUT', '/s3/noteit/noteit/v1/devices/A.json', { ...headers, 'content-length': String(10 * 1024 * MB) });
      expect(res.status).toBe(403);
      expect(res.body).toContain('SignatureDoesNotMatch');
    });

    it('caps an authenticated S3 PUT by declared length and while streaming a chunked body', async () => {
      const path = '/s3/noteit/noteit/v1/devices/B.json';
      const declared = await send(h.url, 'PUT', path, { ...(await s3Headers('PUT', path, UNSIGNED_PAYLOAD)), 'content-length': String(2 * MB) });
      expect(declared.status).toBe(413);
      expect(declared.body).toContain('EntityTooLarge');
      const chunked = await send(h.url, 'PUT', path, await s3Headers('PUT', path, UNSIGNED_PAYLOAD), Array.from({ length: 40 }, () => Buffer.alloc(64 * 1024, 1)));
      expect([413, -1]).toContain(chunked.status);
      const user = h.ctx.accounts.byUsername('admin')!;
      expect(await h.ctx.store.head(user.id, 'noteit/v1/devices/B.json')).toBeNull();
      // A chunked body under the cap is fine.
      const ok = await send(h.url, 'PUT', path, await s3Headers('PUT', path, UNSIGNED_PAYLOAD), [Buffer.from('small')]);
      expect(ok.status).toBe(200);
    });

    it('compares a declared payload hash after streaming', async () => {
      const path = '/s3/noteit/noteit/v1/devices/C.json';
      const wrongHash = EMPTY_PAYLOAD_SHA256;
      const res = await send(h.url, 'PUT', path, { ...(await s3Headers('PUT', path, wrongHash)), 'content-length': '5' }, [Buffer.from('hello')]);
      expect(res.status).toBe(400);
      expect(res.body).toContain('XAmzContentSHA256Mismatch');
    });

    it('caps /api/storage uploads the same way', async () => {
      const path = '/api/storage/object/noteit/v1/devices/D.json';
      const headers = { cookie: admin.cookie()!, origin: h.url, 'x-noteit': '1' };
      expect((await send(h.url, 'PUT', path, { ...headers, 'content-length': String(2 * MB) })).status).toBe(413);
      const chunked = await send(h.url, 'PUT', path, headers, Array.from({ length: 40 }, () => Buffer.alloc(64 * 1024, 2)));
      expect([413, -1]).toContain(chunked.status);
      const anon = await send(h.url, 'PUT', path, { origin: h.url, 'x-noteit': '1', 'content-length': String(2 * MB) });
      expect(anon.status).toBe(401);
    });
  });

  it('never lets concurrent writes overshoot a quota', async () => {
    const me = h.ctx.accounts.byUsername('admin')!;
    const used = (await h.ctx.quotas.current(me.id)).bytes;
    await admin.fetch(`/api/admin/users/${me.id}`, { method: 'PATCH', body: JSON.stringify({ quotaBytes: used + 1000 }) });
    const results = await Promise.all(
      Array.from({ length: 12 }, (_, i) =>
        admin.fetch(`/api/storage/object/noteit/v1/devices/Q${i}.json`, { method: 'PUT', body: new Uint8Array(300), headers: { 'content-type': 'application/octet-stream' } }).then((r) => r.status),
      ),
    );
    expect(results.filter((s) => s === 200)).toHaveLength(3);
    expect(results.filter((s) => s === 507)).toHaveLength(9);
    const onDisk = await h.ctx.store.usage(me.id);
    expect(onDisk.bytes).toBeLessThanOrEqual(used + 1000);
    expect((await h.ctx.quotas.current(me.id)).bytes).toBe(onDisk.bytes);
  });

  describe('client address behind proxies', () => {
    const event = (xff: string | undefined, peer = '10.0.0.5') =>
      ({ node: { req: { headers: xff === undefined ? {} : { 'x-forwarded-for': xff }, socket: { remoteAddress: peer } } } }) as unknown as H3Event;

    it('ignores X-Forwarded-For unless proxies are trusted', () => {
      expect(clientIp(event('1.2.3.4'), loadConfig({}))).toBe('10.0.0.5');
    });

    it('counts trusted hops from the right, so a client-supplied prefix is ignored', () => {
      const one = loadConfig({ NOTEIT_TRUST_PROXY: 'true' });
      expect(clientIp(event('6.6.6.6, 203.0.113.9'), one)).toBe('203.0.113.9');
      expect(clientIp(event('203.0.113.9'), one)).toBe('203.0.113.9');
      const two = loadConfig({ NOTEIT_TRUST_PROXY: 'true', NOTEIT_TRUSTED_PROXY_HOPS: '2' });
      expect(clientIp(event('6.6.6.6, 203.0.113.9, 172.16.0.2'), two)).toBe('203.0.113.9');
      expect(clientIp(event('172.16.0.2'), two)).toBe('10.0.0.5');
      expect(clientIp(event(undefined), two)).toBe('10.0.0.5');
    });

    it('keeps rate-limiting a client that rotates spoofed X-Forwarded-For prefixes', async () => {
      const proxied = await startServer({ NOTEIT_TRUST_PROXY: 'true' });
      try {
        const b = browser(proxied.url);
        const statuses: number[] = [];
        for (let i = 0; i < 14; i++) {
          const res = await b.fetch('/api/setup', {
            method: 'POST',
            headers: { 'x-forwarded-for': `9.9.9.${i}, 198.51.100.7` },
            body: JSON.stringify({ token: 'wrong', username: 'admin', password: 'long enough password' }),
          });
          statuses.push(res.status);
        }
        expect(statuses.slice(0, 10).every((s) => s === 403)).toBe(true);
        expect(statuses.slice(10).every((s) => s === 429)).toBe(true);
      } finally {
        await proxied.close();
      }
    });
  });
});
