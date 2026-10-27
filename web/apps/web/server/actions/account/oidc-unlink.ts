import { publicUser } from '../../lib/auth';
import { authClient } from '../../utils/action-client';

/** Removes the linked OIDC sign-in. Only with a password on the account (and password sign-in on), so nobody locks themselves out. */
export default authClient
  .errors({
    notLinked: 'No sign-in is linked to this account.',
    passwordRequired: 'Your account has no password, so unlinking would lock you out.',
    passwordLoginDisabled: 'Password sign-in is turned off on this server, so unlinking would lock you out.',
  })
  .action(async ({ ctx: { noteit, user }, fail }) => {
    if (!user.oidc) return fail('notLinked');
    if (!noteit.cfg.passwordLogin) return fail('passwordLoginDisabled');
    if (!user.passwordHash) return fail('passwordRequired');
    const updated = await noteit.accounts.mutate((f) => {
      const u = f.users.find((x) => x.id === user.id)!;
      delete u.oidc;
      return u;
    });
    return publicUser(updated);
  });
