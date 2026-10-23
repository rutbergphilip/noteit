import { getHeader, getRequestURL, type H3Event, setResponseHeader } from 'h3';
import { ApiFailure } from './accounts';
import type { ServerConfig } from './config';

/** Strips W/ and one pair of quotes (spec §6.2: drivers never see quotes). */
export function normalizeIfMatch(header: string | undefined): string | undefined {
  if (header === undefined) return undefined;
  let e = header.trim();
  if (e.startsWith('W/')) e = e.slice(2);
  if (e.length >= 2 && e.startsWith('"') && e.endsWith('"')) e = e.slice(1, -1);
  if (!e || e.includes(',')) throw new ApiFailure(400, 'badRequest', 'If-Match must name one ETag');
  return e;
}

/** Only `*` is meaningful. */
export function parseIfNoneMatch(header: string | undefined): boolean {
  if (header === undefined) return false;
  if (header.trim() !== '*') throw new ApiFailure(400, 'badRequest', 'If-None-Match must be *');
  return true;
}

export const quoteETag = (etag: string) => `"${etag}"`;

/**
 * Splits the raw (still percent-encoded) path after `prefix` into a key. Each segment is decoded once; a segment
 * that decodes to something containing `/`, `\` or NUL, or that doesn't decode, is refused. The layout grammar
 * check happens in the store, which is the choke point.
 */
export function keyFromRawPath(rawPath: string, prefix: string): string {
  const path = rawPath.split('?')[0]!;
  if (!path.startsWith(prefix)) throw new ApiFailure(400, 'invalidKey', 'bad path');
  const segments = path.slice(prefix.length).split('/');
  const decoded = segments.map((s) => {
    let d: string;
    try {
      d = decodeURIComponent(s);
    } catch {
      throw new ApiFailure(400, 'invalidKey', 'bad encoding');
    }
    if (/[/\\\0]/.test(d)) throw new ApiFailure(400, 'invalidKey', 'bad key');
    return d;
  });
  return decoded.join('/');
}

export function isHttps(event: H3Event, cfg: ServerConfig): boolean {
  if (cfg.publicUrl) return cfg.publicUrl.startsWith('https://');
  if (cfg.trustProxy && getHeader(event, 'x-forwarded-proto') === 'https') return true;
  return getRequestURL(event).protocol === 'https:';
}

/**
 * CSRF for state-changing /api requests: the custom header (never sent cross-origin without a preflight we don't
 * allow) and an Origin that matches NOTEIT_PUBLIC_URL (or the request's own host when it isn't set).
 */
export function checkCsrf(event: H3Event, cfg: ServerConfig): void {
  const method = event.method.toUpperCase();
  if (method === 'GET' || method === 'HEAD' || method === 'OPTIONS') return;
  if (getHeader(event, 'x-noteit') !== '1') throw new ApiFailure(403, 'forbidden', 'Missing X-NoteIt header');
  const origin = getHeader(event, 'origin');
  const expected = cfg.publicUrl ? new URL(cfg.publicUrl).origin : getRequestURL(event, { xForwardedHost: cfg.trustProxy, xForwardedProto: cfg.trustProxy }).origin;
  if (origin !== expected) throw new ApiFailure(403, 'forbidden', 'Cross-origin request refused');
}

const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' blob: data:",
  "font-src 'self'",
  "connect-src 'self'",
  "worker-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join('; ');

export function securityHeaders(event: H3Event, cfg: ServerConfig): void {
  setResponseHeader(event, 'Content-Security-Policy', CSP);
  setResponseHeader(event, 'X-Content-Type-Options', 'nosniff');
  setResponseHeader(event, 'Referrer-Policy', 'no-referrer');
  setResponseHeader(event, 'X-Frame-Options', 'DENY');
  setResponseHeader(event, 'Cross-Origin-Opener-Policy', 'same-origin');
  setResponseHeader(event, 'Cross-Origin-Resource-Policy', 'same-origin');
  setResponseHeader(event, 'Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=()');
  if (isHttps(event, cfg)) setResponseHeader(event, 'Strict-Transport-Security', 'max-age=31536000');
}

export function clientIp(event: H3Event, cfg: ServerConfig): string {
  if (cfg.trustProxy) {
    const fwd = getHeader(event, 'x-forwarded-for');
    if (fwd) return fwd.split(',')[0]!.trim();
  }
  return event.node.req.socket.remoteAddress ?? 'unknown';
}
