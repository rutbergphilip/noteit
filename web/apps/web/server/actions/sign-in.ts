import { setResponseHeader } from 'h3';
import { signInInput } from '../../shared/schemas';
import { verifyPassword } from '../lib/accounts';
import { issueSession, sessionView } from '../lib/auth';
import { clientIp } from '../lib/http';
import { publicClient } from '../utils/action-client';

/** Password sign-in. One uniform error for unknown users and wrong passwords, rate-limited per IP and per name. */
export default publicClient
  .schema(signInInput)
  .errors({
    invalidCredentials: 'Wrong username or password.',
    rateLimited: 'Too many attempts. Try again shortly.',
    passwordLoginDisabled: 'Password sign-in is turned off on this server.',
  })
  .action(async ({ parsedInput: { username, password }, ctx: { noteit }, event, fail }) => {
    if (!noteit.cfg.passwordLogin) return fail('passwordLoginDisabled');
    const ip = clientIp(event, noteit.cfg);
    const wait = Math.max(noteit.loginLimiter.hit(`ip:${ip}`), noteit.loginLimiter.hit(`user:${username}`));
    if (wait) {
      setResponseHeader(event, 'Retry-After', wait);
      return fail('rateLimited');
    }
    const user = noteit.accounts.byUsername(username);
    const ok = await verifyPassword(user?.passwordHash, password);
    if (!user || !ok || user.status !== 'active') return fail('invalidCredentials');
    noteit.loginLimiter.reset(`user:${username}`);
    await noteit.accounts.mutate((f) => {
      const u = f.users.find((x) => x.id === user.id);
      if (u) u.lastSeenAt = new Date().toISOString();
    });
    const fresh = noteit.accounts.byId(user.id)!;
    issueSession(event, noteit, fresh);
    return sessionView(noteit, fresh);
  });
