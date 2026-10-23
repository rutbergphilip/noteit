import { clearSession } from '../../lib/auth';
import { type ActionMeta, authClient } from '../../utils/action-client';

/** Bumps the session epoch, which invalidates every cookie this account has. */
export default authClient.metadata({ allowPasswordChange: true } satisfies ActionMeta).action(async ({ ctx: { noteit, user }, event }) => {
  await noteit.accounts.mutate((f) => {
    const u = f.users.find((x) => x.id === user.id);
    if (u) u.sessionEpoch += 1;
  });
  clearSession(event);
  return true;
});
