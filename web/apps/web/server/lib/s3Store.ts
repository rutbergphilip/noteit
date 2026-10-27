import { randomUUID } from 'node:crypto';
import {
  copyBytes,
  EMPTY_PAYLOAD_SHA256,
  isCanonicalUuid,
  isListablePrefix,
  isValidKey,
  parseError,
  parseListV2,
  sha256Hex,
  signRequest,
  unquoteETag,
  uriEncode,
} from '@noteit/core';
import { InvalidKeyError } from './diskStore';
import { type DeleteResult, type ObjectStore, type PutResult, type StoredObject, StoreUnavailable } from './store';

export interface S3StoreConfig {
  endpoint: string;
  region: string;
  bucket: string;
  /** Key prefix inside the bucket, without slashes at either end; '' for the bucket root. */
  prefix: string;
  pathStyle: boolean;
  accessKeyId: string;
  secretAccessKey: string;
  /** Per-request timeout; a timeout is a failed request, never retried. */
  timeoutMs: number;
}

/** The upstream lacks a capability the server relies on; the server refuses to start (spec §6.2). */
export class UpstreamCapabilityError extends Error {}

class Status {
  constructor(
    readonly status: number,
    readonly code: string | undefined,
  ) {}
}

/**
 * Upstream S3 driver (spec §6.2): `<prefix>/users/<USER-UUID>/<key>` in one bucket, with the same SigV4 signer the
 * browser uses (@noteit/core). Unlike the client S3Backend it never falls back to HEAD-verified writes: the
 * upstream must have atomic conditional writes and deletes and unique ETags, which `init()` checks with the
 * extended canary. Conditional requests are sent once; nothing is retried.
 *
 * Availability: until the canary has reached the upstream once, `started()` is false and the canary is retried
 * every `retryMs`. After 3 consecutive failed requests `ready()` turns false and a one-key listing probes every
 * `retryMs` until it succeeds. Neither state stops the process.
 */
export class S3Store implements ObjectStore {
  readonly kind = 's3';
  private readonly base: string;
  private isStarted = false;
  private isAvailable = true;
  private failures = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private closed = false;

  constructor(
    private readonly cfg: S3StoreConfig,
    private readonly log: (msg: string) => void,
    private readonly fetchImpl: typeof fetch = (i, init) => fetch(i, init),
    private readonly retryMs = 10_000,
  ) {
    const prefix = cfg.prefix.replace(/^\/+|\/+$/g, '');
    if (prefix && !prefix.split('/').every((s) => /^[A-Za-z0-9._-]{1,128}$/.test(s) && s !== '.' && s !== '..')) {
      throw new Error(`NOTEIT_S3_PREFIX ${JSON.stringify(cfg.prefix)} is not a valid key prefix`);
    }
    this.base = prefix ? `${prefix}/` : '';
  }

  started(): boolean {
    return this.isStarted;
  }

  ready(): boolean {
    return this.isStarted && this.isAvailable;
  }

  close(): void {
    this.closed = true;
    clearTimeout(this.timer);
  }

  async init(): Promise<void> {
    try {
      await this.canary();
      this.isStarted = true;
      this.log(`NoteIt store: upstream S3 bucket ${this.cfg.bucket}${this.base ? ` under ${this.base}` : ''} passed the conditional-request checks`);
    } catch (e) {
      if (e instanceof UpstreamCapabilityError) throw e;
      this.log(`NoteIt store: upstream S3 unreachable (${(e as Error).message}); retrying every ${this.retryMs / 1000} s`);
      this.schedule(() => this.init());
    }
  }

  private schedule(fn: () => Promise<void>): void {
    if (this.closed) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      fn().catch((e) => this.log(`NoteIt store: ${(e as Error).message}`));
    }, this.retryMs);
    this.timer.unref?.();
  }

  // MARK: keys

  private userBase(userId: string): string {
    if (!isCanonicalUuid(userId)) throw new InvalidKeyError('bad user id');
    return `${this.base}users/${userId}/`;
  }

  private objectKey(userId: string, key: string): string {
    if (!isValidKey(key)) throw new InvalidKeyError(`invalid key ${JSON.stringify(key)}`);
    return this.userBase(userId) + key;
  }

  private url(fullKey: string | undefined, query: [string, string][] = []): URL {
    const endpoint = new URL(this.cfg.endpoint);
    const basePath = endpoint.pathname.replace(/\/$/, '');
    const key = fullKey !== undefined ? uriEncode(fullKey, false) : '';
    let path: string;
    if (this.cfg.pathStyle) path = `${basePath}/${uriEncode(this.cfg.bucket)}/${key}`;
    else {
      endpoint.hostname = `${this.cfg.bucket}.${endpoint.hostname}`;
      path = `${basePath}/${key}`;
    }
    const url = new URL(endpoint.origin);
    url.pathname = path;
    url.search = query.map(([k, v]) => `${uriEncode(k)}=${uriEncode(v)}`).join('&');
    return url;
  }

  // MARK: requests

  /**
   * One signed request. Returns the response for 2xx, a Status for the 4xx answers callers handle (404, 409, 412,
   * 501), and throws StoreUnavailable for everything else (network, timeout, 5xx, auth or other client errors).
   */
  private async send(
    method: string,
    fullKey: string | undefined,
    opts: { query?: [string, string][]; body?: Uint8Array; headers?: Record<string, string> } = {},
  ): Promise<Response | Status> {
    const url = this.url(fullKey, opts.query);
    const headers = opts.headers ?? {};
    let res: Response;
    try {
      const signed = await signRequest({
        method,
        url,
        headers,
        payloadHash: opts.body ? await sha256Hex(opts.body) : EMPTY_PAYLOAD_SHA256,
        accessKeyId: this.cfg.accessKeyId,
        secretAccessKey: this.cfg.secretAccessKey,
        region: this.cfg.region,
        date: new Date(),
      });
      const init: RequestInit = { method, headers: { ...headers, ...signed }, redirect: 'error', signal: AbortSignal.timeout(this.cfg.timeoutMs) };
      if (opts.body) init.body = copyBytes(opts.body);
      res = await this.fetchImpl(url, init);
    } catch (e) {
      throw this.failed(`${method} ${fullKey ?? '/'}: ${(e as Error).message}`);
    }
    if (res.ok) {
      this.succeeded();
      return res;
    }
    const text = method === 'HEAD' ? '' : await res.text().catch(() => '');
    const code = parseError(text)?.code;
    if (res.status === 404 || res.status === 409 || res.status === 412 || res.status === 501 || code === 'NotImplemented') {
      this.succeeded();
      return new Status(res.status, code);
    }
    if (res.status >= 500) throw this.failed(`${method} ${fullKey ?? '/'}: HTTP ${res.status}${code ? ` ${code}` : ''}`);
    // Credentials, bucket or clock: the operator has to fix it; the request reached the upstream, so it is up.
    this.succeeded();
    this.log(`NoteIt store: upstream S3 refused ${method} ${fullKey ?? '/'}: HTTP ${res.status}${code ? ` ${code}` : ''}`);
    throw new StoreUnavailable(`upstream S3 refused the request (HTTP ${res.status}${code ? ` ${code}` : ''})`);
  }

  private succeeded(): void {
    this.failures = 0;
  }

  private failed(message: string): StoreUnavailable {
    this.failures++;
    if (this.isStarted && this.isAvailable && this.failures >= 3) {
      this.isAvailable = false;
      this.log(`NoteIt store: upstream S3 unavailable (${message}); probing every ${this.retryMs / 1000} s`);
      this.schedule(() => this.probe());
    }
    return new StoreUnavailable(message);
  }

  private async probe(): Promise<void> {
    try {
      const res = await this.send('GET', undefined, { query: [['list-type', '2'], ['max-keys', '1'], ['prefix', this.base]] });
      if (res instanceof Status) throw new StoreUnavailable(`HTTP ${res.status}`);
      this.isAvailable = true;
      this.log('NoteIt store: upstream S3 is available again');
    } catch {
      this.schedule(() => this.probe());
    }
  }

  private static etag(res: Response): string {
    return unquoteETag(res.headers.get('etag') ?? '');
  }

  private static lastModified(res: Response): number {
    const t = Date.parse(res.headers.get('last-modified') ?? '');
    return Number.isNaN(t) ? Date.now() : t;
  }

  private static precondition(res: Status): boolean {
    return res.status === 412 || res.status === 409;
  }

  private static notImplemented(res: Response | Status): res is Status {
    return res instanceof Status && (res.status === 501 || res.code === 'NotImplemented');
  }

  private unexpected(what: string, res: Status): never {
    if (S3Store.notImplemented(res)) {
      this.log(`NoteIt store: upstream S3 no longer implements conditional requests (${what})`);
    }
    throw new StoreUnavailable(`${what}: unexpected HTTP ${res.status}`);
  }

  // MARK: ObjectStore

  async head(userId: string, key: string): Promise<{ etag: string; size: number; lastModified: number } | null> {
    const res = await this.send('HEAD', this.objectKey(userId, key));
    if (res instanceof Status) return res.status === 404 ? null : this.unexpected(`HEAD ${key}`, res);
    return { etag: S3Store.etag(res), size: Number(res.headers.get('content-length') ?? 0), lastModified: S3Store.lastModified(res) };
  }

  async get(userId: string, key: string): Promise<{ data: Uint8Array; etag: string; lastModified: number } | null> {
    const res = await this.send('GET', this.objectKey(userId, key));
    if (res instanceof Status) return res.status === 404 ? null : this.unexpected(`GET ${key}`, res);
    const data = new Uint8Array(await res.arrayBuffer());
    return { data, etag: S3Store.etag(res), lastModified: S3Store.lastModified(res) };
  }

  async put(userId: string, key: string, data: Uint8Array, cond: { ifMatch?: string; ifNoneMatch?: boolean }): Promise<PutResult> {
    const fullKey = this.objectKey(userId, key);
    const headers: Record<string, string> = {};
    if (cond.ifNoneMatch) headers['If-None-Match'] = '*';
    if (cond.ifMatch !== undefined) headers['If-Match'] = `"${cond.ifMatch}"`;
    const res = await this.send('PUT', fullKey, { body: data, headers });
    if (res instanceof Status) return S3Store.precondition(res) ? 'preconditionFailed' : this.unexpected(`PUT ${key}`, res);
    const etag = S3Store.etag(res) || (await this.head(userId, key))?.etag;
    if (!etag) throw new StoreUnavailable(`PUT ${key}: the upstream returned no ETag`);
    return { etag };
  }

  async delete(userId: string, key: string, cond: { ifMatch?: string }): Promise<DeleteResult> {
    const fullKey = this.objectKey(userId, key);
    // S3 answers 204 for a missing key; callers need notFound, as from the disk driver.
    if (cond.ifMatch === undefined && !(await this.head(userId, key))) return 'notFound';
    const headers: Record<string, string> = cond.ifMatch !== undefined ? { 'If-Match': `"${cond.ifMatch}"` } : {};
    const res = await this.send('DELETE', fullKey, { headers });
    if (res instanceof Status) {
      if (res.status === 404) return 'notFound';
      return S3Store.precondition(res) ? 'preconditionFailed' : this.unexpected(`DELETE ${key}`, res);
    }
    return 'ok';
  }

  async list(userId: string, prefix: string): Promise<StoredObject[]> {
    if (prefix !== '' && !isListablePrefix(prefix)) throw new InvalidKeyError(`invalid prefix ${JSON.stringify(prefix)}`);
    const root = this.userBase(userId);
    const out: StoredObject[] = [];
    let token: string | undefined;
    do {
      const query: [string, string][] = [['list-type', '2'], ['prefix', root + prefix]];
      if (token) query.push(['continuation-token', token]);
      const res = await this.send('GET', undefined, { query });
      if (res instanceof Status) this.unexpected('LIST', res);
      const page = parseListV2(await res.text());
      for (const o of page.objects) {
        if (!o.key.startsWith(root)) continue;
        const key = o.key.slice(root.length);
        if (isValidKey(key)) out.push({ key, etag: o.etag, size: o.size, lastModified: o.lastModified ?? Date.now() });
      }
      if (page.isTruncated && !page.nextContinuationToken) throw new StoreUnavailable('truncated listing without a continuation token');
      token = page.isTruncated ? page.nextContinuationToken : undefined;
    } while (token);
    return out.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  }

  async usage(userId: string): Promise<{ bytes: number; objects: number }> {
    const all = await this.list(userId, '');
    return { bytes: all.reduce((n, o) => n + o.size, 0), objects: all.length };
  }

  async deleteNamespace(userId: string): Promise<void> {
    const keys = (await this.list(userId, '')).map((o) => o.key);
    for (let i = 0; i < keys.length; i += 8) {
      await Promise.all(keys.slice(i, i + 8).map((key) => this.send('DELETE', this.objectKey(userId, key))));
    }
  }

  // MARK: canary

  /**
   * The extended canary (spec §6.2, §6.4) on `<prefix>/server-canary/<UUID>`: If-None-Match and If-Match are
   * enforced on PUT, an overwrite gets a new ETag and the old one stops matching, and If-Match is enforced on
   * DELETE. Throws UpstreamCapabilityError naming the failed check, or StoreUnavailable when unreachable.
   */
  private async canary(): Promise<void> {
    const key = `${this.base}server-canary/${randomUUID().toUpperCase()}`;
    const body = (s: string) => new TextEncoder().encode(s);
    const bogus = { 'If-Match': '"00000000000000000000000000000000"' };
    const check = (ok: boolean, what: string) => {
      if (!ok) throw new UpstreamCapabilityError(`upstream S3 failed the startup check: ${what}`);
    };
    const refused = (res: Response | Status) => {
      if (S3Store.notImplemented(res)) throw new UpstreamCapabilityError('upstream S3 failed the startup check: it does not implement conditional requests (501 NotImplemented)');
      return res instanceof Status && S3Store.precondition(res);
    };
    let created = false;
    try {
      const first = await this.send('PUT', key, { body: body('canary-1'), headers: { 'If-None-Match': '*' } });
      check(!refused(first) && first instanceof Response, 'a conditional create (If-None-Match: *) was refused');
      created = true;
      const etag1 = S3Store.etag(first as Response);
      check(etag1 !== '', 'no ETag on PUT');
      check(refused(await this.send('PUT', key, { body: body('canary-2'), headers: { 'If-None-Match': '*' } })), 'it ignores If-None-Match on PUT');
      check(refused(await this.send('PUT', key, { body: body('canary-2'), headers: bogus })), 'it ignores If-Match on PUT');
      const second = await this.send('PUT', key, { body: body('canary-3'), headers: { 'If-Match': `"${etag1}"` } });
      check(!refused(second) && second instanceof Response, 'it rejects a correct If-Match on PUT');
      const etag2 = S3Store.etag(second as Response);
      check(etag2 !== '' && etag2 !== etag1, 'it reissued an ETag for different bytes');
      check(refused(await this.send('PUT', key, { body: body('canary-4'), headers: { 'If-Match': `"${etag1}"` } })), 'it still accepts the old ETag after an overwrite');
      check(refused(await this.send('DELETE', key, { headers: bogus })), 'it ignores If-Match on DELETE');
      const deleted = await this.send('DELETE', key, { headers: { 'If-Match': `"${etag2}"` } });
      check(!refused(deleted) && deleted instanceof Response, 'it rejects a correct If-Match on DELETE');
      created = false;
    } finally {
      if (created) await this.send('DELETE', key).catch(() => undefined);
    }
  }
}
