import { mkdtemp, rm } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp, defineEventHandler, setResponseStatus, toNodeListener } from 'h3';
import { createApiHandler } from '../../server/lib/api';
import { loadConfig } from '../../server/lib/config';
import { createContext, type ServerContext } from '../../server/lib/context';
import { securityHeaders } from '../../server/lib/http';
import { createS3Handler } from '../../server/lib/s3';

export const SETUP_TOKEN = 'test-setup-token-123';

export interface Harness {
  url: string;
  ctx: ServerContext;
  dataDir: string;
  close(): Promise<void>;
}

/** The same handlers Nitro mounts, on a real HTTP listener. */
export async function startServer(env: Record<string, string> = {}): Promise<Harness> {
  const dataDir = await mkdtemp(join(tmpdir(), 'noteit-server-'));
  const cfg = loadConfig({ NOTEIT_DATA_DIR: dataDir, NOTEIT_SETUP_TOKEN: SETUP_TOKEN, ...env });
  const ctx = await createContext(cfg, () => undefined);
  const api = createApiHandler(ctx);
  const s3 = createS3Handler(ctx);
  const app = createApp();
  app.use(
    defineEventHandler((event) => {
      securityHeaders(event, cfg);
      if (event.path.startsWith('/api/')) return api(event);
      if (event.path.startsWith('/s3/')) return s3(event);
      setResponseStatus(event, 404);
      return 'not found';
    }),
  );
  const server: Server = createServer(toNodeListener(app));
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('no address');
  const url = `http://127.0.0.1:${address.port}`;
  return {
    url,
    ctx,
    dataDir,
    close: async () => {
      await new Promise<void>((r) => server.close(() => r()));
      await rm(dataDir, { recursive: true, force: true });
    },
  };
}

/** A fetch that behaves like a same-origin browser tab: keeps the session cookie and sends Origin + X-NoteIt. */
export function browser(url: string): { fetch: typeof fetch; cookie: () => string | undefined } {
  let cookie: string | undefined;
  const f = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const headers = new Headers(init.headers);
    if (cookie) headers.set('cookie', cookie);
    if (!headers.has('origin')) headers.set('origin', url);
    if (!headers.has('x-noteit')) headers.set('x-noteit', '1');
    if (init.body && typeof init.body === 'string' && !headers.has('content-type')) headers.set('content-type', 'application/json');
    const { credentials: _c, ...rest } = init;
    const res = await fetch(typeof input === 'string' && input.startsWith('/') ? url + input : input, { ...rest, headers });
    const set = res.headers.get('set-cookie');
    if (set) {
      const value = set.split(';')[0]!;
      cookie = value.endsWith('=') ? undefined : value;
    }
    return res;
  }) as typeof fetch;
  return { fetch: f, cookie: () => cookie };
}
