import { randomBytes, randomUUID } from 'node:crypto';
import { unlink } from 'node:fs/promises';
import { join } from 'node:path';
import {
  createRouter,
  defineEventHandler,
  deleteCookie,
  getCookie,
  getHeader,
  getQuery,
  getRouterParam,
  type H3Event,
  readBody,
  setCookie,
  setResponseHeader,
  setResponseStatus,
  useBase,
} from 'h3';
import {
  ApiFailure,
  type AccountsFile,
  assertNotLastAdmin,
  checkPassword,
  hashPassword,
  type Invite,
  newAccessKeyId,
  newSecret,
  newUserId,
  sha256hex,
  type User,
  USERNAME_RE,
  verifyPassword,
} from './accounts';
import { isListablePrefix, isValidKey } from '@noteit/core';
import { BodyTooLarge, readBodyLimited } from './body';
import type { ServerContext } from './context';
import { InvalidKeyError } from './diskStore';
import { checkCsrf, clientIp, isHttps, keyFromRawPath, normalizeIfMatch, parseIfNoneMatch, quoteETag } from './http';
import { SESSION_COOKIE, SESSION_TTL_S } from './sessions';

const PAGE = 1000;

function fail(status: number, code: string, message?: string): never {
  throw new ApiFailure(status, code, message);
}

async function jsonBody<T extends Record<string, unknown>>(event: H3Event): Promise<Partial<T>> {
  const body = (await readBody(event).catch(() => undefined)) as unknown;
  if (body === undefined || body === null || body === '') return {};
  if (typeof body !== 'object' || Array.isArray(body)) fail(400, 'badRequest', 'Expected a JSON object');
  return body as Partial<T>;
}

const str = (v: unknown, max = 200): string | undefined => (typeof v === 'string' && v.length <= max ? v : undefined);

export function publicUser(u: User) {
  return { id: u.id, username: u.username, displayName: u.displayName, role: u.role, mustChangePassword: u.mustChangePassword, oidcLinked: false };
}

/** The REST API under /api (spec §6.3). Mount the returned handler at the server root. */
export function createApiHandler(ctx: ServerContext) {
  const { cfg, accounts, store, sessions, quotas } = ctx;
  const router = createRouter();

  const issueSession = (event: H3Event, user: User) => {
    const now = Math.floor(Date.now() / 1000);
    setCookie(event, SESSION_COOKIE, sessions.sign({ uid: user.id, epoch: user.sessionEpoch, iat: now, exp: now + SESSION_TTL_S }), {
      httpOnly: true,
      secure: isHttps(event, cfg),
      sameSite: 'strict',
      path: '/',
      maxAge: SESSION_TTL_S,
    });
  };

  /** Re-checks the account on every request: active, same epoch. Slides the cookie once a day. */
  const requireUser = (event: H3Event, opts: { allowPasswordChange?: boolean } = {}): User => {
    const p = sessions.verify(getCookie(event, SESSION_COOKIE));
    const user = p && accounts.byId(p.uid);
    if (!p || !user || user.status !== 'active' || user.sessionEpoch !== p.epoch) fail(401, 'unauthorized', 'Sign in again.');
    if (user.mustChangePassword && !opts.allowPasswordChange) fail(403, 'passwordChangeRequired', 'Choose a new password first.');
    if (Math.floor(Date.now() / 1000) - p.iat > 86_400) issueSession(event, user);
    return user;
  };

  const requireAdmin = (event: H3Event): User => {
    const user = requireUser(event);
    if (user.role !== 'admin') fail(403, 'forbidden', 'Admins only.');
    return user;
  };

  const sessionResponse = async (user: User) => {
    const usage = await quotas.current(user.id);
    return {
      user: publicUser(user),
      quota: { usedBytes: usage.bytes, limitBytes: user.quotaBytes, usedObjects: usage.objects, limitObjects: user.maxObjects },
    };
  };

  const newUser = (username: string, displayName: string, role: User['role'], passwordHash: string, extra: Partial<User> = {}): User => ({
    id: newUserId(),
    username,
    displayName: displayName || username,
    role,
    status: 'active',
    passwordHash,
    sessionEpoch: 1,
    mustChangePassword: false,
    quotaBytes: cfg.defaultQuotaBytes,
    maxObjects: cfg.defaultMaxObjects,
    s3Keys: [],
    createdAt: new Date().toISOString(),
    ...extra,
  });

  const checkUsername = (v: unknown): string => {
    const username = typeof v === 'string' ? v.trim().toLowerCase() : '';
    if (!USERNAME_RE.test(username)) fail(400, 'badRequest', 'Usernames are 2–32 lowercase letters, digits, dots, dashes or underscores.');
    return username;
  };

  // MARK: health and info

  router.get('/health/live', defineEventHandler(() => ({ ok: true })));
  router.get('/health', defineEventHandler(() => ({ ok: true, mode: 'server', needsSetup: accounts.isEmpty })));
  router.get(
    '/server-info',
    defineEventHandler(() => ({
      version: cfg.version,
      commit: cfg.commit,
      sourceUrl: cfg.sourceUrl,
      needsSetup: accounts.isEmpty,
      storage: 'disk',
      auth: { password: cfg.passwordLogin, oidc: null },
    })),
  );

  // MARK: setup and sessions

  router.post(
    '/setup',
    defineEventHandler(async (event) => {
      if (!accounts.isEmpty) fail(404, 'notFound');
      const wait = ctx.setupLimiter.hit(clientIp(event, cfg));
      if (wait) {
        setResponseHeader(event, 'Retry-After', String(wait));
        fail(429, 'rateLimited', 'Too many attempts.');
      }
      const body = await jsonBody(event);
      if (!ctx.bootstrap.matches(body.token)) fail(403, 'invalidSetupToken', 'That setup token is not right.');
      const username = checkUsername(body.username ?? cfg.adminUsername);
      const password = checkPassword(body.password);
      const passwordHash = await hashPassword(password);
      const user = await accounts.mutate((f) => {
        if (f.users.length > 0) fail(404, 'notFound');
        const u = newUser(username, str(body.displayName, 64) ?? username, 'admin', passwordHash);
        f.users.push(u);
        return u;
      });
      ctx.bootstrap.consume();
      await unlink(join(cfg.dataDir, 'setup-token')).catch(() => undefined);
      issueSession(event, user);
      setResponseStatus(event, 204);
      return null;
    }),
  );

  router.post(
    '/login',
    defineEventHandler(async (event) => {
      if (!cfg.passwordLogin) fail(404, 'notFound');
      const body = await jsonBody(event);
      const username = typeof body.username === 'string' ? body.username.trim().toLowerCase() : '';
      const ip = clientIp(event, cfg);
      const wait = Math.max(ctx.loginLimiter.hit(`ip:${ip}`), ctx.loginLimiter.hit(`user:${username}`));
      if (wait) {
        setResponseHeader(event, 'Retry-After', String(wait));
        setResponseStatus(event, 429);
        return { error: 'rateLimited', message: 'Too many attempts. Try again shortly.', retryAfter: wait };
      }
      const user = accounts.byUsername(username);
      const ok = await verifyPassword(user?.passwordHash, typeof body.password === 'string' ? body.password : '');
      if (!user || !ok || user.status !== 'active') fail(401, 'invalidCredentials', 'Wrong username or password.');
      ctx.loginLimiter.reset(`user:${username}`);
      await accounts.mutate((f) => {
        const u = f.users.find((x) => x.id === user.id);
        if (u) u.lastSeenAt = new Date().toISOString();
      });
      issueSession(event, accounts.byId(user.id)!);
      setResponseStatus(event, 204);
      return null;
    }),
  );

  router.post(
    '/logout',
    defineEventHandler((event) => {
      deleteCookie(event, SESSION_COOKIE, { path: '/' });
      setResponseStatus(event, 204);
      return null;
    }),
  );

  router.get('/session', defineEventHandler((event) => sessionResponse(requireUser(event, { allowPasswordChange: true }))));

  // MARK: account

  router.patch(
    '/account',
    defineEventHandler(async (event) => {
      const user = requireUser(event);
      const body = await jsonBody(event);
      const displayName = str(body.displayName, 64)?.trim();
      if (!displayName) fail(400, 'badRequest', 'Enter a name.');
      await accounts.mutate((f) => {
        const u = f.users.find((x) => x.id === user.id);
        if (u) u.displayName = displayName;
      });
      return sessionResponse(accounts.byId(user.id)!);
    }),
  );

  router.post(
    '/account/password',
    defineEventHandler(async (event) => {
      const user = requireUser(event, { allowPasswordChange: true });
      const body = await jsonBody(event);
      if (!(await verifyPassword(user.passwordHash, typeof body.current === 'string' ? body.current : ''))) fail(401, 'invalidCredentials', 'Your current password is not right.');
      const passwordHash = await hashPassword(checkPassword(body.next));
      const updated = await accounts.mutate((f) => {
        const u = f.users.find((x) => x.id === user.id)!;
        u.passwordHash = passwordHash;
        u.mustChangePassword = false;
        u.sessionEpoch += 1;
        return u;
      });
      issueSession(event, updated);
      setResponseStatus(event, 204);
      return null;
    }),
  );

  router.post(
    '/account/logout-everywhere',
    defineEventHandler(async (event) => {
      const user = requireUser(event, { allowPasswordChange: true });
      await accounts.mutate((f) => {
        const u = f.users.find((x) => x.id === user.id);
        if (u) u.sessionEpoch += 1;
      });
      deleteCookie(event, SESSION_COOKIE, { path: '/' });
      setResponseStatus(event, 204);
      return null;
    }),
  );

  const keyView = (k: User['s3Keys'][number]) => ({ accessKeyId: k.accessKeyId, label: k.label, createdAt: k.createdAt, lastUsedAt: k.lastUsedAt });

  router.get('/account/s3-keys', defineEventHandler((event) => requireUser(event).s3Keys.map(keyView)));
  router.post(
    '/account/s3-keys',
    defineEventHandler(async (event) => {
      const user = requireUser(event);
      const body = await jsonBody(event);
      const label = str(body.label, 64)?.trim() || 'Access key';
      return accounts.mutate((f) => {
        const u = f.users.find((x) => x.id === user.id)!;
        if (u.s3Keys.length >= 10) fail(409, 'badRequest', 'You can have up to 10 keys.');
        const key = { accessKeyId: newAccessKeyId(), secretAccessKey: newSecret(), label, createdAt: new Date().toISOString() };
        u.s3Keys.push(key);
        return { accessKeyId: key.accessKeyId, secretAccessKey: key.secretAccessKey };
      });
    }),
  );
  router.delete(
    '/account/s3-keys/:id',
    defineEventHandler(async (event) => {
      const user = requireUser(event);
      const id = getRouterParam(event, 'id');
      await accounts.mutate((f) => {
        const u = f.users.find((x) => x.id === user.id)!;
        const before = u.s3Keys.length;
        u.s3Keys = u.s3Keys.filter((k) => k.accessKeyId !== id);
        if (u.s3Keys.length === before) fail(404, 'notFound');
      });
      setResponseStatus(event, 204);
      return null;
    }),
  );
  router.post(
    '/account/s3-keys/:id/rotate',
    defineEventHandler(async (event) => {
      const user = requireUser(event);
      const id = getRouterParam(event, 'id');
      return accounts.mutate((f) => {
        const u = f.users.find((x) => x.id === user.id)!;
        const old = u.s3Keys.find((k) => k.accessKeyId === id);
        if (!old) fail(404, 'notFound');
        const key = { accessKeyId: newAccessKeyId(), secretAccessKey: newSecret(), label: old.label, createdAt: new Date().toISOString() };
        u.s3Keys = [...u.s3Keys.filter((k) => k !== old), key];
        return { accessKeyId: key.accessKeyId, secretAccessKey: key.secretAccessKey };
      });
    }),
  );

  // MARK: invites

  router.post(
    '/invites/redeem',
    defineEventHandler(async (event) => {
      const wait = ctx.setupLimiter.hit(`invite:${clientIp(event, cfg)}`);
      if (wait) fail(429, 'rateLimited', 'Too many attempts.');
      const body = await jsonBody(event);
      const token = typeof body.token === 'string' ? body.token : '';
      const username = checkUsername(body.username);
      const passwordHash = await hashPassword(checkPassword(body.password));
      const user = await accounts.mutate((f) => {
        const invite = f.invites.find((i) => i.tokenSha256 === sha256hex(token));
        if (!invite || invite.usedAt || invite.revokedAt || Date.parse(invite.expiresAt) < Date.now()) fail(410, 'inviteInvalid', 'This invite is no longer valid.');
        if (f.users.some((u) => u.username === username)) fail(409, 'usernameTaken', 'That username is taken.');
        const u = newUser(username, str(body.displayName, 64) ?? username, invite.role, passwordHash, {
          ...(invite.quotaBytes ? { quotaBytes: invite.quotaBytes } : {}),
          ...(invite.maxObjects ? { maxObjects: invite.maxObjects } : {}),
        });
        f.users.push(u);
        invite.usedAt = new Date().toISOString();
        invite.usedBy = u.id;
        return u;
      });
      issueSession(event, user);
      setResponseStatus(event, 204);
      return null;
    }),
  );

  // MARK: admin

  router.get(
    '/admin/users',
    defineEventHandler(async (event) => {
      requireAdmin(event);
      const users = await Promise.all(
        accounts.users.map(async (u) => {
          const usage = await quotas.current(u.id);
          return {
            id: u.id,
            username: u.username,
            displayName: u.displayName,
            role: u.role,
            status: u.status,
            methods: ['password'],
            quotaBytes: u.quotaBytes,
            maxObjects: u.maxObjects,
            usedBytes: usage.bytes,
            objectCount: usage.objects,
            lastSeenAt: u.lastSeenAt,
          };
        }),
      );
      return { users, totalCeilingBytes: accounts.users.reduce((n, u) => n + u.quotaBytes, 0) };
    }),
  );

  router.post(
    '/admin/users',
    defineEventHandler(async (event) => {
      requireAdmin(event);
      const body = await jsonBody(event);
      const username = checkUsername(body.username);
      const role = body.role === 'admin' ? 'admin' : 'user';
      const temporaryPassword = randomBytes(12).toString('base64url');
      const passwordHash = await hashPassword(temporaryPassword);
      const user = await accounts.mutate((f) => {
        if (f.users.some((u) => u.username === username)) fail(409, 'usernameTaken', 'That username is taken.');
        const u = newUser(username, str(body.displayName, 64) ?? username, role, passwordHash, {
          mustChangePassword: true,
          ...(typeof body.quotaBytes === 'number' && body.quotaBytes > 0 ? { quotaBytes: Math.floor(body.quotaBytes) } : {}),
          ...(typeof body.maxObjects === 'number' && body.maxObjects > 0 ? { maxObjects: Math.min(10_000_000, Math.floor(body.maxObjects)) } : {}),
        });
        f.users.push(u);
        return u;
      });
      return { user: publicUser(user), temporaryPassword };
    }),
  );

  router.patch(
    '/admin/users/:id',
    defineEventHandler(async (event) => {
      requireAdmin(event);
      const id = getRouterParam(event, 'id') ?? '';
      const body = await jsonBody(event);
      await accounts.mutate((f: AccountsFile) => {
        const u = f.users.find((x) => x.id === id);
        if (!u || u.status === 'deleting') fail(404, 'notFound');
        const role = body.role === 'admin' || body.role === 'user' ? body.role : undefined;
        const status = body.status === 'active' || body.status === 'disabled' ? body.status : undefined;
        assertNotLastAdmin(f, { userId: id, ...(role === 'user' ? { role } : {}), ...(status === 'disabled' ? { status } : {}) });
        if (role) u.role = role;
        if (status) {
          if (status !== u.status) u.sessionEpoch += 1;
          u.status = status;
        }
        if (typeof body.quotaBytes === 'number' && body.quotaBytes > 0) u.quotaBytes = Math.floor(body.quotaBytes);
        if (typeof body.maxObjects === 'number' && body.maxObjects > 0) u.maxObjects = Math.min(10_000_000, Math.floor(body.maxObjects));
        const name = str(body.displayName, 64)?.trim();
        if (name) u.displayName = name;
      });
      return { ok: true };
    }),
  );

  router.post(
    '/admin/users/:id/reset-password',
    defineEventHandler(async (event) => {
      requireAdmin(event);
      const id = getRouterParam(event, 'id') ?? '';
      const temporaryPassword = randomBytes(12).toString('base64url');
      const passwordHash = await hashPassword(temporaryPassword);
      await accounts.mutate((f) => {
        const u = f.users.find((x) => x.id === id);
        if (!u || u.status === 'deleting') fail(404, 'notFound');
        u.passwordHash = passwordHash;
        u.mustChangePassword = true;
        u.sessionEpoch += 1;
      });
      return { temporaryPassword };
    }),
  );

  router.delete(
    '/admin/users/:id',
    defineEventHandler(async (event) => {
      requireAdmin(event);
      const id = getRouterParam(event, 'id') ?? '';
      const body = await jsonBody(event);
      const target = accounts.byId(id);
      if (!target || target.status === 'deleting') fail(404, 'notFound');
      if (body.confirmUsername !== target.username) fail(400, 'badRequest', 'Type the username to confirm.');
      await accounts.mutate((f) => {
        assertNotLastAdmin(f, { userId: id, status: 'deleting' });
        const u = f.users.find((x) => x.id === id)!;
        u.status = 'deleting';
        u.sessionEpoch += 1;
        u.s3Keys = [];
      });
      await store.deleteNamespace(id);
      quotas.forget(id);
      await accounts.mutate((f) => {
        f.users = f.users.filter((u) => u.id !== id);
      });
      setResponseStatus(event, 202);
      return null;
    }),
  );

  const inviteView = (i: Invite) => ({ id: i.id, role: i.role, createdAt: i.createdAt, expiresAt: i.expiresAt, usedAt: i.usedAt, revokedAt: i.revokedAt, quotaBytes: i.quotaBytes, maxObjects: i.maxObjects });

  router.get('/admin/invites', defineEventHandler((event) => (requireAdmin(event), accounts.invites.map(inviteView))));
  router.post(
    '/admin/invites',
    defineEventHandler(async (event) => {
      const admin = requireAdmin(event);
      const body = await jsonBody(event);
      const ttl = typeof body.ttlHours === 'number' && body.ttlHours > 0 && body.ttlHours <= 24 * 30 ? body.ttlHours : cfg.inviteTtlHours;
      const token = randomBytes(24).toString('base64url');
      const invite: Invite = {
        id: randomUUID().toUpperCase(),
        tokenSha256: sha256hex(token),
        role: body.role === 'admin' ? 'admin' : 'user',
        createdBy: admin.id,
        createdAt: new Date().toISOString(),
        expiresAt: new Date(Date.now() + ttl * 3_600_000).toISOString(),
      };
      if (typeof body.quotaBytes === 'number' && body.quotaBytes > 0) invite.quotaBytes = Math.floor(body.quotaBytes);
      await accounts.mutate((f) => void f.invites.push(invite));
      return { id: invite.id, token, expiresAt: invite.expiresAt };
    }),
  );
  router.delete(
    '/admin/invites/:id',
    defineEventHandler(async (event) => {
      requireAdmin(event);
      const id = getRouterParam(event, 'id');
      await accounts.mutate((f) => {
        const invite = f.invites.find((i) => i.id === id);
        if (!invite) fail(404, 'notFound');
        invite.revokedAt = new Date().toISOString();
      });
      setResponseStatus(event, 204);
      return null;
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

  const SETUP_ALLOWED = new Set(['/health', '/health/live', '/server-info', '/setup']);

  const inner = useBase('/api', router.handler);
  return defineEventHandler(async (event) => {
    event.context.noteitRawUrl = event.node.req.url ?? '';
    try {
      const path = (event.path.split('?')[0] ?? '').replace(/^\/api/, '');
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
