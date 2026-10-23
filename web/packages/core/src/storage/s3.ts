import { type Bytes, copyBytes, sha256Hex, utf8 } from '../bytes.js';
import { StorageError } from '../errors.js';
import { CANARY_MISMATCH_ETAG, CANARY_PREFIX } from '../layout.js';
import { newUuid } from '../uuid.js';
import { type PutOptions, type RemoteObject, type StorageBackend, unquoteETag } from './backend.js';
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

  async atomicConditionalWrites(): Promise<boolean> {
    await this.verifyConditionals();
    return this.conditionalWritesSupported;
  }

  async atomicConditionalDelete(): Promise<boolean> {
    await this.verifyConditionals();
    return this.conditionalDeletesSupported;
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

  /** The canary (S3Backend.swift runConditionalCanary): checks If-None-Match, a bogus If-Match, and conditional deletes. */
  verifyConditionals(): Promise<void> {
    this.canary ??= this.runCanary().catch((e) => {
      this.canary = undefined;
      throw e;
    });
    return this.canary;
  }

  private async runCanary(): Promise<void> {
    const key = CANARY_PREFIX + newUuid();
    const bogus = { 'If-Match': `"${CANARY_MISMATCH_ETAG}"` };
    const accepts = async (f: () => Promise<unknown>): Promise<boolean> => {
      try {
        await f();
        return true;
      } catch (e) {
        if (e instanceof StorageError && e.kind === 'preconditionFailed') return false;
        if (e instanceof ConditionalNotSupported) return true;
        throw e;
      }
    };
    try {
      try {
        await this.upload(key, utf8('canary'), { 'If-None-Match': '*' });
        const a = await accepts(() => this.upload(key, utf8('again'), { 'If-None-Match': '*' }));
        const b = await accepts(() => this.upload(key, utf8('again'), bogus));
        if (a || b) this.conditionalWritesSupported = false;
      } catch (e) {
        if (!(e instanceof ConditionalNotSupported)) throw e;
        this.conditionalWritesSupported = false;
        await this.upload(key, utf8('canary'), {});
      }
      if (await accepts(() => this.send('DELETE', key, { headers: bogus, conditional: true }))) this.conditionalDeletesSupported = false;
    } finally {
      await this.send('DELETE', key).catch(() => undefined);
    }
  }
}
