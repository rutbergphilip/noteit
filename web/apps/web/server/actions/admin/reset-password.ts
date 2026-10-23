import { randomBytes } from 'node:crypto';
import { userIdInput } from '../../../shared/schemas';
import { hashPassword } from '../../lib/accounts';
import { adminClient } from '../../utils/action-client';

/** Signs the account out everywhere and hands the admin a one-time temporary password. */
export default adminClient
  .schema(userIdInput)
  .errors({ notFound: 'That account no longer exists.' })
  .action(async ({ parsedInput: { id }, ctx: { noteit }, fail }) => {
    const temporaryPassword = randomBytes(12).toString('base64url');
    const passwordHash = await hashPassword(temporaryPassword);
    await noteit.accounts.mutate((f) => {
      const u = f.users.find((x) => x.id === id);
      if (!u || u.status === 'deleting') return fail('notFound');
      u.passwordHash = passwordHash;
      u.mustChangePassword = true;
      u.sessionEpoch += 1;
    });
    return { temporaryPassword };
  });
