import { accessKeyInput } from '../../../shared/schemas';
import { newAccessKeyId, newSecret } from '../../lib/accounts';
import { authClient } from '../../utils/action-client';

/** Replaces a key with a new id and secret under the same label. */
export default authClient
  .schema(accessKeyInput)
  .errors({ notFound: 'That key no longer exists.' })
  .action(({ parsedInput, ctx: { noteit, user }, fail }) =>
    noteit.accounts.mutate((f) => {
      const u = f.users.find((x) => x.id === user.id)!;
      const old = u.s3Keys.find((k) => k.accessKeyId === parsedInput.accessKeyId);
      if (!old) return fail('notFound');
      const key = { accessKeyId: newAccessKeyId(), secretAccessKey: newSecret(), label: old.label, createdAt: new Date().toISOString() };
      u.s3Keys = [...u.s3Keys.filter((k) => k !== old), key];
      return { accessKeyId: key.accessKeyId, secretAccessKey: key.secretAccessKey };
    }),
  );
