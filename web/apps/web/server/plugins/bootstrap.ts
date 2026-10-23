import { defineNitroPlugin } from 'nitropack/runtime';
import { serverContext } from '../lib/context';

/** Opens the data directory at startup so the setup token is logged before the first request. */
export default defineNitroPlugin(async () => {
  const ctx = await serverContext();
  ctx.log(`NoteIt server: data in ${ctx.cfg.dataDir}${ctx.accounts.isEmpty ? ' (waiting for first-admin setup)' : ''}`);
});
