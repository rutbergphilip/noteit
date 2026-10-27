import { setResponseHeader } from 'h3';
import { oidcStartInput } from '../../shared/schemas';
import { sha256hex } from '../lib/accounts';
import { sessionUser } from '../lib/auth';
import { clientIp } from '../lib/http';
import { publicClient } from '../utils/action-client';

/**
 * Starts an OIDC sign-in (spec §7.2) and returns the identity provider URL for the browser to navigate to. The
 * flow's state, nonce and PKCE verifier stay in an encrypted cookie for /api/oidc/callback.
 */
export default publicClient
  .schema(oidcStartInput)
  .errors({
    oidcDisabled: 'Single sign-on is not set up on this server.',
    setupRequired: 'This server needs its first admin.',
    alreadySetUp: 'This server already has an admin.',
    invalidSetupToken: 'That setup token is not right.',
    inviteInvalid: 'This invite is no longer valid.',
    usernameTaken: 'That username is taken.',
    alreadyLinked: 'Your account is already linked to a sign-in. Unlink it first.',
    unauthorized: 'Sign in again.',
    rateLimited: 'Too many attempts. Try again in a minute.',
  })
  .action(async ({ parsedInput: { intent, token, username }, ctx: { noteit }, event, fail }) => {
    const provider = noteit.oidc;
    if (!provider) return fail('oidcDisabled');
    const limited = (key: string) => {
      const wait = noteit.setupLimiter.hit(key);
      if (wait) setResponseHeader(event, 'Retry-After', wait);
      return wait > 0;
    };
    // Until the first admin exists, only setup (which checks the setup token) may start a flow.
    if (noteit.accounts.isEmpty && intent !== 'setup') return fail('setupRequired');
    switch (intent) {
      case 'login':
        return { url: await provider.start(event, noteit, { intent }) };
      case 'link': {
        const user = sessionUser(event, noteit);
        if (!user) return fail('unauthorized');
        if (user.oidc) return fail('alreadyLinked');
        return { url: await provider.start(event, noteit, { intent, uid: user.id, epoch: user.sessionEpoch }) };
      }
      case 'setup': {
        if (!noteit.accounts.isEmpty) return fail('alreadySetUp');
        if (limited(clientIp(event, noteit.cfg))) return fail('rateLimited');
        if (!noteit.bootstrap.matches(token)) return fail('invalidSetupToken', { validationErrors: { token: ['That setup token is not right.'] } });
        return { url: await provider.start(event, noteit, { intent, setupToken: token!, ...(username ? { username } : {}) }) };
      }
      case 'invite': {
        if (limited(`invite:${clientIp(event, noteit.cfg)}`)) return fail('rateLimited');
        const inviteSha = sha256hex(token ?? '');
        const invite = noteit.accounts.invites.find((i) => i.tokenSha256 === inviteSha);
        if (!token || !invite || invite.usedAt || invite.revokedAt || Date.parse(invite.expiresAt) < Date.now()) {
          return fail('inviteInvalid', { validationErrors: { token: ['This invite is no longer valid.'] } });
        }
        if (username && noteit.accounts.byUsername(username)) return fail('usernameTaken', { validationErrors: { username: ['That username is taken.'] } });
        return { url: await provider.start(event, noteit, { intent, inviteSha, ...(username ? { username } : {}) }) };
      }
    }
  });
