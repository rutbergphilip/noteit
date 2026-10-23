import { sessionUser, sessionView } from '../lib/auth';
import { publicClient } from '../utils/action-client';

/** The signed-in account and its quota, or null when signed out (not an error: it's how the SPA boots). */
export default publicClient.action(async ({ ctx: { noteit }, event }) => {
  const user = sessionUser(event, noteit);
  return user ? sessionView(noteit, user) : null;
});
