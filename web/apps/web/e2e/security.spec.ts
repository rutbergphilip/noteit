import { action, expect, newAccount, test } from './fixtures';

// CSRF: a signed-in session's cookie alone never authorises a state change. Each case keeps the real session
// cookie and changes one thing a cross-site page would differ in.
test('state-changing actions and storage writes refuse cross-origin requests', async ({ context, baseURL }, info) => {
  await newAccount(context, info, baseURL!);
  const req = context.request;
  const keys = async () => (await action<unknown[]>(req, baseURL!, 'account/s3-keys', undefined, { method: 'GET' })).data ?? [];
  expect(await keys()).toHaveLength(0);

  const post = (headers: Record<string, string>, data = '{"label":"evil"}') => req.post(`${baseURL}/api/_actions/account/create-s3-key`, { headers, data });
  expect((await post({ origin: 'http://evil.example', 'content-type': 'application/json' })).status()).toBe(403);
  expect((await post({ 'content-type': 'application/json' })).status()).toBe(403); // no Origin at all
  expect((await post({ origin: baseURL!, 'content-type': 'text/plain' })).status()).toBe(415); // what a <form> or no-cors fetch can send
  expect((await post({ origin: baseURL!, 'content-type': 'application/x-www-form-urlencoded' }, 'label=evil')).status()).toBe(415);
  expect((await post({ origin: baseURL!, 'content-type': 'application/json', 'sec-fetch-site': 'cross-site' })).status()).toBe(403);
  expect(await keys()).toHaveLength(0);
  // The same request from the app's own origin works.
  expect((await post({ origin: baseURL!, 'content-type': 'application/json' })).status()).toBe(200);
  expect(await keys()).toHaveLength(1);

  // The storage API wants X-NoteIt and the right Origin on writes.
  const url = `${baseURL}/api/storage/object/noteit/v1/canary/e2e-csrf`;
  expect((await req.put(url, { headers: { origin: baseURL! }, data: Buffer.from('x') })).status()).toBe(403);
  expect((await req.put(url, { headers: { origin: 'http://evil.example', 'x-noteit': '1' }, data: Buffer.from('x') })).status()).toBe(403);
});

test('a cross-site page posting to the server with the user signed in changes nothing', async ({ page, context, baseURL }, info) => {
  await newAccount(context, info, baseURL!);
  // A page on another origin, served by route interception, that tries a form post and a no-cors fetch.
  await page.route('http://evil.example/**', (route) =>
    route.fulfill({
      contentType: 'text/html',
      body: `<!doctype html><form id=f method=post action="${baseURL}/api/_actions/account/create-s3-key" enctype="text/plain"><input name='{"label":"x","a":"' value='"}'></form>
<script>fetch(${JSON.stringify(`${baseURL}/api/_actions/account/create-s3-key`)}, { method: 'POST', mode: 'no-cors', credentials: 'include', headers: { 'content-type': 'text/plain' }, body: '{"label":"y"}' }).finally(() => { document.title = 'fetched'; document.getElementById('f').submit(); });</script>`,
    }),
  );
  const refused = page.waitForResponse((r) => r.url().endsWith('/api/_actions/account/create-s3-key') && r.request().method() === 'POST' && r.request().resourceType() === 'document');
  await page.goto('http://evil.example/');
  expect((await refused).status()).toBeGreaterThanOrEqual(400);
  const keys = await action<unknown[]>(context.request, baseURL!, 'account/s3-keys', undefined, { method: 'GET' });
  expect(keys.data).toHaveLength(0);
});

test('every response carries the CSP and the other security headers', async ({ request, baseURL }) => {
  const res = await request.get(`${baseURL}/`);
  const h = res.headers();
  expect(h['content-security-policy']).toContain("default-src 'self'");
  expect(h['content-security-policy']).toContain("frame-ancestors 'none'");
  expect(h['x-frame-options']).toBe('DENY');
  expect(h['x-content-type-options']).toBe('nosniff');
  expect(h['referrer-policy']).toBe('no-referrer');
});
