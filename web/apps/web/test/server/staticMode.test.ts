import { createServer } from 'node:http';
import { createApp, defineEventHandler, toNodeListener } from 'h3';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { loadConfig } from '../../server/lib/config';
import { contentSecurityPolicy, metaContentSecurityPolicy } from '../../server/lib/http';
import { clientConfigFor, staticModeResponse } from '../../server/lib/staticMode';

describe('NOTEIT_MODE=static', () => {
  let url = '';
  const server = createServer(
    toNodeListener(
      createApp().use(
        defineEventHandler((event) => {
          const answer = staticModeResponse(event);
          return answer === undefined ? 'client file' : answer;
        }),
      ),
    ),
  );
  beforeAll(async () => {
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
    url = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  });
  afterAll(() => new Promise<void>((r) => server.close(() => r())));

  it('parses the mode and refuses an unknown one', () => {
    expect(loadConfig({ NOTEIT_DATA_DIR: '/tmp/x' }).mode).toBe('server');
    expect(loadConfig({ NOTEIT_DATA_DIR: '/tmp/x', NOTEIT_MODE: 'static' }).mode).toBe('static');
    expect(() => loadConfig({ NOTEIT_DATA_DIR: '/tmp/x', NOTEIT_MODE: 'direct' })).toThrow(/NOTEIT_MODE/);
  });

  it('serves noteit-client.json from the mode', () => {
    expect(clientConfigFor(loadConfig({ NOTEIT_DATA_DIR: '/tmp/x' }))).toEqual({ mode: 'server' });
    expect(clientConfigFor(loadConfig({ NOTEIT_DATA_DIR: '/tmp/x', NOTEIT_MODE: 'static', NOTEIT_SOURCE_URL: 'https://example.com/fork' }))).toEqual({ mode: 'direct', sourceUrl: 'https://example.com/fork' });
  });

  it('answers only health and the client files', async () => {
    expect(await (await fetch(`${url}/api/health`)).json()).toEqual({ ok: true, mode: 'static', needsSetup: false });
    expect(await (await fetch(`${url}/api/health/live`)).json()).toEqual({ ok: true });
    for (const path of ['/api/_actions/server-info', '/api/_actions/sign-in', '/api/storage/list', '/api/oidc/callback', '/s3/noteit', '/api']) {
      const res = await fetch(`${url}${path}`, { method: path.includes('sign-in') ? 'POST' : 'GET' });
      expect(res.status, path).toBe(404);
    }
    expect(await (await fetch(`${url}/`)).text()).toBe('client file');
  });

  it('lets a direct-mode page reach any https bucket, and keeps the meta policy free of header-only directives', () => {
    expect(contentSecurityPolicy([], false)).toContain("connect-src 'self';");
    expect(contentSecurityPolicy(['abc'], true)).toContain("connect-src 'self' https: http://localhost:* http://127.0.0.1:*");
    expect(contentSecurityPolicy(['abc'], true)).toContain("'sha256-abc'");
    const meta = metaContentSecurityPolicy(['abc']);
    expect(meta).not.toContain('frame-ancestors');
    expect(meta).toContain("script-src 'self' 'sha256-abc'");
  });
});
