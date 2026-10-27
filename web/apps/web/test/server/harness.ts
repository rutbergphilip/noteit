import { mkdtemp, rm } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp, defineEventHandler, type EventHandler, setResponseStatus, toNodeListener } from 'h3';
import { createActionHandler, type SafeAction } from '#safe-action';
import { createApiHandler } from '../../server/lib/api';
import { loadConfig } from '../../server/lib/config';
import { createContext, type ServerContext } from '../../server/lib/context';
import type { ObjectStore } from '../../server/lib/store';
import { securityHeaders } from '../../server/lib/http';
import { createS3Handler } from '../../server/lib/s3';

export const SETUP_TOKEN = 'test-setup-token-123';

/**
 * server/actions mounted the way the nuxt-safe-action module mounts them: `<name>[.<method>].ts` at
 * /api/_actions/<name>, POST unless the filename says otherwise.
 */
const actionModules = import.meta.glob<{ default: SafeAction }>('../../server/actions/**/*.ts', { eager: true });
const actionRoutes = new Map<string, EventHandler>();
for (const [file, mod] of Object.entries(actionModules)) {
  const raw = file.replace('../../server/actions/', '').replace(/\.ts$/, '');
  const m = /^(.*)\.(get|post|put|patch|delete)$/.exec(raw);
  const method = (m?.[2] ?? 'post').toUpperCase();
  actionRoutes.set(`${method} /api/_actions/${m?.[1] ?? raw}`, createActionHandler(mod.default, method));
}

export interface Harness {
  url: string;
  ctx: ServerContext;
  dataDir: string;
  close(): Promise<void>;
}

/** The same handlers Nitro mounts, on a real HTTP listener. */
export async function startServer(env: Record<string, string> = {}, opts: { store?: ObjectStore; log?: (msg: string) => void } = {}): Promise<Harness> {
  const dataDir = await mkdtemp(join(tmpdir(), 'noteit-server-'));
  const cfg = loadConfig({ NOTEIT_DATA_DIR: dataDir, NOTEIT_SETUP_TOKEN: SETUP_TOKEN, ...env });
  const ctx = await createContext(cfg, opts.log ?? (() => undefined), opts.store);
  const api = createApiHandler(ctx);
  const s3 = createS3Handler(ctx);
  const app = createApp();
  app.use(
    defineEventHandler((event) => {
      securityHeaders(event, cfg);
      const action = actionRoutes.get(`${event.method} ${event.path.split('?')[0]}`);
      if (action) {
        event.context.noteit = ctx;
        return action(event);
      }
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
      ctx.store.close();
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

/** What `useAction` gets back: the safe-action result envelope. */
export interface Envelope<T = any> {
  data?: T;
  serverError?: { code: string; message: string };
  businessError?: { code: string; message: string };
  validationErrors?: Record<string, string[]>;
}

/** Calls an action the way the client transport does: JSON POST (or GET with ?input=) from a same-origin tab. */
export async function action<T = any>(b: ReturnType<typeof browser>, name: string, input?: unknown, init: { method?: 'GET' | 'POST'; headers?: Record<string, string> } = {}): Promise<Envelope<T> & { status: number }> {
  const method = init.method ?? 'POST';
  const query = method === 'GET' && input !== undefined ? `?input=${encodeURIComponent(JSON.stringify(input))}` : '';
  const res = await b.fetch(`/api/_actions/${name}${query}`, {
    method,
    headers: { 'content-type': 'application/json', ...init.headers },
    ...(method === 'GET' ? {} : { body: JSON.stringify(input ?? {}) }),
  });
  return { status: res.status, ...((await res.json()) as Envelope<T>) };
}
