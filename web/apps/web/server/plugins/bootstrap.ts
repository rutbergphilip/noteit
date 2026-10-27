import { defineNitroPlugin } from 'nitropack/runtime';
import { serverContext } from '../lib/context';

/**
 * Opens the data directory and the store at startup, so the setup token is logged before the first request and a
 * configuration that can never work (bad settings, an upstream S3 without conditional requests) stops the
 * process with the reason instead of failing every request.
 */
export default defineNitroPlugin(async () => {
  try {
    const ctx = await serverContext();
    const where = ctx.cfg.store === 's3' && ctx.cfg.s3 ? `stores in s3://${ctx.cfg.s3.bucket}/${ctx.cfg.s3.prefix}` : `data in ${ctx.cfg.dataDir}`;
    ctx.log(`NoteIt server: ${where}${ctx.accounts.isEmpty ? ' (waiting for first-admin setup)' : ''}`);
  } catch (e) {
    console.error(`NoteIt server can't start: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  }
});
