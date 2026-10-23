import { randomBytes, randomUUID } from 'node:crypto';
import { createInviteInput } from '../../../shared/schemas';
import { type Invite, sha256hex } from '../../lib/accounts';
import { adminClient } from '../../utils/action-client';

/** The token is returned once; only its hash is stored. */
export default adminClient.schema(createInviteInput).action(async ({ parsedInput, ctx: { noteit, user } }) => {
  const token = randomBytes(24).toString('base64url');
  const invite: Invite = {
    id: randomUUID().toUpperCase(),
    tokenSha256: sha256hex(token),
    role: parsedInput.role,
    createdBy: user.id,
    createdAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + (parsedInput.ttlHours ?? noteit.cfg.inviteTtlHours) * 3_600_000).toISOString(),
    ...(parsedInput.quotaBytes ? { quotaBytes: parsedInput.quotaBytes } : {}),
  };
  await noteit.accounts.mutate((f) => void f.invites.push(invite));
  return { id: invite.id, token, expiresAt: invite.expiresAt };
});
