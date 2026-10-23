import { type Bytes, copyBytes } from '../bytes.js';
import { StorageError } from '../errors.js';
import { assertListablePrefix, assertReadableKey, assertValidKey, type PutOptions, type RemoteObject, type StorageBackend, unquoteETag } from './backend.js';

/** Talks to the NoteIt server's browser REST front door, `/api/storage` (spec §6.3a). */
export class HttpProxyBackend implements StorageBackend {
  private readonly baseUrl: string;
  private readonly fetchImpl: typeof fetch;
  private readonly headers: Record<string, string>;

  constructor(opts: { baseUrl: string; fetch?: typeof fetch; headers?: Record<string, string> }) {
    this.baseUrl = opts.baseUrl.replace(/\/$/, '');
    this.fetchImpl = opts.fetch ?? ((input, init) => fetch(input, init));
    this.headers = { 'X-NoteIt': '1', ...opts.headers };
  }

  private objectUrl(key: string): string {
    return `${this.baseUrl}/api/storage/object/${key.split('/').map(encodeURIComponent).join('/')}`;
  }

  private async send(url: string, init: RequestInit): Promise<Response> {
    let res: Response;
    try {
      res = await this.fetchImpl(url, { ...init, cache: 'no-store', credentials: 'same-origin', headers: { ...this.headers, ...(init.headers as Record<string, string>) } });
    } catch (e) {
      throw new StorageError('network', e instanceof Error ? e.message : String(e));
    }
    if (res.ok) return res;
    let code = '';
    try {
      code = ((await res.json()) as { error?: string }).error ?? '';
    } catch {
      // not JSON
    }
    switch (res.status) {
      case 404:
        throw new StorageError('notFound', url);
      case 412:
        throw new StorageError('preconditionFailed', url);
      case 401:
      case 403:
        throw new StorageError('unauthorized', code || `HTTP ${res.status}`);
      case 507:
        throw new StorageError('quotaExceeded', code);
      case 429:
      case 502:
      case 503:
        throw new StorageError('network', code || `HTTP ${res.status}`);
      default:
        throw new StorageError(res.status >= 500 ? 'network' : 'invalidResponse', code || `HTTP ${res.status}`);
    }
  }

  async list(prefix: string): Promise<RemoteObject[]> {
    assertListablePrefix(prefix);
    const out: RemoteObject[] = [];
    let token: string | undefined;
    do {
      const q = new URLSearchParams({ prefix });
      if (token) q.set('continuationToken', token);
      const res = await this.send(`${this.baseUrl}/api/storage/list?${q}`, { method: 'GET' });
      const page = (await res.json()) as { objects: RemoteObject[]; nextContinuationToken?: string };
      out.push(...page.objects);
      token = page.nextContinuationToken;
    } while (token);
    return out;
  }

  async get(key: string): Promise<{ data: Bytes; etag: string }> {
    assertReadableKey(key);
    const res = await this.send(this.objectUrl(key), { method: 'GET' });
    const etag = unquoteETag(res.headers.get('ETag') ?? '');
    if (!etag) throw new StorageError('invalidResponse', 'ETag not exposed');
    return { data: new Uint8Array(await res.arrayBuffer()), etag };
  }

  async put(key: string, data: Uint8Array, opts: PutOptions = {}): Promise<string> {
    assertValidKey(key);
    const headers: Record<string, string> = { 'Content-Type': 'application/octet-stream' };
    if (opts.ifMatch !== undefined) headers['If-Match'] = `"${opts.ifMatch}"`;
    if (opts.ifNoneMatch) headers['If-None-Match'] = '*';
    const res = await this.send(this.objectUrl(key), { method: 'PUT', body: copyBytes(data), headers });
    const body = (await res.json()) as { etag?: string };
    if (!body.etag) throw new StorageError('invalidResponse', 'no etag');
    return body.etag;
  }

  async delete(key: string, opts: { ifMatch?: string } = {}): Promise<void> {
    assertValidKey(key);
    const headers: Record<string, string> = {};
    if (opts.ifMatch !== undefined) headers['If-Match'] = `"${opts.ifMatch}"`;
    await this.send(this.objectUrl(key), { method: 'DELETE', headers });
  }

  async probe(): Promise<void> {
    await this.send(`${this.baseUrl}/api/storage/list?prefix=${encodeURIComponent('noteit/')}`, { method: 'GET' });
  }

  async atomicConditionalWrites(): Promise<boolean> {
    return true;
  }

  async atomicConditionalDelete(): Promise<boolean> {
    return true;
  }
}
