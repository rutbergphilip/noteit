import { authClient } from '../../utils/action-client';

/** Labels and ids only: a secret is shown once, when it is created. */
export default authClient.action(({ ctx: { user } }) =>
  user.s3Keys.map((k) => ({ accessKeyId: k.accessKeyId, label: k.label, createdAt: k.createdAt, lastUsedAt: k.lastUsedAt })),
);
