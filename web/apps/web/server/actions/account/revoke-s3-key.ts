import { accessKeyInput } from '../../../shared/schemas';
import { authClient } from '../../utils/action-client';

export default authClient
  .schema(accessKeyInput)
  .errors({ notFound: 'That key no longer exists.' })
  .action(async ({ parsedInput, ctx: { noteit, user }, fail }) => {
    await noteit.accounts.mutate((f) => {
      const u = f.users.find((x) => x.id === user.id)!;
      const before = u.s3Keys.length;
      u.s3Keys = u.s3Keys.filter((k) => k.accessKeyId !== parsedInput.accessKeyId);
      if (u.s3Keys.length === before) return fail('notFound');
    });
    return true;
  });
