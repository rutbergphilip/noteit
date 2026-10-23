import { userIdInput } from '../../../shared/schemas';
import { adminClient } from '../../utils/action-client';

export default adminClient
  .schema(userIdInput)
  .errors({ notFound: 'That invite no longer exists.' })
  .action(async ({ parsedInput: { id }, ctx: { noteit }, fail }) => {
    await noteit.accounts.mutate((f) => {
      const invite = f.invites.find((i) => i.id === id);
      if (!invite) return fail('notFound');
      invite.revokedAt = new Date().toISOString();
    });
    return true;
  });
