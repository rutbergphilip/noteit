import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { type APIRequestContext, type BrowserContext, expect, type Page, request, test as base, type TestInfo } from '@playwright/test';

export const SETUP_TOKEN = 'e2e-setup-token-0123456789';
export const ADMIN = { username: 'admin', password: 'admin-password-123' };
export const PASSPHRASE = 'correct horse battery staple';

const here = fileURLToPath(new URL('.', import.meta.url));
/** The admin's saved session for one browser project (written by setup.setup.ts). */
export const adminState = (info: TestInfo) => join(here, '.auth', `${info.project.name.replace(/^setup-/, '')}-admin.json`);

/** A random client address: the server trusts X-Forwarded-For in E2E, so every test has its own sign-in limit. */
export const randomIp = () => `10.${[...randomBytes(3)].join('.')}`;

export interface Envelope<T = unknown> {
  data?: T;
  serverError?: { code: string; message: string };
  businessError?: { code: string; message: string };
  validationErrors?: Record<string, string[]>;
}

/** Calls a safe action the way the app's transport does: JSON, same Origin. */
export async function action<T = unknown>(
  req: APIRequestContext,
  baseURL: string,
  name: string,
  input?: unknown,
  opts: { method?: 'GET' | 'POST'; headers?: Record<string, string> } = {},
): Promise<Envelope<T> & { status: number }> {
  const method = opts.method ?? 'POST';
  const headers = { origin: baseURL, 'content-type': 'application/json', ...opts.headers };
  const url = `${baseURL}/api/_actions/${name}`;
  const res =
    method === 'GET'
      ? await req.get(input === undefined ? url : `${url}?input=${encodeURIComponent(JSON.stringify(input))}`, { headers })
      : await req.post(url, { headers, data: JSON.stringify(input ?? {}) });
  const text = await res.text();
  let body: Envelope<T> = {};
  try {
    body = JSON.parse(text) as Envelope<T>;
  } catch {
    /* a refused request may not be JSON */
  }
  return { status: res.status(), ...body };
}

export async function adminRequest(info: TestInfo, baseURL: string): Promise<APIRequestContext> {
  return request.newContext({ baseURL, storageState: adminState(info) });
}

export interface Account {
  username: string;
  password: string;
}

/** A fresh account made by the admin, signed in on `context` with its forced password change already done. */
export async function newAccount(context: BrowserContext, info: TestInfo, baseURL: string, opts: { changePassword?: boolean; role?: 'user' | 'admin' } = {}): Promise<Account & { temporaryPassword: string }> {
  const admin = await adminRequest(info, baseURL);
  const username = `u${randomBytes(5).toString('hex')}`;
  const created = await action<{ temporaryPassword: string }>(admin, baseURL, 'admin/create-user', { username, displayName: `User ${username}`, role: opts.role ?? 'user' });
  await admin.dispose();
  expect(created.data, JSON.stringify(created)).toBeTruthy();
  const temporaryPassword = created.data!.temporaryPassword;
  const password = 'user-password-123';
  const signedIn = await action(context.request, baseURL, 'sign-in', { username, password: temporaryPassword }, { headers: { 'x-forwarded-for': randomIp() } });
  expect(signedIn.data, JSON.stringify(signedIn)).toBeTruthy();
  if (opts.changePassword !== false) {
    const changed = await action(context.request, baseURL, 'account/change-password', { current: temporaryPassword, next: password });
    expect(changed.data, JSON.stringify(changed)).toBe(true);
  }
  return { username, password: opts.changePassword === false ? temporaryPassword : password, temporaryPassword };
}

/** The editor's ProseMirror surface. */
export const editorOf = (page: Page) => page.locator('.ProseMirror[contenteditable="true"]');

/** Waits for the library to be open (the app shell with its New Note button). */
export async function expectReady(page: Page): Promise<void> {
  await expect(page.getByRole('button', { name: 'New note', exact: true })).toBeVisible({ timeout: 30_000 });
}

/** On the "Encrypt Your Notes" screen: makes the library. */
export async function createLibrary(page: Page, passphrase = PASSPHRASE): Promise<void> {
  await expect(page.getByRole('heading', { name: 'Encrypt Your Notes' })).toBeVisible({ timeout: 30_000 });
  await page.getByLabel('Encryption passphrase').fill(passphrase);
  await page.getByLabel('Type it again').fill(passphrase);
  await page.getByRole('button', { name: 'Create Encrypted Library' }).click();
  await expectReady(page);
}

/** On the "Unlock Your Notes" screen: opens the library. */
export async function unlockLibrary(page: Page, passphrase = PASSPHRASE): Promise<void> {
  await expect(page.getByRole('heading', { name: 'Unlock Your Notes' })).toBeVisible({ timeout: 30_000 });
  await page.getByLabel('Passphrase', { exact: true }).fill(passphrase);
  await page.getByRole('button', { name: 'Unlock', exact: true }).click();
  await expectReady(page);
}

/** Creates a note through the New Note button and types `title` and `body` lines into it. */
export async function newNote(page: Page, title: string, ...body: string[]): Promise<void> {
  const before = await page.getByRole('listitem').count();
  await page.getByRole('button', { name: 'New note', exact: true }).click();
  await expect(page.getByRole('listitem')).toHaveCount(before + 1);
  const ed = editorOf(page);
  await expect(ed).toBeFocused();
  await page.keyboard.type(title);
  for (const line of body) {
    await page.keyboard.press('Enter');
    await page.keyboard.type(line);
  }
  await expectSaved(page);
}

/** The editor's save state says Saved (the 600 ms debounce has run and the worker has the edit). */
export async function expectSaved(page: Page): Promise<void> {
  await expect(page.getByRole('toolbar', { name: 'Formatting' }).getByText('Saved', { exact: true })).toBeVisible();
}

/** A note row in the list by title (the row's text starts with it). */
export const noteRow = (page: Page, title: string | RegExp) =>
  page
    .getByRole('region', { name: 'Notes' })
    .getByRole('listitem')
    .filter({ hasText: typeof title === 'string' ? new RegExp(`^${title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`) : title });

/** Runs a command through the command palette (⌘K), by its title. */
export async function runCommand(page: Page, title: string): Promise<void> {
  await page.keyboard.press('ControlOrMeta+k');
  const input = page.getByRole('dialog').getByPlaceholder('Search notes and commands');
  await expect(input).toBeVisible();
  await input.fill(title);
  await page.getByRole('dialog').getByRole('option', { name: title }).first().click();
}

/** A signed-in fresh account with an open, empty library: most specs start here. */
export const test = base.extend<{ account: Account }>({
  account: async ({ page, context, baseURL }, use, info) => {
    const account = await newAccount(context, info, baseURL!);
    await page.goto('/');
    await createLibrary(page);
    await use(account);
  },
});

export { expect };
