import { deleteCookie, getCookie, type H3Event, setCookie } from 'h3';
import { newUserId, type User } from './accounts';
import type { ServerContext } from './context';
import { isHttps } from './http';
import { SESSION_COOKIE, SESSION_TTL_S } from './sessions';

export function issueSession(event: H3Event, ctx: ServerContext, user: User): void {
  const now = Math.floor(Date.now() / 1000);
  setCookie(event, SESSION_COOKIE, ctx.sessions.sign({ uid: user.id, epoch: user.sessionEpoch, iat: now, exp: now + SESSION_TTL_S }), {
    httpOnly: true,
    secure: isHttps(event, ctx.cfg),
    sameSite: 'strict',
    path: '/',
    maxAge: SESSION_TTL_S,
  });
}

export function clearSession(event: H3Event): void {
  deleteCookie(event, SESSION_COOKIE, { path: '/' });
}

/**
 * The signed-in account, re-checked on every request (active, same session epoch), or undefined. Slides the cookie
 * once a day.
 */
export function sessionUser(event: H3Event, ctx: ServerContext): User | undefined {
  const p = ctx.sessions.verify(getCookie(event, SESSION_COOKIE));
  const user = p && ctx.accounts.byId(p.uid);
  if (!p || !user || user.status !== 'active' || user.sessionEpoch !== p.epoch) return undefined;
  if (Math.floor(Date.now() / 1000) - p.iat > 86_400) issueSession(event, ctx, user);
  return user;
}

export function publicUser(u: User) {
  return { id: u.id, username: u.username, displayName: u.displayName, role: u.role, mustChangePassword: u.mustChangePassword, oidcLinked: false };
}

export async function sessionView(ctx: ServerContext, user: User) {
  const usage = await ctx.quotas.current(user.id);
  return {
    user: publicUser(user),
    quota: { usedBytes: usage.bytes, limitBytes: user.quotaBytes, usedObjects: usage.objects, limitObjects: user.maxObjects },
  };
}

export function newUser(ctx: ServerContext, init: { username: string; displayName?: string | undefined; role: User['role']; passwordHash: string }, extra: Partial<User> = {}): User {
  return {
    id: newUserId(),
    username: init.username,
    displayName: init.displayName || init.username,
    role: init.role,
    status: 'active',
    passwordHash: init.passwordHash,
    sessionEpoch: 1,
    mustChangePassword: false,
    quotaBytes: ctx.cfg.defaultQuotaBytes,
    maxObjects: ctx.cfg.defaultMaxObjects,
    s3Keys: [],
    createdAt: new Date().toISOString(),
    ...extra,
  };
}
