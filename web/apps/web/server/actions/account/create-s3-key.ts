import { createS3KeyInput } from '../../../shared/schemas';
import { newAccessKeyId, newSecret } from '../../lib/accounts';
import { authClient } from '../../utils/action-client';

const MAX_KEYS = 10;

export default authClient
  .schema(createS3KeyInput)
  .errors({ tooManyKeys: `You can have up to ${MAX_KEYS} keys.` })
  .action(({ parsedInput, ctx: { noteit, user }, fail }) =>
    noteit.accounts.mutate((f) => {
      const u = f.users.find((x) => x.id === user.id)!;
      if (u.s3Keys.length >= MAX_KEYS) return fail('tooManyKeys');
      const key = { accessKeyId: newAccessKeyId(), secretAccessKey: newSecret(), label: parsedInput.label || 'Access key', createdAt: new Date().toISOString() };
      u.s3Keys.push(key);
      return { accessKeyId: key.accessKeyId, secretAccessKey: key.secretAccessKey };
    }),
  );
