import {
  createRouter,
  defineEventHandler,
  getHeader,
  getQuery,
  type H3Event,
  setResponseHeader,
  setResponseStatus,
  useBase,
} from 'h3';
import { isListablePrefix, isValidKey } from '@noteit/core';
import { ApiFailure, type User } from './accounts';
import { sessionUser } from './auth';
import { BodyTooLarge, readBodyLimited } from './body';
import type { ServerContext } from './context';
import { InvalidKeyError } from './diskStore';
import { StoreUnavailable } from './store';
import { checkCsrf, keyFromRawPath, normalizeIfMatch, parseIfNoneMatch, quoteETag } from './http';

const PAGE = 1000;

function fail(status: number, code: string, message?: string): never {
  throw new ApiFailure(status, code, message);
}

/**
 * The plain /api routes: health probes and the sync data plane (spec §6.3a). The data plane moves opaque ciphertext
 * with ETags, conditional headers and size-capped binary bodies, so it stays a REST blob store rather than safe
 * actions, which are a JSON RPC fit. The control plane (setup, sessions, account, admin) lives in server/actions.
 * Mount the returned handler at the server root.
 */
export function createApiHandler(ctx: ServerContext) {
  const { cfg, accounts, store, quotas } = ctx;
  const router = createRouter();

  const requireUser = (event: H3Event): User => {
    const user = sessionUser(event, ctx);
    if (!user) fail(401, 'unauthorized', 'Sign in again.');
    if (user.mustChangePassword) fail(403, 'passwordChangeRequired', 'Choose a new password first.');
    return user;
  };

  router.get('/health/live', defineEventHandler(() => ({ ok: true })));
  // Readiness: 503 while the store (an upstream S3 bucket) can't be reached. Liveness above never depends on it.
  router.get(
    '/health',
    defineEventHandler((event) => {
      if (!store.ready()) {
        setResponseStatus(event, 503);
        return { ok: false, mode: 'server', reason: 'storeUnavailable' };
      }
      return { ok: true, mode: 'server', needsSetup: accounts.isEmpty };
    }),
  );

  // MARK: storage (zero-knowledge: bytes in, bytes out; the server never parses or decrypts them)

  router.get(
    '/storage/list',
    defineEventHandler(async (event) => {
      const user = requireUser(event);
      const q = getQuery(event);
      const prefix = typeof q.prefix === 'string' ? q.prefix : '';
      if (!isListablePrefix(prefix)) fail(400, 'invalidKey', 'Invalid prefix.');
      const all = await store.list(user.id, prefix);
      const after = typeof q.continuationToken === 'string' && q.continuationToken ? Buffer.from(q.continuationToken, 'base64url').toString('utf8') : undefined;
      const start = after === undefined ? 0 : all.findIndex((o) => o.key > after);
      const page = start < 0 ? [] : all.slice(start, start + PAGE);
      const last = page.at(-1);
      const more = start >= 0 && start + PAGE < all.length;
      return {
        objects: page.map((o) => ({ key: o.key, etag: o.etag, size: o.size, lastModified: o.lastModified })),
        ...(more && last ? { nextContinuationToken: Buffer.from(last.key).toString('base64url') } : {}),
      };
    }),
  );

  // useBase rewrites node.req.url, so the wrapper keeps the original raw URL for key parsing.
  const objectKey = (event: H3Event) => keyFromRawPath(String(event.context.noteitRawUrl ?? ''), '/api/storage/object/');

  router.get(
    '/storage/object/**',
    defineEventHandler(async (event) => {
      const user = requireUser(event);
      const obj = await store.get(user.id, objectKey(event));
      if (!obj) fail(404, 'notFound');
      setResponseHeader(event, 'ETag', quoteETag(obj.etag));
      setResponseHeader(event, 'Content-Type', 'application/octet-stream');
      setResponseHeader(event, 'Cache-Control', 'no-store');
      return Buffer.from(obj.data);
    }),
  );

  router.put(
    '/storage/object/**',
    defineEventHandler(async (event) => {
      // Authenticate and validate everything we can from the headers before a single body byte is read.
      const user = requireUser(event);
      const key = objectKey(event);
      if (!isValidKey(key)) fail(400, 'invalidKey', 'Invalid key.');
      const cond = { ifMatch: normalizeIfMatch(getHeader(event, 'if-match')), ifNoneMatch: parseIfNoneMatch(getHeader(event, 'if-none-match')) };
      let data: Uint8Array;
      try {
        data = await readBodyLimited(event, cfg.maxObjectBytes);
      } catch (e) {
        if (e instanceof BodyTooLarge) {
          setResponseHeader(event, 'Connection', 'close');
          fail(413, 'tooLarge', 'Object too large.');
        }
        throw e;
      }
      const result = await quotas.exclusive(user.id, async () => {
        const previous = await store.head(user.id, key);
        await quotas.admit(user, previous?.size, data.length);
        const put = await store.put(user.id, key, data, cond);
        if (put !== 'preconditionFailed') await quotas.applied(user.id, previous?.size, data.length);
        return put;
      });
      if (result === 'preconditionFailed') fail(412, 'preconditionFailed', 'The object changed.');
      setResponseHeader(event, 'ETag', quoteETag(result.etag));
      return { etag: result.etag };
    }),
  );

  router.delete(
    '/storage/object/**',
    defineEventHandler(async (event) => {
      const user = requireUser(event);
      const key = objectKey(event);
      const ifMatch = normalizeIfMatch(getHeader(event, 'if-match'));
      const result = await quotas.exclusive(user.id, async () => {
        const previous = await store.head(user.id, key);
        const deleted = await store.delete(user.id, key, ifMatch !== undefined ? { ifMatch } : {});
        if (deleted === 'ok') await quotas.applied(user.id, previous?.size, undefined);
        return deleted;
      });
      if (result === 'notFound') fail(404, 'notFound');
      if (result === 'preconditionFailed') fail(412, 'preconditionFailed', 'The object changed.');
      setResponseStatus(event, 204);
      return null;
    }),
  );

  const SETUP_ALLOWED = new Set(['/health', '/health/live']);

  const inner = useBase('/api', router.handler);
  return defineEventHandler(async (event) => {
    event.context.noteitRawUrl = event.node.req.url ?? '';
    try {
      const path = (event.path.split('?')[0] ?? '').replace(/^\/api/, '');
      if (!store.started() && !SETUP_ALLOWED.has(path)) fail(503, 'storeUnavailable', 'The storage backend is not reachable yet.');
      if (accounts.isEmpty && !SETUP_ALLOWED.has(path)) fail(503, 'setupRequired', 'This server needs its first admin.');
      checkCsrf(event, cfg);
      const result = await inner(event);
      if (result === undefined && !event.handled) fail(404, 'notFound');
      return result;
    } catch (e) {
      // An unread request body would otherwise keep the connection busy draining it.
      if (!event.node.req.complete) setResponseHeader(event, 'Connection', 'close');
      if (e instanceof ApiFailure) {
        setResponseStatus(event, e.status);
        return { error: e.code, message: e.message };
      }
      if (e instanceof InvalidKeyError) {
        setResponseStatus(event, 400);
        return { error: 'invalidKey', message: 'Invalid key.' };
      }
      if (e instanceof StoreUnavailable) {
        setResponseStatus(event, 502);
        return { error: 'storeUnavailable', message: 'The storage backend is not reachable. Try again.' };
      }
      const status = (e as { statusCode?: number }).statusCode;
      if (status === 404 || status === 405) {
        setResponseStatus(event, status);
        return { error: 'notFound', message: 'Not found.' };
      }
      ctx.log(`api error: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`);
      setResponseStatus(event, 500);
      return { error: 'storeUnavailable', message: 'Something went wrong.' };
    }
  });
}
