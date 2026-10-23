import { updateProfileInput } from '../../../shared/schemas';
import { sessionView } from '../../lib/auth';
import { authClient } from '../../utils/action-client';

export default authClient.schema(updateProfileInput).action(async ({ parsedInput, ctx: { noteit, user } }) => {
  await noteit.accounts.mutate((f) => {
    const u = f.users.find((x) => x.id === user.id);
    if (u) u.displayName = parsedInput.displayName;
  });
  return sessionView(noteit, noteit.accounts.byId(user.id)!);
});
