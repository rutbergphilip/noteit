import { adminClient } from '../../utils/action-client';

export default adminClient.action(({ ctx: { noteit } }) =>
  noteit.accounts.invites.map((i) => ({
    id: i.id,
    role: i.role,
    createdAt: i.createdAt,
    expiresAt: i.expiresAt,
    usedAt: i.usedAt,
    revokedAt: i.revokedAt,
    quotaBytes: i.quotaBytes,
    maxObjects: i.maxObjects,
  })),
);
