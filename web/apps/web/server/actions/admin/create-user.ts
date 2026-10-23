import { randomBytes } from 'node:crypto';
import { createUserInput } from '../../../shared/schemas';
import { hashPassword } from '../../lib/accounts';
import { newUser, publicUser } from '../../lib/auth';
import { adminClient } from '../../utils/action-client';

/** A new account with a one-time temporary password; the user must choose their own on first sign-in. */
export default adminClient
  .schema(createUserInput)
  .errors({ usernameTaken: 'That username is taken.' })
  .action(async ({ parsedInput, ctx: { noteit }, fail }) => {
    const temporaryPassword = randomBytes(12).toString('base64url');
    const passwordHash = await hashPassword(temporaryPassword);
    const user = await noteit.accounts.mutate((f) => {
      if (f.users.some((u) => u.username === parsedInput.username)) return fail('usernameTaken', { validationErrors: { username: ['That username is taken.'] } });
      const u = newUser(noteit, { username: parsedInput.username, displayName: parsedInput.displayName, role: parsedInput.role, passwordHash }, {
        mustChangePassword: true,
        ...(parsedInput.quotaBytes ? { quotaBytes: parsedInput.quotaBytes } : {}),
        ...(parsedInput.maxObjects ? { maxObjects: parsedInput.maxObjects } : {}),
      });
      f.users.push(u);
      return u;
    });
    return { user: publicUser(user), temporaryPassword };
  });
