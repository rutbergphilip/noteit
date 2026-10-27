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

function expectedOrigin(event: H3Event, cfg: ServerConfig): string {
  return cfg.publicUrl ? new URL(cfg.publicUrl).origin : getRequestURL(event, { xForwardedHost: cfg.trustProxy, xForwardedProto: cfg.trustProxy }).origin;
}

/**
 * CSRF for state-changing /api requests: the custom header (never sent cross-origin without a preflight we don't
 * allow) and an Origin that matches NOTEIT_PUBLIC_URL (or the request's own host when it isn't set).
 */
export function checkCsrf(event: H3Event, cfg: ServerConfig): void {
  const method = event.method.toUpperCase();
  if (method === 'GET' || method === 'HEAD' || method === 'OPTIONS') return;
  if (getHeader(event, 'x-noteit') !== '1') throw new ApiFailure(403, 'forbidden', 'Missing X-NoteIt header');
  if (getHeader(event, 'origin') !== expectedOrigin(event, cfg)) throw new ApiFailure(403, 'forbidden', 'Cross-origin request refused');
}

/**
 * CSRF for safe actions that change state (every non-GET action). The action transport always sends
 * `Content-Type: application/json`, which a cross-site page can only send after a CORS preflight we never answer:
 * the same guarantee the X-NoteIt header gives the routes above. Form-encoded and text bodies (the ones a plain
 * cross-site <form> can send) are refused, Sec-Fetch-Site must say same-origin when the browser sends it, and the
 * Origin must match exactly as for /api.
 */
export function checkActionCsrf(event: H3Event, cfg: ServerConfig): void {
  const method = event.method.toUpperCase();
  if (method === 'GET' || method === 'HEAD' || method === 'OPTIONS') return;
  const type = getHeader(event, 'content-type')?.split(';', 1)[0]?.trim().toLowerCase();
  if (type !== 'application/json') throw new ApiFailure(415, 'unsupportedMediaType', 'Actions only accept JSON.');
  const site = getHeader(event, 'sec-fetch-site');
  if (site && site !== 'same-origin' && site !== 'none') throw new ApiFailure(403, 'forbidden', 'Cross-site request refused');
  if (getHeader(event, 'origin') !== expectedOrigin(event, cfg)) throw new ApiFailure(403, 'forbidden', 'Cross-origin request refused');
}

/**
 * The CSP; the SPA page adds sha256 hashes of its own inline scripts (Nuxt's config and importmap). In direct mode
 * (spec §11.2) the browser talks to a bucket the user chooses, so `connect-src` allows any https origin and local
 * development endpoints.
 */
export function contentSecurityPolicy(scriptHashes: string[] = [], direct = false): string {
  let policy = CSP.replace("script-src 'self'", ["script-src 'self'", ...scriptHashes.map((h) => `'sha256-${h}'`)].join(' '));
  if (direct) policy = policy.replace("connect-src 'self'", DIRECT_CONNECT_SRC);
  return policy;
}

export const DIRECT_CONNECT_SRC = "connect-src 'self' https: http://localhost:* http://127.0.0.1:*";

/**
 * The page's own `<meta>` CSP, for static hosts that send no header: the direct-mode policy without the directives a
 * `<meta>` policy can't carry (`frame-ancestors`). Under the server's header, both apply and `connect-src` stays 'self'.
 */
export function metaContentSecurityPolicy(scriptHashes: string[]): string {
  return contentSecurityPolicy(scriptHashes, true)
    .split('; ')
    .filter((d) => !d.startsWith('frame-ancestors'))
    .join('; ');
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
  setResponseHeader(event, 'Content-Security-Policy', contentSecurityPolicy([], cfg.mode === 'static'));
  setResponseHeader(event, 'X-Content-Type-Options', 'nosniff');
  setResponseHeader(event, 'Referrer-Policy', 'no-referrer');
  setResponseHeader(event, 'X-Frame-Options', 'DENY');
  setResponseHeader(event, 'Cross-Origin-Opener-Policy', 'same-origin');
  setResponseHeader(event, 'Cross-Origin-Resource-Policy', 'same-origin');
  setResponseHeader(event, 'Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=()');
  if (isHttps(event, cfg)) setResponseHeader(event, 'Strict-Transport-Security', 'max-age=31536000');
}

/**
 * The address rate limits key on. Without NOTEIT_TRUST_PROXY it is the socket peer. Behind proxies, each trusted
 * proxy appends the address it received from, so only entries counted from the right are trustworthy: with
 * NOTEIT_TRUSTED_PROXY_HOPS = n (default 1) the client is the n-th entry from the right. Anything left of that was
 * supplied by the client and is ignored. Too few entries → the socket peer.
 */
export function clientIp(event: H3Event, cfg: ServerConfig): string {
  const peer = event.node.req.socket.remoteAddress ?? 'unknown';
  if (!cfg.trustProxy) return peer;
  const fwd = getHeader(event, 'x-forwarded-for');
  if (!fwd) return peer;
  const entries = fwd.split(',').map((e) => e.trim()).filter(Boolean);
  const entry = entries[entries.length - cfg.trustedProxyHops];
  return entry ?? peer;
}
