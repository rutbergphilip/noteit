import { clearSession } from '../lib/auth';
import { publicClient } from '../utils/action-client';

export default publicClient.action(({ event }) => {
  clearSession(event);
  return true;
});
