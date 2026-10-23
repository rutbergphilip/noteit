import { createHash, timingSafeEqual } from 'node:crypto';
import { canonicalRequest, isValidKey, parseAuthorization, signature, UNSIGNED_PAYLOAD, xmlEscape } from '@noteit/core';
import { defineEventHandler, getHeader, type H3Event, setResponseHeader, setResponseStatus } from 'h3';
import { BodyTooLarge, readBodyLimited } from './body';
import { ApiFailure, type User } from './accounts';
import type { ServerContext } from './context';
import type { StoredObject } from './diskStore';
import { InvalidKeyError } from './diskStore';
import { normalizeIfMatch } from './http';

export const BUCKET = 'noteit';
const MAX_SKEW_MS = 15 * 60_000;

class S3Failure extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

function sendError(event: H3Event, f: S3Failure, resource: string): string {
  setResponseStatus(event, f.status);
  setResponseHeader(event, 'Content-Type', 'application/xml');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>${f.code}</Code><Message>${xmlEscape(f.message)}</Message><Resource>${xmlEscape(resource)}</Resource></Error>`;
}

const sha256hex = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');

/** SigV4 header auth (spec §6.3b). The access key picks exactly one user; nothing in the request can name another. */
/** Verifies the signature over the headers only; the declared payload hash is checked later, while the body streams. */
async function authenticate(event: H3Event, ctx: ServerContext): Promise<{ user: User; payloadHash: string }> {
  const auth = parseAuthorization(getHeader(event, 'authorization') ?? '');
  if (!auth || auth.service !== 's3') throw new S3Failure(403, 'AccessDenied', 'Only AWS4-HMAC-SHA256 header authentication is supported');
  const found = ctx.accounts.byAccessKey(auth.accessKeyId);
  if (!found || found.user.status === 'deleting') throw new S3Failure(403, 'InvalidAccessKeyId', 'The access key does not exist');
  const amzDate = getHeader(event, 'x-amz-date') ?? '';
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(amzDate);
  if (!m) throw new S3Failure(403, 'AccessDenied', 'Missing x-amz-date');
  const when = Date.UTC(+m[1]!, +m[2]! - 1, +m[3]!, +m[4]!, +m[5]!, +m[6]!);
  if (Math.abs(Date.now() - when) > MAX_SKEW_MS) throw new S3Failure(403, 'RequestTimeTooSkewed', 'The difference between the request time and the server time is too large');
  if (amzDate.slice(0, 8) !== auth.dateStamp) throw new S3Failure(403, 'SignatureDoesNotMatch', 'Credential date mismatch');
  for (const required of ['host', 'x-amz-date', 'x-amz-content-sha256']) {
    if (!auth.signedHeaders.includes(required)) throw new S3Failure(403, 'AccessDenied', `${required} must be signed`);
  }
  const payloadHash = getHeader(event, 'x-amz-content-sha256') ?? '';
  if (payloadHash.startsWith('STREAMING-')) throw new S3Failure(501, 'NotImplemented', 'aws-chunked uploads are not supported');
  if (payloadHash !== UNSIGNED_PAYLOAD && !/^[0-9a-f]{64}$/.test(payloadHash)) throw new S3Failure(400, 'InvalidArgument', 'Bad x-amz-content-sha256');
  const headers: Record<string, string> = {};
  for (const name of auth.signedHeaders) {
    const raw = event.node.req.headers[name];
    headers[name] = Array.isArray(raw) ? raw.join(',') : (raw ?? '');
  }
  const url = event.node.req.url ?? '/';
  const q = url.indexOf('?');
  const canonical = canonicalRequest({
    method: event.method.toUpperCase(),
    path: q < 0 ? url : url.slice(0, q),
    query: q < 0 ? '' : url.slice(q + 1),
    headers,
    signedHeaders: auth.signedHeaders,
    payloadHash,
  });
  const expected = await signature({ canonical, amzDate, dateStamp: auth.dateStamp, region: auth.region, secretAccessKey: found.key.secretAccessKey });
  if (!timingSafeEqual(Buffer.from(expected), Buffer.from(auth.signature.padEnd(expected.length, '0').slice(0, expected.length))) || expected !== auth.signature) {
    throw new S3Failure(403, 'SignatureDoesNotMatch', 'The request signature does not match');
  }
  if (found.user.status !== 'active') throw new S3Failure(403, 'AccessDenied', 'This account is disabled');
  const lastUsed = found.key.lastUsedAt ? Date.parse(found.key.lastUsedAt) : 0;
  if (Date.now() - lastUsed > 3_600_000) {
    void ctx.accounts.mutate((f) => {
      const key = f.users.find((u) => u.id === found.user.id)?.s3Keys.find((k) => k.accessKeyId === found.key.accessKeyId);
      if (key) key.lastUsedAt = new Date().toISOString();
    });
  }
  return { user: found.user, payloadHash };
}

export interface ListV2Query {
  prefix: string;
  delimiter?: string;
  maxKeys: number;
  continuationToken?: string;
  startAfter?: string;
  encodingType?: 'url';
}

export interface ListV2Result {
  contents: StoredObject[];
  commonPrefixes: string[];
  keyCount: number;
  isTruncated: boolean;
  nextContinuationToken?: string;
}

/** ListObjectsV2 over a sorted listing (spec §6.3b): grouping, paging and tokens. */
export function listObjectsV2(all: StoredObject[], q: ListV2Query): ListV2Result {
  const contents: StoredObject[] = [];
  const commonPrefixes: string[] = [];
  let after: string | undefined;
  if (q.continuationToken) after = Buffer.from(q.continuationToken, 'base64url').toString('utf8');
  else if (q.startAfter) after = q.startAfter;
  if (q.maxKeys === 0) return { contents, commonPrefixes, keyCount: 0, isTruncated: false };
  let last: string | undefined;
  let truncated = false;
  for (const o of all) {
    if (!o.key.startsWith(q.prefix)) continue;
    if (after !== undefined && (o.key <= after || (q.delimiter && after.endsWith(q.delimiter) && o.key.startsWith(after)))) continue;
    const rest = o.key.slice(q.prefix.length);
    const cut = q.delimiter ? rest.indexOf(q.delimiter) : -1;
    const entry = cut >= 0 ? q.prefix + rest.slice(0, cut + q.delimiter!.length) : undefined;
    if (entry !== undefined && entry === commonPrefixes.at(-1)) continue;
    if (contents.length + commonPrefixes.length >= q.maxKeys) {
      truncated = true;
      break;
    }
    if (entry !== undefined) {
      commonPrefixes.push(entry);
      last = entry;
    } else {
      contents.push(o);
      last = o.key;
    }
  }
  return {
    contents,
    commonPrefixes,
    keyCount: contents.length + commonPrefixes.length,
    isTruncated: truncated,
    ...(truncated && last ? { nextContinuationToken: Buffer.from(last).toString('base64url') } : {}),
  };
}

export function renderListV2(q: ListV2Query, r: ListV2Result): string {
  const enc = (s: string) => xmlEscape(q.encodingType === 'url' ? encodeURIComponent(s).replace(/%2F/g, '/') : s);
  const parts = [`<?xml version="1.0" encoding="UTF-8"?>`, `<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">`, `<Name>${BUCKET}</Name>`, `<Prefix>${enc(q.prefix)}</Prefix>`];
  if (q.delimiter) parts.push(`<Delimiter>${enc(q.delimiter)}</Delimiter>`);
  parts.push(`<MaxKeys>${q.maxKeys}</MaxKeys>`);
  if (q.encodingType) parts.push(`<EncodingType>url</EncodingType>`);
  if (q.startAfter && !q.continuationToken) parts.push(`<StartAfter>${enc(q.startAfter)}</StartAfter>`);
  if (q.continuationToken) parts.push(`<ContinuationToken>${xmlEscape(q.continuationToken)}</ContinuationToken>`);
  parts.push(`<KeyCount>${r.keyCount}</KeyCount>`, `<IsTruncated>${r.isTruncated}</IsTruncated>`);
  if (r.nextContinuationToken) parts.push(`<NextContinuationToken>${r.nextContinuationToken}</NextContinuationToken>`);
  for (const o of r.contents) {
    parts.push(
      `<Contents><Key>${enc(o.key)}</Key><LastModified>${new Date(o.lastModified).toISOString()}</LastModified><ETag>&quot;${o.etag}&quot;</ETag><Size>${o.size}</Size><StorageClass>STANDARD</StorageClass></Contents>`,
    );
  }
  for (const p of r.commonPrefixes) parts.push(`<CommonPrefixes><Prefix>${enc(p)}</Prefix></CommonPrefixes>`);
  parts.push('</ListBucketResult>');
  return parts.join('');
}

function checkDigests(event: H3Event, body: Uint8Array): void {
  const md5 = getHeader(event, 'content-md5');
  if (md5 !== undefined && createHash('md5').update(body).digest('base64') !== md5) throw new S3Failure(400, 'BadDigest', 'Content-MD5 mismatch');
  const sha256 = getHeader(event, 'x-amz-checksum-sha256');
  if (sha256 !== undefined && createHash('sha256').update(body).digest('base64') !== sha256) throw new S3Failure(400, 'BadDigest', 'Checksum mismatch');
  const sha1 = getHeader(event, 'x-amz-checksum-sha1');
  if (sha1 !== undefined && createHash('sha1').update(body).digest('base64') !== sha1) throw new S3Failure(400, 'BadDigest', 'Checksum mismatch');
  for (const h of ['x-amz-checksum-crc32', 'x-amz-checksum-crc32c']) {
    if (getHeader(event, h) !== undefined) throw new S3Failure(501, 'NotImplemented', `${h} is not supported; use Content-MD5`);
  }
}

/** Splits `/s3/<bucket>/<key>` with each key segment decoded once; a decoded segment may not contain `/`, `\` or NUL. */
function parsePath(rawUrl: string): { bucket: string; key: string | undefined } {
  const path = rawUrl.split('?')[0]!;
  const rest = path.replace(/^\/s3\/?/, '');
  const slash = rest.indexOf('/');
  const decode = (s: string) => {
    try {
      return decodeURIComponent(s);
    } catch {
      throw new S3Failure(400, 'InvalidURI', 'Bad encoding');
    }
  };
  if (slash < 0) return { bucket: decode(rest), key: undefined };
  const rawKey = rest.slice(slash + 1);
  if (rawKey === '') return { bucket: decode(rest.slice(0, slash)), key: undefined };
  const segments = rawKey.split('/').map(decode);
  if (segments.some((s) => /[/\\\0]/.test(s))) throw new S3Failure(400, 'InvalidURI', 'Bad key');
  return { bucket: decode(rest.slice(0, slash)), key: segments.join('/') };
}

/** The S3-compatible subset at /s3 for the native app's S3 backend and rclone. */
export function createS3Handler(ctx: ServerContext) {
  const { store, quotas, cfg } = ctx;
  return defineEventHandler(async (event) => {
    const url = event.node.req.url ?? '/';
    const method = event.method.toUpperCase();
    try {
      if (ctx.accounts.isEmpty) throw new S3Failure(503, 'ServiceUnavailable', 'This server needs its first admin');
      // Signature first, from the headers alone: nothing is buffered for an unauthenticated client.
      const { user, payloadHash } = await authenticate(event, ctx);
      const { bucket, key } = parsePath(url);
      if (bucket !== BUCKET) throw new S3Failure(404, 'NoSuchBucket', 'The only bucket is noteit');
      if (key !== undefined && !isValidKey(key)) throw new S3Failure(400, 'InvalidArgument', 'Key is outside the NoteIt layout. In NoteIt on your Mac, choose the NoteIt Server provider, or leave Folder inside bucket empty.');
      let body: Uint8Array = new Uint8Array();
      if (method === 'PUT') {
        try {
          body = await readBodyLimited(event, cfg.maxObjectBytes);
        } catch (e) {
          if (e instanceof BodyTooLarge) {
            setResponseHeader(event, 'Connection', 'close');
            throw new S3Failure(413, 'EntityTooLarge', 'Your proposed upload exceeds the maximum allowed object size');
          }
          throw e;
        }
        if (payloadHash !== UNSIGNED_PAYLOAD && sha256hex(body) !== payloadHash) throw new S3Failure(400, 'XAmzContentSHA256Mismatch', 'The payload hash does not match');
      }
      const params = new URLSearchParams(url.includes('?') ? url.slice(url.indexOf('?') + 1) : '');

      if (key === undefined) {
        if (method === 'HEAD') return '';
        if (method !== 'GET') throw new S3Failure(405, 'MethodNotAllowed', 'Unsupported bucket operation');
        if (params.get('list-type') !== '2') throw new S3Failure(501, 'NotImplemented', 'Use ListObjectsV2 (list-type=2)');
        const maxKeysRaw = params.get('max-keys');
        const maxKeys = maxKeysRaw === null ? 1000 : Number(maxKeysRaw);
        if (!Number.isInteger(maxKeys) || maxKeys < 0) throw new S3Failure(400, 'InvalidArgument', 'Bad max-keys');
        const q: ListV2Query = { prefix: params.get('prefix') ?? '', maxKeys: Math.min(maxKeys, 1000) };
        const delimiter = params.get('delimiter');
        if (delimiter) q.delimiter = delimiter;
        const token = params.get('continuation-token');
        if (token) q.continuationToken = token;
        const startAfter = params.get('start-after');
        if (startAfter) q.startAfter = startAfter;
        if (params.get('encoding-type') === 'url') q.encodingType = 'url';
        const all = await store.list(user.id, '');
        setResponseHeader(event, 'Content-Type', 'application/xml');
        return renderListV2(q, listObjectsV2(all, q));
      }

      switch (method) {
        case 'GET':
        case 'HEAD': {
          const head = await store.head(user.id, key);
          if (!head) throw new S3Failure(404, 'NoSuchKey', 'The specified key does not exist');
          setResponseHeader(event, 'ETag', `"${head.etag}"`);
          setResponseHeader(event, 'Last-Modified', new Date(head.lastModified).toUTCString());
          setResponseHeader(event, 'Content-Type', 'application/octet-stream');
          if (method === 'HEAD') {
            setResponseHeader(event, 'Content-Length', head.size);
            return '';
          }
          const obj = await store.get(user.id, key);
          if (!obj) throw new S3Failure(404, 'NoSuchKey', 'The specified key does not exist');
          setResponseHeader(event, 'ETag', `"${obj.etag}"`);
          return Buffer.from(obj.data);
        }
        case 'PUT': {
          if (getHeader(event, 'x-amz-copy-source')) throw new S3Failure(501, 'NotImplemented', 'CopyObject is not supported');
          checkDigests(event, body);
          const noneMatch = getHeader(event, 'if-none-match');
          if (noneMatch !== undefined && noneMatch.trim() !== '*') throw new S3Failure(400, 'InvalidArgument', 'If-None-Match must be *');
          let ifMatch: string | undefined;
          try {
            ifMatch = normalizeIfMatch(getHeader(event, 'if-match'));
          } catch {
            throw new S3Failure(400, 'InvalidArgument', 'Bad If-Match');
          }
          const result = await quotas.exclusive(user.id, async () => {
            const previous = await store.head(user.id, key);
            try {
              await quotas.admit(user, previous?.size, body.length);
            } catch (e) {
              if (e instanceof ApiFailure) throw new S3Failure(400, 'QuotaExceeded', 'This account is out of storage');
              throw e;
            }
            const put = await store.put(user.id, key, body, { ...(ifMatch !== undefined ? { ifMatch } : {}), ifNoneMatch: noneMatch !== undefined });
            if (put !== 'preconditionFailed') await quotas.applied(user.id, previous?.size, body.length);
            return put;
          });
          if (result === 'preconditionFailed') throw new S3Failure(412, 'PreconditionFailed', 'At least one of the pre-conditions you specified did not hold');
          setResponseHeader(event, 'ETag', `"${result.etag}"`);
          return '';
        }
        case 'DELETE': {
          let ifMatch: string | undefined;
          try {
            ifMatch = normalizeIfMatch(getHeader(event, 'if-match'));
          } catch {
            throw new S3Failure(400, 'InvalidArgument', 'Bad If-Match');
          }
          const result = await quotas.exclusive(user.id, async () => {
            const previous = await store.head(user.id, key);
            const deleted = await store.delete(user.id, key, ifMatch !== undefined ? { ifMatch } : {});
            if (deleted === 'ok') await quotas.applied(user.id, previous?.size, undefined);
            return deleted;
          });
          if (result === 'preconditionFailed') throw new S3Failure(412, 'PreconditionFailed', 'At least one of the pre-conditions you specified did not hold');
          // S3 answers 204 for a missing key unless a condition names it.
          if (result === 'notFound' && ifMatch !== undefined) throw new S3Failure(404, 'NoSuchKey', 'The specified key does not exist');
          setResponseStatus(event, 204);
          return '';
        }
        default:
          throw new S3Failure(405, 'MethodNotAllowed', 'Unsupported operation');
      }
    } catch (e) {
      // An unread request body would otherwise keep the connection busy draining it.
      if (!event.node.req.complete) setResponseHeader(event, 'Connection', 'close');
      if (e instanceof S3Failure) return method === 'HEAD' ? (setResponseStatus(event, e.status), '') : sendError(event, e, url.split('?')[0]!);
      if (e instanceof InvalidKeyError) return sendError(event, new S3Failure(400, 'InvalidArgument', 'Invalid key'), url.split('?')[0]!);
      ctx.log(`s3 error: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`);
      return sendError(event, new S3Failure(500, 'InternalError', 'We encountered an internal error'), url.split('?')[0]!);
    }
  });
}
