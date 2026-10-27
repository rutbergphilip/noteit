import { type Bytes, copyBytes, sha256Hex, utf8 } from '../bytes.js';
import { StorageError } from '../errors.js';
import { CANARY_MISMATCH_ETAG, CANARY_PREFIX } from '../layout.js';
import { newUuid } from '../uuid.js';
import { assertListablePrefix, assertReadableKey, assertValidKey, type PutOptions, type RemoteObject, type StorageBackend, unquoteETag } from './backend.js';
import { parseError, parseListV2 } from './s3xml.js';
import { EMPTY_PAYLOAD_SHA256, signRequest, uriEncode } from './sigv4.js';

export interface S3Config {
  endpoint: string;
  bucket: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  pathStyle: boolean;
  prefix?: string;
}

class ConditionalNotSupported extends Error {}

/** Canaries older than this are a crashed client's (spec §6.4). */
export const STALE_CANARY_MS = 10 * 60_000;

/**
 * Port of the native S3Backend's request shapes (path-style URLs, SigV4 headers, quoted If-Match, If-None-Match: *).
 * Conditional requests are sent once; unconditional ones retry network errors after 0.5 s and 1.5 s.
 */
export class S3Backend implements StorageBackend {
  conditionalWritesSupported = true;
  conditionalDeletesSupported = true;
  private readonly keyPrefix: string;
  private canary: Promise<void> | undefined;

  constructor(
    private readonly cfg: S3Config,
    private readonly fetchImpl: typeof fetch = (i, init) => fetch(i, init),
    private readonly now: () => Date = () => new Date(),
    private readonly retryDelaysMs: number[] = [500, 1500],
  ) {
    const trimmed = (cfg.prefix ?? '').replace(/^\/+|\/+$/g, '');
    if (trimmed && !trimmed.split('/').every((s) => /^[A-Za-z0-9._-]{1,128}$/.test(s) && s !== '.' && s !== '..')) {
      throw new StorageError('invalidResponse', `invalid key prefix ${JSON.stringify(cfg.prefix)}`);
    }
    this.keyPrefix = trimmed ? `${trimmed}/` : '';
  }

  makeURL(key: string | undefined, query: [string, string][] = []): URL {
    const endpoint = new URL(this.cfg.endpoint);
    const basePath = endpoint.pathname.replace(/\/$/, '');
    const encodedKey = key !== undefined ? uriEncode(key, false) : '';
    let path: string;
    if (this.cfg.pathStyle) path = `${basePath}/${uriEncode(this.cfg.bucket)}/${encodedKey}`;
    else {
      endpoint.hostname = `${this.cfg.bucket}.${endpoint.hostname}`;
      path = `${basePath}/${encodedKey}`;
    }
    const url = new URL(endpoint.origin);
    url.pathname = path;
    url.search = query.map(([k, v]) => `${uriEncode(k)}=${uriEncode(v)}`).join('&');
    return url;
  }

  private async send(
    method: string,
    key: string | undefined,
    opts: { query?: [string, string][]; body?: Uint8Array; headers?: Record<string, string>; conditional?: boolean } = {},
  ): Promise<Response> {
    // The one choke point for object keys: nothing outside the layout grammar reaches a URL path.
    if (key !== undefined) {
      if (method === 'GET' || method === 'HEAD') assertReadableKey(key);
      else assertValidKey(key);
    }
    const url = this.makeURL(key !== undefined ? this.keyPrefix + key : undefined, opts.query);
    const payloadHash = opts.body ? await sha256Hex(opts.body) : EMPTY_PAYLOAD_SHA256;
    const label = key ?? '/';
    for (let attempt = 0; ; attempt++) {
      const signed = await signRequest({
        method,
        url,
        headers: opts.headers ?? {},
        payloadHash,
        accessKeyId: this.cfg.accessKeyId,
        secretAccessKey: this.cfg.secretAccessKey,
        region: this.cfg.region,
        date: this.now(),
      });
      let failure: StorageError;
      try {
        const init: RequestInit = { method, headers: { ...opts.headers, ...signed }, cache: 'no-store', credentials: 'omit', redirect: 'error' };
        if (opts.body) init.body = copyBytes(opts.body);
        const res = await this.fetchImpl(url, init);
        if (res.ok) return res;
        const text = method === 'HEAD' ? '' : await res.text();
        const err = parseError(text);
        if (opts.conditional && (res.status === 501 || (res.status === 400 && err?.code === 'NotImplemented'))) throw new ConditionalNotSupported();
        const detail = err ? `${err.code}: ${err.message}` : `HTTP ${res.status}`;
        if (err?.code === 'RequestTimeTooSkewed') throw new StorageError('clockSkew', detail);
        if (err?.code === 'InvalidAccessKeyId' || err?.code === 'SignatureDoesNotMatch') throw new StorageError('unauthorized', detail);
        if (err?.code === 'QuotaExceeded') throw new StorageError('quotaExceeded', detail);
        if (res.status === 404) throw new StorageError('notFound', label);
        if (res.status === 412 || (res.status === 409 && opts.conditional)) throw new StorageError('preconditionFailed', label);
        if (res.status === 401 || res.status === 403) throw new StorageError('unauthorized', detail);
        failure = new StorageError(res.status >= 500 ? 'network' : 'invalidResponse', detail);
      } catch (e) {
        if (e instanceof StorageError || e instanceof ConditionalNotSupported) {
          if (!(e instanceof StorageError && e.kind === 'network')) throw e;
          failure = e;
        } else failure = new StorageError('network', e instanceof Error ? e.message : String(e));
      }
      const delay = this.retryDelaysMs[attempt];
      if (opts.conditional || delay === undefined) throw failure;
      await new Promise((r) => setTimeout(r, delay));
    }
  }

  private async etagOf(res: Response, key: string): Promise<string> {
    const tag = unquoteETag(res.headers.get('ETag') ?? '');
    if (tag) return tag;
    const head = await this.send('HEAD', key);
    const again = unquoteETag(head.headers.get('ETag') ?? '');
    if (!again) throw new StorageError('invalidResponse', 'ETag not exposed');
    return again;
  }

  async list(prefix: string): Promise<RemoteObject[]> {
    assertListablePrefix(prefix);
    const out: RemoteObject[] = [];
    let token: string | undefined;
    do {
      const query: [string, string][] = [['list-type', '2'], ['prefix', this.keyPrefix + prefix]];
      if (token) query.push(['continuation-token', token]);
      const page = parseListV2(await (await this.send('GET', undefined, { query })).text());
      for (const o of page.objects) {
        if (o.key.startsWith(this.keyPrefix)) out.push({ ...o, key: o.key.slice(this.keyPrefix.length) });
      }
      if (page.isTruncated && !page.nextContinuationToken) throw new StorageError('invalidResponse', 'truncated list without continuation token');
      token = page.isTruncated ? page.nextContinuationToken : undefined;
    } while (token);
    return out;
  }

  async get(key: string): Promise<{ data: Bytes; etag: string }> {
    const res = await this.send('GET', key);
    const data = new Uint8Array(await res.arrayBuffer());
    return { data, etag: await this.etagOf(res, key) };
  }

  private async upload(key: string, data: Uint8Array, headers: Record<string, string>): Promise<string> {
    const res = await this.send('PUT', key, { body: data, headers, conditional: Object.keys(headers).length > 0 });
    return this.etagOf(res, key);
  }

  async put(key: string, data: Uint8Array, opts: PutOptions = {}): Promise<string> {
    const conditional = opts.ifMatch !== undefined || opts.ifNoneMatch === true;
    if (!conditional) return this.upload(key, data, {});
    await this.verifyConditionals();
    if (this.conditionalWritesSupported) {
      const headers: Record<string, string> = {};
      if (opts.ifNoneMatch) headers['If-None-Match'] = '*';
      if (opts.ifMatch !== undefined) headers['If-Match'] = `"${opts.ifMatch}"`;
      try {
        return await this.upload(key, data, headers);
      } catch (e) {
        if (!(e instanceof ConditionalNotSupported)) throw e;
        this.conditionalWritesSupported = false;
      }
    }
    await this.checkPreconditions(key, opts);
    const tag = await this.upload(key, data, {});
    const head = await this.headETag(key);
    if (head !== tag) throw new StorageError('network', 'write could not be verified');
    return tag;
  }

  async delete(key: string, opts: { ifMatch?: string } = {}): Promise<void> {
    if (opts.ifMatch === undefined) {
      await this.send('DELETE', key);
      return;
    }
    await this.verifyConditionals();
    if (!this.conditionalDeletesSupported) throw new StorageError('conditionalDeleteUnsupported', key);
    try {
      await this.send('DELETE', key, { headers: { 'If-Match': `"${opts.ifMatch}"` }, conditional: true });
    } catch (e) {
      if (!(e instanceof ConditionalNotSupported)) throw e;
      this.conditionalDeletesSupported = false;
      throw new StorageError('conditionalDeleteUnsupported', key);
    }
  }

  async probe(): Promise<void> {
    parseListV2(await (await this.send('GET', undefined, { query: [['list-type', '2'], ['max-keys', '1'], ['prefix', this.keyPrefix]] })).text());
  }

  /**
   * For the direct-mode connect wizard's CORS check (spec §6.4): a PUT with `If-None-Match: *`, returning the ETag
   * header exactly as the browser exposes it ('' when CORS hides it), with no HEAD fallback.
   */
  async putExposingETag(key: string, data: Uint8Array): Promise<string> {
    const res = await this.send('PUT', key, { body: data, headers: { 'If-None-Match': '*' }, conditional: true });
    return unquoteETag(res.headers.get('ETag') ?? '');
  }

  /** Whether this session's canary finished (false after a network or credential failure, until it runs again). */
  get conditionalsChecked(): boolean {
    return this.checked;
  }

  /** What this session's canary found; both false until it ran (call `verifyConditionals()` first). */
  get capabilities(): { writes: boolean; deletes: boolean } {
    return { writes: this.writePassed && this.conditionalWritesSupported, deletes: this.deletePassed && this.conditionalDeletesSupported };
  }

  /** True once this session's canary passed its write steps (S3Backend.swift writePassed). */
  async atomicConditionalWrites(): Promise<boolean> {
    await this.verifyConditionals();
    return this.writePassed && this.conditionalWritesSupported;
  }

  /** True once this session's canary passed its delete steps. */
  async atomicConditionalDelete(): Promise<boolean> {
    await this.verifyConditionals();
    return this.deletePassed && this.conditionalDeletesSupported;
  }

  private async headETag(key: string): Promise<string | undefined> {
    try {
      return unquoteETag((await this.send('HEAD', key)).headers.get('ETag') ?? '');
    } catch (e) {
      if (e instanceof StorageError && e.kind === 'notFound') return undefined;
      throw e;
    }
  }

  private async checkPreconditions(key: string, opts: PutOptions): Promise<void> {
    const current = await this.headETag(key);
    if (opts.ifNoneMatch && current !== undefined) throw new StorageError('preconditionFailed', key);
    if (opts.ifMatch !== undefined && current !== opts.ifMatch) throw new StorageError('preconditionFailed', key);
  }

  /**
   * The canary (S3Backend.swift runConditionalCanary, spec §6.4), once per session. Write steps: create with
   * If-None-Match, then it and a bogus If-Match must get 412; an If-Match overwrite with the first ETag must succeed
   * with a different ETag, after which that ETag must get 412. Delete steps: a bogus If-Match DELETE must get 412 and
   * leave the object; a DELETE with the current ETag must remove it. A canary that can't finish (network,
   * credentials) marks nothing and runs again next time. Never throws.
   */
  verifyConditionals(): Promise<void> {
    this.canary ??= this.runCanary();
    return this.canary;
  }

  private writePassed = false;
  private deletePassed = false;
  private checked = false;

  private async accepts(f: () => Promise<unknown>): Promise<boolean> {
    try {
      await f();
      return true;
    } catch (e) {
      if (e instanceof StorageError && e.kind === 'preconditionFailed') return false;
      if (e instanceof ConditionalNotSupported) return true;
      throw e;
    }
  }

  private async runCanary(): Promise<void> {
    const key = CANARY_PREFIX + newUuid();
    const bogus = { 'If-Match': `"${CANARY_MISMATCH_ETAG}"` };
    try {
      let writesHold = true;
      try {
        const first = await this.upload(key, utf8('canary'), { 'If-None-Match': '*' });
        const ignoresNoneMatch = await this.accepts(() => this.upload(key, utf8('again'), { 'If-None-Match': '*' }));
        const ignoresMatch = await this.accepts(() => this.upload(key, utf8('again'), bogus));
        writesHold = !ignoresNoneMatch && !ignoresMatch && (await this.overwriteRetiresETag(key, first));
      } catch (e) {
        if (!(e instanceof ConditionalNotSupported)) throw e;
        writesHold = false;
        await this.upload(key, utf8('canary'), {});
      }
      const deletesHold = await this.conditionalDeleteHolds(key, bogus);
      if (!writesHold) this.conditionalWritesSupported = false;
      if (!deletesHold) this.conditionalDeletesSupported = false;
      this.writePassed = writesHold;
      this.deletePassed = deletesHold;
      this.checked = true;
      // Passing delete steps removed the canary already.
      if (!deletesHold) await this.send('DELETE', key).catch(() => undefined);
      await this.sweepStaleCanaries();
    } catch {
      // Unreachable or unauthorized: real requests surface the error; check again next time.
      await this.send('DELETE', key).catch(() => undefined);
      this.canary = undefined;
    }
  }

  /** An If-Match overwrite with `first` succeeds with a new ETag, and `first` stops matching afterwards. */
  private async overwriteRetiresETag(key: string, first: string): Promise<boolean> {
    let second: string;
    try {
      second = await this.upload(key, utf8('canary-2'), { 'If-Match': `"${first}"` });
    } catch (e) {
      if ((e instanceof StorageError && e.kind === 'preconditionFailed') || e instanceof ConditionalNotSupported) return false;
      throw e;
    }
    if (second === first) return false;
    return !(await this.accepts(() => this.upload(key, utf8('canary-3'), { 'If-Match': `"${first}"` })));
  }

  /** The canary's delete steps; on success the canary is gone. */
  private async conditionalDeleteHolds(key: string, bogus: Record<string, string>): Promise<boolean> {
    if (await this.accepts(() => this.send('DELETE', key, { headers: bogus, conditional: true }))) return false;
    const current = await this.headETag(key);
    if (current === undefined) return false;
    try {
      await this.send('DELETE', key, { headers: { 'If-Match': `"${current}"` }, conditional: true });
    } catch (e) {
      if ((e instanceof StorageError && e.kind === 'preconditionFailed') || e instanceof ConditionalNotSupported) return false;
      throw e;
    }
    return (await this.headETag(key)) === undefined;
  }

  /**
   * Canaries left by a client that crashed mid-check: without a server nobody else removes them (spec §6.4). Only
   * ones older than 10 minutes, so another client's running check is left alone. Best effort.
   */
  private async sweepStaleCanaries(): Promise<void> {
    try {
      const cutoff = this.now().getTime() - STALE_CANARY_MS;
      for (const o of await this.list(CANARY_PREFIX)) {
        if (o.lastModified !== undefined && o.lastModified < cutoff) await this.send('DELETE', o.key).catch(() => undefined);
      }
    } catch {
      // Listing failed: try again on the next session's canary.
    }
  }
}
