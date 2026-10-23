import { adminClient } from '../../utils/action-client';

export default adminClient.action(async ({ ctx: { noteit } }) => {
  const users = await Promise.all(
    noteit.accounts.users.map(async (u) => {
      const usage = await noteit.quotas.current(u.id);
      return {
        id: u.id,
        username: u.username,
        displayName: u.displayName,
        role: u.role,
        status: u.status,
        methods: ['password'],
        quotaBytes: u.quotaBytes,
        maxObjects: u.maxObjects,
        usedBytes: usage.bytes,
        objectCount: usage.objects,
        lastSeenAt: u.lastSeenAt,
      };
    }),
  );
  return { users, totalCeilingBytes: noteit.accounts.users.reduce((n, u) => n + u.quotaBytes, 0) };
});
