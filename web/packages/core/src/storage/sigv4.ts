import { copyBytes, hex, sha256Hex, utf8 } from '../bytes.js';

/** AWS Signature Version 4, header form. Mirrors Sources/NoteItSync/Storage/SigV4Signer.swift. */

export const EMPTY_PAYLOAD_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
export const UNSIGNED_PAYLOAD = 'UNSIGNED-PAYLOAD';

/** RFC 3986: everything but unreserved characters is percent-encoded. */
export function uriEncode(s: string, encodeSlash = true): string {
  let out = '';
  for (const byte of utf8(s)) {
    const c = String.fromCharCode(byte);
    if (/[A-Za-z0-9\-._~]/.test(c) || (c === '/' && !encodeSlash)) out += c;
    else out += `%${byte.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return out;
}

function safeDecode(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

export function canonicalURI(percentEncodedPath: string): string {
  if (!percentEncodedPath) return '/';
  return percentEncodedPath.split('/').map((seg) => uriEncode(safeDecode(seg))).join('/');
}

export function canonicalQuery(percentEncodedQuery: string): string {
  if (!percentEncodedQuery) return '';
  return percentEncodedQuery
    .split('&')
    .filter((p) => p.length > 0)
    .map((pair) => {
      const i = pair.indexOf('=');
      const name = i < 0 ? pair : pair.slice(0, i);
      const value = i < 0 ? '' : pair.slice(i + 1);
      return [uriEncode(safeDecode(name)), uriEncode(safeDecode(value))] as const;
    })
    .sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0) : a[0] < b[0] ? -1 : 1))
    .map(([n, v]) => `${n}=${v}`)
    .join('&');
}

export function amzTimestamps(date: Date): { amzDate: string; dateStamp: string } {
  const iso = date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  return { amzDate: iso, dateStamp: iso.slice(0, 8) };
}

async function hmac(key: Uint8Array, message: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey('raw', copyBytes(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, utf8(message)));
}

export interface CanonicalInput {
  method: string;
  /** Path as sent on the wire (percent-encoded), e.g. "/s3/noteit/noteit/v1/manifest.json". */
  path: string;
  /** Query as sent on the wire, without "?". */
  query: string;
  /** Lowercased header name → value, for exactly the signed headers. */
  headers: Record<string, string>;
  signedHeaders: string[];
  payloadHash: string;
}

export function canonicalRequest(c: CanonicalInput): string {
  const names = [...c.signedHeaders].sort();
  const canonicalHeaders = names.map((n) => `${n}:${(c.headers[n] ?? '').trim().split(/[ \t]+/).join(' ')}\n`).join('');
  return [c.method, canonicalURI(c.path), canonicalQuery(c.query), canonicalHeaders, names.join(';'), c.payloadHash].join('\n');
}

export async function signature(opts: {
  canonical: string;
  amzDate: string;
  dateStamp: string;
  region: string;
  service?: string;
  secretAccessKey: string;
}): Promise<string> {
  const service = opts.service ?? 's3';
  const scope = `${opts.dateStamp}/${opts.region}/${service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', opts.amzDate, scope, await sha256Hex(utf8(opts.canonical))].join('\n');
  let key: Uint8Array = utf8(`AWS4${opts.secretAccessKey}`);
  for (const part of [opts.dateStamp, opts.region, service, 'aws4_request']) key = await hmac(key, part);
  return hex(await hmac(key, stringToSign));
}

/** Signs a request; returns the headers to add (x-amz-date, x-amz-content-sha256, authorization). */
export async function signRequest(opts: {
  method: string;
  url: URL;
  headers: Record<string, string>;
  payloadHash: string;
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
  date: Date;
}): Promise<Record<string, string>> {
  const { amzDate, dateStamp } = amzTimestamps(opts.date);
  const headers: Record<string, string> = { host: opts.url.host };
  for (const [name, value] of Object.entries(opts.headers)) {
    const lower = name.toLowerCase();
    if (lower.startsWith('x-amz-') || lower === 'range' || lower === 'if-match' || lower === 'if-none-match') headers[lower] = value;
  }
  headers['x-amz-date'] = amzDate;
  headers['x-amz-content-sha256'] = opts.payloadHash;
  const signedHeaders = Object.keys(headers).sort();
  const canonical = canonicalRequest({
    method: opts.method,
    path: opts.url.pathname,
    query: opts.url.search.replace(/^\?/, ''),
    headers,
    signedHeaders,
    payloadHash: opts.payloadHash,
  });
  const sig = await signature({ canonical, amzDate, dateStamp, region: opts.region, secretAccessKey: opts.secretAccessKey });
  return {
    'x-amz-date': amzDate,
    'x-amz-content-sha256': opts.payloadHash,
    authorization: `AWS4-HMAC-SHA256 Credential=${opts.accessKeyId}/${dateStamp}/${opts.region}/s3/aws4_request, SignedHeaders=${signedHeaders.join(';')}, Signature=${sig}`,
  };
}

export interface ParsedAuthorization {
  accessKeyId: string;
  dateStamp: string;
  region: string;
  service: string;
  signedHeaders: string[];
  signature: string;
}

export function parseAuthorization(header: string): ParsedAuthorization | undefined {
  const m = /^AWS4-HMAC-SHA256\s+Credential=([^/,\s]+)\/(\d{8})\/([^/,\s]+)\/([^/,\s]+)\/aws4_request\s*,\s*SignedHeaders=([^,\s]+)\s*,\s*Signature=([0-9a-f]{64})\s*$/.exec(header.trim());
  if (!m) return undefined;
  return { accessKeyId: m[1]!, dateStamp: m[2]!, region: m[3]!, service: m[4]!, signedHeaders: m[5]!.split(';'), signature: m[6]! };
}
