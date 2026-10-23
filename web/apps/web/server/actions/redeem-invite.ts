import { hashPassword, sha256hex } from '../lib/accounts';
import { redeemInviteInput } from '../../shared/schemas';
import { issueSession, newUser, sessionView } from '../lib/auth';
import { clientIp } from '../lib/http';
import { publicClient } from '../utils/action-client';

/** Creates an account from an admin's invite token and signs it in. */
export default publicClient
  .schema(redeemInviteInput)
  .errors({
    inviteInvalid: 'This invite is no longer valid.',
    usernameTaken: 'That username is taken.',
    rateLimited: 'Too many attempts. Try again in a minute.',
  })
  .action(async ({ parsedInput, ctx: { noteit }, event, fail }) => {
    if (noteit.setupLimiter.hit(`invite:${clientIp(event, noteit.cfg)}`)) return fail('rateLimited');
    const passwordHash = await hashPassword(parsedInput.password);
    const user = await noteit.accounts.mutate((f) => {
      const invite = f.invites.find((i) => i.tokenSha256 === sha256hex(parsedInput.token));
      if (!invite || invite.usedAt || invite.revokedAt || Date.parse(invite.expiresAt) < Date.now()) return fail('inviteInvalid', { validationErrors: { token: ['This invite is no longer valid.'] } });
      if (f.users.some((u) => u.username === parsedInput.username)) return fail('usernameTaken', { validationErrors: { username: ['That username is taken.'] } });
      const u = newUser(noteit, { username: parsedInput.username, displayName: parsedInput.displayName, role: invite.role, passwordHash }, {
        ...(invite.quotaBytes ? { quotaBytes: invite.quotaBytes } : {}),
        ...(invite.maxObjects ? { maxObjects: invite.maxObjects } : {}),
      });
      f.users.push(u);
      invite.usedAt = new Date().toISOString();
      invite.usedBy = u.id;
      return u;
    });
    issueSession(event, noteit, user);
    return sessionView(noteit, user);
  });
