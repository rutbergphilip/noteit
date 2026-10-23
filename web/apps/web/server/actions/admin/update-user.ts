import { updateUserInput } from '../../../shared/schemas';
import { removesLastAdmin } from '../../lib/accounts';
import { adminClient } from '../../utils/action-client';

export default adminClient
  .schema(updateUserInput)
  .errors({
    notFound: 'That account no longer exists.',
    lastAdmin: 'There must be at least one active admin.',
  })
  .action(async ({ parsedInput: { id, role, status, displayName, quotaBytes, maxObjects }, ctx: { noteit }, fail }) => {
    await noteit.accounts.mutate((f) => {
      const u = f.users.find((x) => x.id === id);
      if (!u || u.status === 'deleting') return fail('notFound');
      if (removesLastAdmin(f, { userId: id, role: role === 'user' ? role : undefined, status: status === 'disabled' ? status : undefined })) return fail('lastAdmin');
      if (role) u.role = role;
      if (status) {
        if (status !== u.status) u.sessionEpoch += 1;
        u.status = status;
      }
      if (quotaBytes) u.quotaBytes = quotaBytes;
      if (maxObjects) u.maxObjects = maxObjects;
      if (displayName) u.displayName = displayName;
    });
    return true;
  });
