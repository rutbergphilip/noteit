import { changePasswordInput } from '../../../shared/schemas';
import { hashPassword, verifyPassword } from '../../lib/accounts';
import { issueSession } from '../../lib/auth';
import { type ActionMeta, authClient } from '../../utils/action-client';

/** Also the forced first-sign-in change, so it runs while mustChangePassword is set. Ends every other session. */
export default authClient
  .metadata({ allowPasswordChange: true } satisfies ActionMeta)
  .schema(changePasswordInput)
  .errors({ wrongPassword: 'Your current password is not right.' })
  .action(async ({ parsedInput, ctx: { noteit, user }, event, fail }) => {
    if (!(await verifyPassword(user.passwordHash, parsedInput.current))) return fail('wrongPassword', { validationErrors: { current: ['That is not your current password.'] } });
    const passwordHash = await hashPassword(parsedInput.next);
    const updated = await noteit.accounts.mutate((f) => {
      const u = f.users.find((x) => x.id === user.id)!;
      u.passwordHash = passwordHash;
      u.mustChangePassword = false;
      u.sessionEpoch += 1;
      return u;
    });
    issueSession(event, noteit, updated);
    return true;
  });
