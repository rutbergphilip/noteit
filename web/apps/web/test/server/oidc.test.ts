import { OAuth2Server } from 'oauth2-mock-server';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { loadConfig } from '../../server/lib/config';
import { claimList, suggestUsername } from '../../server/lib/oidc';
import { type Envelope, type Harness, SETUP_TOKEN, startServer } from './harness';

/** A same-origin browser with a real cookie jar (the OIDC flow cookie sits next to the session cookie). */
function jarBrowser(base: string) {
  const jar = new Map<string, string>();
  const f = async (input: string, init: RequestInit = {}): Promise<Response> => {
    const headers = new Headers(init.headers);
    if (jar.size) headers.set('cookie', [...jar].map(([k, v]) => `${k}=${v}`).join('; '));
    headers.set('origin', base);
    headers.set('x-noteit', '1');
    const res = await fetch(input.startsWith('/') ? base + input : input, { ...init, headers, redirect: 'manual' });
    for (const c of res.headers.getSetCookie()) {
      const [pair] = c.split(';');
      const i = pair!.indexOf('=');
      const name = pair!.slice(0, i);
      const value = pair!.slice(i + 1);
      if (!value || /max-age=0|expires=thu, 01 jan 1970/i.test(c)) jar.delete(name);
      else jar.set(name, value);
    }
    return res;
  };
  const action = async <T = any>(name: string, input?: unknown, method: 'GET' | 'POST' = 'POST'): Promise<Envelope<T>> => {
    const res = await f(`/api/_actions/${name}`, method === 'GET' ? { method } : { method, headers: { 'content-type': 'application/json' }, body: JSON.stringify(input ?? {}) });
    return (await res.json()) as Envelope<T>;
  };
  return { fetch: f, action, jar };
}

describe('OIDC sign-in', () => {
  let idp: OAuth2Server;
  let h: Harness;
  let claims: Record<string, unknown> = {};
  const logs: string[] = [];

  beforeAll(async () => {
    idp = new OAuth2Server();
    await idp.issuer.keys.generate('RS256');
    await idp.start(0, 'localhost');
    idp.service.on('beforeTokenSigning', (token) => Object.assign(token.payload, claims));
    h = await startServer(
      {
        NOTEIT_OIDC_ISSUER: idp.issuer.url!,
        NOTEIT_OIDC_CLIENT_ID: 'noteit',
        NOTEIT_OIDC_CLIENT_SECRET: 'client-secret',
        NOTEIT_OIDC_REDIRECT_URL: 'http://127.0.0.1:1/api/oidc/callback',
        NOTEIT_OIDC_LABEL: 'Authentik',
        NOTEIT_OIDC_SCOPES: 'openid profile groups',
        NOTEIT_OIDC_AUTO_PROVISION: 'true',
        NOTEIT_OIDC_ALLOWED_GROUPS: 'noteit',
        NOTEIT_OIDC_ADMIN_GROUPS: 'noteit-admins',
      },
      { log: (m) => logs.push(m) },
    );
    // The harness listens on a random port; the redirect URL follows it.
    h.ctx.cfg.oidc!.redirectUrl = `${h.url}/api/oidc/callback`;
  });
  afterAll(async () => {
    await h.close();
    await idp.stop();
  });
  afterEach(() => {
    claims = {};
  });

  /** start → identity provider (auto-approves) → callback; returns where the callback page sends the browser. */
  async function signInThrough(b: ReturnType<typeof jarBrowser>, input: Record<string, unknown>, tamper?: (callback: URL) => void): Promise<string> {
    const started = await b.action<{ url: string }>('oidc-start', input);
    expect(started.data?.url, JSON.stringify(started)).toBeTruthy();
    const authorize = await fetch(started.data!.url, { redirect: 'manual' });
    const callback = new URL(authorize.headers.get('location')!);
    tamper?.(callback);
    const page = await b.fetch(callback.pathname + callback.search);
    expect(page.headers.get('content-type')).toContain('text/html');
    return /url=([^"]+)"/.exec(await page.text())![1]!;
  }

  it('validates its configuration at startup', () => {
    const base = { NOTEIT_DATA_DIR: '/tmp/x', NOTEIT_PUBLIC_URL: 'https://notes.example.com', NOTEIT_OIDC_CLIENT_ID: 'c' };
    expect(() => loadConfig({ ...base, NOTEIT_PASSWORD_LOGIN: 'false' })).toThrow(/needs OIDC/);
    expect(() => loadConfig({ ...base, NOTEIT_OIDC_ISSUER: 'http://idp.example.com' })).toThrow(/https/);
    expect(() => loadConfig({ ...base, NOTEIT_OIDC_ISSUER: 'https://idp.example.com', NOTEIT_OIDC_AUTO_PROVISION: 'true' })).toThrow(/ALLOWED_GROUPS/);
    expect(() => loadConfig({ NOTEIT_DATA_DIR: '/tmp/x', NOTEIT_OIDC_ISSUER: 'https://idp.example.com', NOTEIT_OIDC_CLIENT_ID: 'c' })).toThrow(/NOTEIT_PUBLIC_URL/);
    const cfg = loadConfig({ ...base, NOTEIT_OIDC_ISSUER: 'https://idp.example.com/application/o/noteit/' });
    expect(cfg.oidc).toMatchObject({ redirectUrl: 'https://notes.example.com/api/oidc/callback', scopes: 'openid profile', label: 'Single Sign-On', groupsClaim: 'groups', autoProvision: false });
    expect(loadConfig({ NOTEIT_DATA_DIR: '/tmp/x' }).oidc).toBeUndefined();
  });

  it('reads groups by dot path and suggests free usernames', () => {
    expect(claimList({ realm_access: { roles: ['a', 'b', 3] } }, 'realm_access.roles')).toEqual(['a', 'b']);
    expect(claimList({ groups: 'one' }, 'groups')).toEqual(['one']);
    expect(claimList({}, 'groups')).toBeUndefined();
    expect(suggestUsername({ preferred_username: 'Alice Smith' }, () => false)).toBe('alice-smith');
    expect(suggestUsername({ email: 'bob@example.com' }, (n) => n === 'bob')).toBe('bob-2');
    expect(suggestUsername({}, () => false)).toBe('user');
  });

  it('sets up the first admin through OIDC with the setup token, then signs in by (iss, sub)', async () => {
    const info = await jarBrowser(h.url).action('server-info', undefined, 'GET');
    expect(info.data.auth).toEqual({ password: true, oidc: { label: 'Authentik' } });

    const b = jarBrowser(h.url);
    const wrong = await b.action('oidc-start', { intent: 'setup', token: 'nope' });
    expect(wrong.businessError?.code).toBe('invalidSetupToken');
    claims = { sub: 'admin-sub', preferred_username: 'root', name: 'The Admin', groups: [] };
    expect(await signInThrough(b, { intent: 'setup', token: SETUP_TOKEN, username: 'admin' })).toBe('/');
    const session = await b.action('session', undefined, 'GET');
    expect(session.data.user).toMatchObject({ username: 'admin', displayName: 'The Admin', role: 'admin', oidcLinked: true, hasPassword: false });
    // Single use, through either path.
    expect((await b.action('oidc-start', { intent: 'setup', token: SETUP_TOKEN })).businessError?.code).toBe('alreadySetUp');

    // Signing in again maps by (iss, sub): a changed username or email claim doesn't matter. The admin keeps the role
    // even without the admin group, because demoting them would leave no admin.
    const again = jarBrowser(h.url);
    claims = { sub: 'admin-sub', preferred_username: 'someone-else', email: 'x@example.com' };
    expect(await signInThrough(again, { intent: 'login' })).toBe('/');
    expect((await again.action('session', undefined, 'GET')).data.user).toMatchObject({ username: 'admin', role: 'admin' });
    expect(logs.some((l) => /kept admin an admin/.test(l))).toBe(true);
  });

  it('uses PKCE S256, state and nonce, and refuses a mismatch or a missing flow cookie', async () => {
    const b = jarBrowser(h.url);
    const url = new URL((await b.action<{ url: string }>('oidc-start', { intent: 'login' })).data!.url);
    expect(url.searchParams.get('code_challenge_method')).toBe('S256');
    expect(url.searchParams.get('code_challenge')).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(url.searchParams.get('state')).toBeTruthy();
    expect(url.searchParams.get('nonce')).toBeTruthy();
    expect(url.searchParams.get('scope')).toBe('openid profile groups');
    const flowCookie = b.jar.get('noteit_oidc')!;
    expect(flowCookie).toBeTruthy();
    expect(flowCookie).not.toContain(url.searchParams.get('state')!);

    claims = { sub: 'admin-sub' };
    expect(await signInThrough(jarBrowser(h.url), { intent: 'login' }, (cb) => cb.searchParams.set('state', 'forged'))).toBe('/#oidc-error=failed');
    claims = { sub: 'admin-sub', nonce: 'replayed' };
    const nonce = jarBrowser(h.url);
    expect(await signInThrough(nonce, { intent: 'login' })).toBe('/#oidc-error=failed');
    expect((await nonce.action('session', undefined, 'GET')).data).toBeNull();

    claims = { sub: 'admin-sub' };
    const noCookie = jarBrowser(h.url);
    expect(await signInThrough(noCookie, { intent: 'login' }, () => noCookie.jar.delete('noteit_oidc'))).toBe('/#oidc-error=expired');
    expect(await signInThrough(jarBrowser(h.url), { intent: 'login' }, (cb) => cb.searchParams.set('error', 'access_denied'))).toBe('/#oidc-error=denied');
  });

  it('provisions only members of the allowed groups and sets the role from the admin groups', async () => {
    claims = { sub: 'stranger', preferred_username: 'stranger', groups: ['other'] };
    expect(await signInThrough(jarBrowser(h.url), { intent: 'login' })).toBe('/#oidc-error=notLinked');
    expect(h.ctx.accounts.users.some((u) => u.username === 'stranger')).toBe(false);

    const b = jarBrowser(h.url);
    claims = { sub: 'dana-sub', preferred_username: 'dana', groups: ['noteit', 'noteit-admins'] };
    expect(await signInThrough(b, { intent: 'login' })).toBe('/');
    expect((await b.action('session', undefined, 'GET')).data.user).toMatchObject({ username: 'dana', role: 'admin', oidcLinked: true });
    claims = { sub: 'dana-sub', groups: ['noteit'] };
    expect(await signInThrough(jarBrowser(h.url), { intent: 'login' })).toBe('/');
    expect(h.ctx.accounts.byUsername('dana')?.role).toBe('user');

    // Disabled accounts can't sign in through OIDC either.
    await h.ctx.accounts.mutate((f) => {
      f.users.find((u) => u.username === 'dana')!.status = 'disabled';
    });
    expect(await signInThrough(jarBrowser(h.url), { intent: 'login' })).toBe('/#oidc-error=disabled');
  });

  it('links a sign-in to a password account from Settings, and unlinks it', async () => {
    const admin = jarBrowser(h.url);
    claims = { sub: 'admin-sub' };
    await signInThrough(admin, { intent: 'login' });
    const created = await admin.action('admin/create-user', { username: 'erin' });
    const temp = created.data.temporaryPassword as string;
    const erin = jarBrowser(h.url);
    await erin.action('sign-in', { username: 'erin', password: temp });
    await erin.action('account/change-password', { current: temp, next: 'erins own password' });
    await erin.action('sign-in', { username: 'erin', password: 'erins own password' });

    claims = { sub: 'admin-sub' };
    expect(await signInThrough(erin, { intent: 'link' })).toBe('/#oidc-error=alreadyLinked');
    claims = { sub: 'erin-sub' };
    expect(await signInThrough(erin, { intent: 'link' })).toBe('/#oidc-linked');
    expect((await erin.action('session', undefined, 'GET')).data.user.oidcLinked).toBe(true);
    expect((await erin.action('oidc-start', { intent: 'link' })).businessError?.code).toBe('alreadyLinked');

    const elsewhere = jarBrowser(h.url);
    expect(await signInThrough(elsewhere, { intent: 'login' })).toBe('/');
    expect((await elsewhere.action('session', undefined, 'GET')).data.user.username).toBe('erin');

    expect((await erin.action('account/oidc-unlink')).data.oidcLinked).toBe(false);
    expect(await signInThrough(jarBrowser(h.url), { intent: 'login' })).toBe('/#oidc-error=notLinked');
    // Without a password, unlinking would lock the admin out.
    expect((await admin.action('account/oidc-unlink')).businessError?.code).toBe('passwordRequired');
    // Linking needs a session.
    expect((await jarBrowser(h.url).action('oidc-start', { intent: 'link' })).businessError?.code).toBe('unauthorized');
  });

  it('creates an invited account through OIDC, once', async () => {
    const admin = jarBrowser(h.url);
    claims = { sub: 'admin-sub' };
    await signInThrough(admin, { intent: 'login' });
    const token = (await admin.action('admin/create-invite', { role: 'user' })).data.token as string;

    expect((await jarBrowser(h.url).action('oidc-start', { intent: 'invite', token, username: 'admin' })).businessError?.code).toBe('usernameTaken');
    const frank = jarBrowser(h.url);
    claims = { sub: 'frank-sub', preferred_username: 'frank.f', name: 'Frank' };
    expect(await signInThrough(frank, { intent: 'invite', token, username: 'frank' })).toBe('/');
    expect((await frank.action('session', undefined, 'GET')).data.user).toMatchObject({ username: 'frank', displayName: 'Frank', role: 'user', oidcLinked: true });
    expect((await jarBrowser(h.url).action('oidc-start', { intent: 'invite', token })).businessError?.code).toBe('inviteInvalid');
  });
});

describe('OIDC only (NOTEIT_PASSWORD_LOGIN=false)', () => {
  let idp: OAuth2Server;
  let h: Harness;

  beforeAll(async () => {
    idp = new OAuth2Server();
    await idp.issuer.keys.generate('RS256');
    await idp.start(0, 'localhost');
    h = await startServer({ NOTEIT_OIDC_ISSUER: idp.issuer.url!, NOTEIT_OIDC_CLIENT_ID: 'noteit', NOTEIT_OIDC_REDIRECT_URL: 'http://127.0.0.1:1/api/oidc/callback', NOTEIT_PASSWORD_LOGIN: 'false' });
  });
  afterAll(async () => {
    await h.close();
    await idp.stop();
  });

  it('turns every password path off', async () => {
    const b = jarBrowser(h.url);
    expect((await b.action('server-info', undefined, 'GET')).data.auth).toEqual({ password: false, oidc: { label: 'Single Sign-On' } });
    expect((await b.action('setup', { token: SETUP_TOKEN, username: 'admin', password: 'a long password' })).businessError?.code).toBe('passwordLoginDisabled');
    expect(h.ctx.accounts.isEmpty).toBe(true);
  });
});
