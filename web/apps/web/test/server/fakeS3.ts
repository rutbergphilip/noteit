import { createHash } from 'node:crypto';

/** Ways an upstream can fall short of what the server needs (spec §6.2 startup canary). */
export interface FakeS3Faults {
  ignoreIfNoneMatch?: boolean;
  ignoreIfMatch?: boolean;
  /** Answers 501 NotImplemented to any conditional request. */
  notImplemented?: boolean;
  /** Every object gets the same ETag. */
  reuseETag?: boolean;
  /** If-Match also matches any ETag the key had before. */
  acceptOldETag?: boolean;
  ignoreDeleteIfMatch?: boolean;
  /** Answers 412 to every conditional DELETE. */
  rejectDeleteIfMatch?: boolean;
}

/**
 * An in-memory S3 bucket behind a fetch function: path-style ListObjectsV2 (with paging), GET, HEAD, PUT and
 * DELETE with If-Match / If-None-Match, MD5 ETags. Requires a SigV4 Authorization header but doesn't verify it.
 */
export class FakeS3 {
  readonly objects = new Map<string, { data: Uint8Array; etag: string; history: string[]; lastModified: Date }>();
  readonly requests: { method: string; key: string | undefined; headers: Record<string, string> }[] = [];
  down = false;
  /** Applies the next PUT, then fails as if the response was lost. */
  dropNextPutResponse = false;
  pageSize = 1000;

  constructor(
    readonly bucket = 'upstream',
    public faults: FakeS3Faults = {},
  ) {}

  readonly fetch = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input));
    const method = (init.method ?? 'GET').toUpperCase();
    const headers = Object.fromEntries(Object.entries((init.headers ?? {}) as Record<string, string>).map(([k, v]) => [k.toLowerCase(), v]));
    const [, bucket, ...rest] = url.pathname.split('/');
    const key = rest.length ? rest.map(decodeURIComponent).join('/') : undefined;
    this.requests.push({ method, key, headers });
    if (this.down) throw new TypeError('fetch failed');
    if (!headers.authorization?.startsWith('AWS4-HMAC-SHA256 ')) return this.error(403, 'AccessDenied');
    if (bucket !== this.bucket) return this.error(404, 'NoSuchBucket');
    const ifMatch = headers['if-match']?.replace(/"/g, '');
    const ifNoneMatch = headers['if-none-match'];
    if (this.faults.notImplemented && (ifMatch !== undefined || ifNoneMatch !== undefined)) return this.error(501, 'NotImplemented');
    if (!key) return method === 'GET' ? this.list(url.searchParams) : this.error(405, 'MethodNotAllowed');
    const current = this.objects.get(key);
    const matches = (tag: string) => current !== undefined && (current.etag === tag || (this.faults.acceptOldETag === true && current.history.includes(tag)));

    switch (method) {
      case 'GET':
      case 'HEAD':
        if (!current) return this.error(404, 'NoSuchKey', method === 'HEAD');
        return new Response(method === 'HEAD' ? null : Buffer.from(current.data), {
          headers: { etag: `"${current.etag}"`, 'content-length': String(current.data.length), 'last-modified': current.lastModified.toUTCString() },
        });
      case 'PUT': {
        if (ifNoneMatch === '*' && current && !this.faults.ignoreIfNoneMatch) return this.error(412, 'PreconditionFailed');
        if (ifMatch !== undefined && !this.faults.ignoreIfMatch && !matches(ifMatch)) return this.error(current ? 412 : 404, current ? 'PreconditionFailed' : 'NoSuchKey');
        const data = new Uint8Array(await new Response(init.body as BodyInit).arrayBuffer());
        const etag = this.faults.reuseETag ? 'd41d8cd98f00b204e9800998ecf8427e' : createHash('md5').update(data).digest('hex');
        this.objects.set(key, { data, etag, history: current ? [...current.history, current.etag] : [], lastModified: new Date() });
        if (this.dropNextPutResponse) {
          this.dropNextPutResponse = false;
          throw new TypeError('connection reset');
        }
        return new Response(null, { headers: { etag: `"${etag}"` } });
      }
      case 'DELETE':
        if (ifMatch !== undefined) {
          if (this.faults.rejectDeleteIfMatch) return this.error(412, 'PreconditionFailed');
          if (!current) return this.error(404, 'NoSuchKey');
          if (!this.faults.ignoreDeleteIfMatch && !matches(ifMatch)) return this.error(412, 'PreconditionFailed');
        }
        this.objects.delete(key);
        return new Response(null, { status: 204 });
      default:
        return this.error(405, 'MethodNotAllowed');
    }
  }) as typeof fetch;

  private list(params: URLSearchParams): Response {
    const prefix = params.get('prefix') ?? '';
    const after = params.get('continuation-token') ?? '';
    const max = Math.min(Number(params.get('max-keys') ?? this.pageSize), this.pageSize);
    const all = [...this.objects.keys()].filter((k) => k.startsWith(prefix) && k > after).sort();
    const page = all.slice(0, max);
    const truncated = all.length > page.length;
    const contents = page
      .map((k) => {
        const o = this.objects.get(k)!;
        return `<Contents><Key>${k}</Key><ETag>"${o.etag}"</ETag><Size>${o.data.length}</Size><LastModified>${o.lastModified.toISOString()}</LastModified></Contents>`;
      })
      .join('');
    const xml = `<?xml version="1.0"?><ListBucketResult><IsTruncated>${truncated}</IsTruncated>${contents}${truncated ? `<NextContinuationToken>${page.at(-1)}</NextContinuationToken>` : ''}</ListBucketResult>`;
    return new Response(xml, { headers: { 'content-type': 'application/xml' } });
  }

  private error(status: number, code: string, head = false): Response {
    return new Response(head ? null : `<?xml version="1.0"?><Error><Code>${code}</Code><Message>${code}</Message></Error>`, { status });
  }
}
