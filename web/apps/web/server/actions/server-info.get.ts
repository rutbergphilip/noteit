import { publicClient } from '../utils/action-client';

/** What the SPA needs before anyone signs in. Public, side-effect free. */
export default publicClient.action(({ ctx: { noteit } }) => ({
  version: noteit.cfg.version,
  commit: noteit.cfg.commit,
  sourceUrl: noteit.cfg.sourceUrl,
  needsSetup: noteit.accounts.isEmpty,
  storage: 'disk' as const,
  auth: { password: noteit.cfg.passwordLogin, oidc: null },
}));
