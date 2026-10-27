import { action, adminRequest, createLibrary, expect, expectReady, newAccount, PASSPHRASE, randomIp, unlockLibrary } from './fixtures';
import { test } from '@playwright/test';


test.use({ extraHTTPHeaders: { 'x-forwarded-for': randomIp() } });

test('a new user signs in with the temporary password, must change it, then signs out and back in', async ({ page, baseURL }, info) => {
  const admin = await adminRequest(info, baseURL!);
  const username = `t${Date.now().toString(36)}`;
  const created = await action<{ temporaryPassword: string }>(admin, baseURL!, 'admin/create-user', { username });
  await admin.dispose();
  const temp = created.data!.temporaryPassword;

  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Sign In' })).toBeVisible();
  await page.getByLabel('Username').fill(username);
  await page.getByLabel('Password').fill('wrong-password');
  await page.getByRole('button', { name: 'Sign In' }).click();
  await expect(page.getByText('Wrong username or password.')).toBeVisible();

  await page.getByLabel('Password').fill(temp);
  await page.getByRole('button', { name: 'Sign In' }).click();
  await expect(page.getByRole('heading', { name: 'Choose a New Password' })).toBeVisible();
  // The temporary password is still known, so only the new one is asked for. Too short is refused.
  await expect(page.getByLabel('Temporary password')).toHaveCount(0);
  await page.getByLabel('New password').fill('short');
  await page.getByRole('button', { name: 'Save Password' }).click();
  await expect(page.getByRole('heading', { name: 'Choose a New Password' })).toBeVisible();
  await expect(page.getByLabel('New password')).toHaveAttribute('aria-invalid', 'true');

  // A reload keeps the forced change, and now asks for the temporary password too.
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Choose a New Password' })).toBeVisible();
  await page.getByLabel('Temporary password').fill(temp);
  await page.getByLabel('New password').fill('my-own-password-1');
  await page.getByRole('button', { name: 'Save Password' }).click();

  await createLibrary(page);

  // Sign out from the account menu.
  await page.getByRole('button', { name: 'Account' }).click();
  await page.getByRole('menuitem', { name: 'Sign Out' }).click();
  await expect(page.getByRole('heading', { name: 'Sign In' })).toBeVisible();

  // The old temporary password no longer works; the new one does, and the library asks to be unlocked.
  await page.getByLabel('Username').fill(username);
  await page.getByLabel('Password').fill(temp);
  await page.getByRole('button', { name: 'Sign In' }).click();
  await expect(page.getByText('Wrong username or password.')).toBeVisible();
  await page.getByLabel('Password').fill('my-own-password-1');
  await page.getByRole('button', { name: 'Sign In' }).click();
  await expect(page.getByRole('heading', { name: 'Unlock Your Notes' })).toBeVisible();
  await page.getByLabel('Passphrase', { exact: true }).fill('not the passphrase');
  await page.getByRole('button', { name: 'Unlock', exact: true }).click();
  await expect(page.getByText("That passphrase doesn't open this library.")).toBeVisible();
  await unlockLibrary(page, PASSPHRASE);
});

test('an account that must change its password is refused by every other action and by storage', async ({ context, baseURL }, info) => {
  await newAccount(context, info, baseURL!, { changePassword: false });
  const keys = await action(context.request, baseURL!, 'account/create-s3-key', { label: 'x' });
  expect(keys.serverError?.code).toBe('passwordChangeRequired');
  const res = await context.request.get(`${baseURL}/api/storage/object/noteit/v1/manifest.json`);
  expect(res.status()).toBe(403);
});

test('lock and unlock keep the library; a reload locks it again', async ({ page, context, baseURL }, info) => {
  await newAccount(context, info, baseURL!);
  await page.goto('/');
  await createLibrary(page);
  await page.getByRole('button', { name: 'Account' }).click();
  await page.getByRole('menuitem', { name: 'Lock' }).click();
  await unlockLibrary(page);
  await page.reload();
  await unlockLibrary(page);
  await expectReady(page);
});
