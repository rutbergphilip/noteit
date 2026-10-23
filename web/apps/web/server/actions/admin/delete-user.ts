import { deleteUserInput } from '../../../shared/schemas';
import { removesLastAdmin } from '../../lib/accounts';
import { adminClient } from '../../utils/action-client';

/** Deletes an account and every object it stored. The admin types the username to confirm. */
export default adminClient
  .schema(deleteUserInput)
  .errors({
    notFound: 'That account no longer exists.',
    confirmMismatch: 'Type the username to confirm.',
    lastAdmin: 'There must be at least one active admin.',
  })
  .action(async ({ parsedInput: { id, confirmUsername }, ctx: { noteit }, fail }) => {
    const target = noteit.accounts.byId(id);
    if (!target || target.status === 'deleting') return fail('notFound');
    if (confirmUsername !== target.username) return fail('confirmMismatch', { validationErrors: { confirmUsername: ['Type the username to confirm.'] } });
    await noteit.accounts.mutate((f) => {
      if (removesLastAdmin(f, { userId: id, status: 'deleting' })) return fail('lastAdmin');
      const u = f.users.find((x) => x.id === id)!;
      u.status = 'deleting';
      u.sessionEpoch += 1;
      u.s3Keys = [];
    });
    await noteit.store.deleteNamespace(id);
    noteit.quotas.forget(id);
    await noteit.accounts.mutate((f) => {
      f.users = f.users.filter((u) => u.id !== id);
    });
    return true;
  });
