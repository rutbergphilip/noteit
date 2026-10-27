import { unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { setResponseHeader } from 'h3';
import { setupInput } from '../../shared/schemas';
import { hashPassword } from '../lib/accounts';
import { issueSession, newUser, sessionView } from '../lib/auth';
import { clientIp } from '../lib/http';
import { publicClient } from '../utils/action-client';

/** Creates the first admin with the one-time setup token from the server log, and signs them in. */
export default publicClient
  .schema(setupInput)
  .errors({
    alreadySetUp: 'This server already has an admin.',
    invalidSetupToken: 'That setup token is not right.',
    rateLimited: 'Too many attempts. Try again in a minute.',
    passwordLoginDisabled: 'Password sign-in is turned off on this server. Use the sign-in button instead.',
  })
  .action(async ({ parsedInput, ctx: { noteit }, event, fail }) => {
    if (!noteit.cfg.passwordLogin) return fail('passwordLoginDisabled');
    if (!noteit.accounts.isEmpty) return fail('alreadySetUp');
    const wait = noteit.setupLimiter.hit(clientIp(event, noteit.cfg));
    if (wait) {
      setResponseHeader(event, 'Retry-After', wait);
      return fail('rateLimited');
    }
    if (!noteit.bootstrap.matches(parsedInput.token)) return fail('invalidSetupToken', { validationErrors: { token: ['That setup token is not right.'] } });
    const passwordHash = await hashPassword(parsedInput.password);
    const user = await noteit.accounts.mutate((f) => {
      if (f.users.length > 0) return fail('alreadySetUp');
      const u = newUser(noteit, { username: parsedInput.username, displayName: parsedInput.displayName, role: 'admin', passwordHash });
      f.users.push(u);
      return u;
    });
    noteit.bootstrap.consume();
    await unlink(join(noteit.cfg.dataDir, 'setup-token')).catch(() => undefined);
    issueSession(event, noteit, user);
    return sessionView(noteit, user);
  });
