import { type H3Event, setResponseHeader, setResponseStatus } from 'h3';
import type { ServerConfig } from './config';

/** `noteit-client.json` (spec §6.4): what the client starts as. */
export function clientConfigFor(cfg: ServerConfig): { mode: 'server' } | { mode: 'direct'; sourceUrl: string } {
  return cfg.mode === 'static' ? { mode: 'direct', sourceUrl: cfg.sourceUrl } : { mode: 'server' };
}

/**
 * NOTEIT_MODE=static: answers the health routes and refuses every other /api route (actions included) and /s3 with
 * 404, before anything reaches the accounts or the store. Returns undefined for the client's own files.
 */
export function staticModeResponse(event: H3Event): unknown {
  const path = event.path.split('?')[0] ?? '';
  if (path === '/api/health') return { ok: true, mode: 'static', needsSetup: false };
  if (path === '/api/health/live') return { ok: true };
  if (path === '/api' || path.startsWith('/api/') || path === '/s3' || path.startsWith('/s3/')) {
    setResponseStatus(event, 404);
    setResponseHeader(event, 'Content-Type', 'application/json');
    return { error: 'notFound', message: 'This is a static NoteIt client; it has no server API.' };
  }
  return undefined;
}
