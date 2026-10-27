import { createLibrary, expect, newAccount, test as base } from './fixtures';
import type { Page } from '@playwright/test';

/** An admin (not the first one) with an open library. */
const test = base.extend<{ admin: void }>({
  admin: async ({ page, context, baseURL }, use, info) => {
    await newAccount(context, info, baseURL!, { role: 'admin' });
    await page.goto('/');
    await createLibrary(page);
    await use();
  },
});

async function openSettings(page: Page, section: string) {
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Settings' });
  await dialog.getByRole('navigation', { name: 'Settings sections' }).getByRole('button', { name: section }).click();
  await expect(dialog.getByRole('heading', { level: 2, name: section })).toBeVisible();
  return dialog;
}

test('S3 access keys: create, list, replace and revoke', async ({ page, admin }) => {
  void admin;
  const settings = await openSettings(page, 'Account');
  await settings.getByLabel('Key label').fill('Laptop');
  await settings.getByRole('button', { name: 'Create Key' }).click();
  await expect(settings.getByText("Copy the secret now. It isn't shown again.")).toBeVisible();
  const keyId = (await settings.getByText('Access key ID').locator('xpath=following-sibling::code').textContent())!.trim();
  expect(keyId).toMatch(/^[A-Z0-9]{16,}$/);
  const row = settings.locator('div').filter({ hasText: keyId }).filter({ has: page.getByRole('button', { name: 'Revoke' }) }).last();
  await expect(row).toContainText('Laptop');
  await expect(row).toContainText('never used');

  await row.getByRole('button', { name: 'Replace' }).click();
  await expect(settings.getByText(keyId)).toHaveCount(0);
  const replaced = settings.locator('div').filter({ hasText: 'Laptop' }).filter({ has: page.getByRole('button', { name: 'Revoke' }) }).last();
  await replaced.getByRole('button', { name: 'Revoke' }).click();
  await page.getByRole('alertdialog').or(page.getByRole('dialog').last()).getByRole('button', { name: /Revoke/ }).last().click();
  await expect(settings.getByRole('button', { name: 'Revoke' })).toHaveCount(0);
});

test('invites: an admin makes a link, someone joins with it, and shows in the user list', async ({ page, admin, browser, baseURL }) => {
  void admin;
  const settings = await openSettings(page, 'Users');
  await settings.getByRole('button', { name: 'Create Invite Link' }).click();
  const link = (await settings.getByText('Invite link').locator('xpath=following-sibling::code').textContent())!.trim();
  expect(link).toMatch(/#invite=/);
  // Invites are server-wide (other specs make some too), so count them.
  await expect(settings.getByText('Invite (user)').first()).toBeVisible();
  const open = await settings.getByText('Invite (user)').count();

  const guest = await browser.newContext({ baseURL });
  const g = await guest.newPage();
  await g.goto(link);
  await expect(g.getByRole('heading', { name: 'Create Your Account' })).toBeVisible();
  await expect(g.getByLabel('Invite code')).not.toHaveValue('');
  const username = `guest${Date.now().toString(36)}`;
  await g.getByLabel('Username').fill(username);
  await g.getByLabel('Password').fill('guest-password-1');
  await g.getByRole('button', { name: 'Create Account' }).click();
  await createLibrary(g);
  await guest.close();

  // The admin's list shows the new account; the used invite is gone. Reopening loads the list again.
  await settings.getByRole('button', { name: 'Close settings' }).last().click();
  const again = await openSettings(page, 'Users');
  await expect(again.getByText(`@${username}`)).toBeVisible();
  await expect(again.getByText(`@${username}`)).toBeVisible();
  expect(await again.getByText('Invite (user)').count()).toBeLessThan(open);

  // Create a user directly: a temporary password is shown once.
  await again.getByRole('textbox', { name: 'Username' }).fill(`direct${Date.now().toString(36)}`);
  await again.getByRole('button', { name: 'Create User' }).click();
  await expect(again.getByText('they choose their own password on first sign-in')).toBeVisible();
});

test('a non-admin sees no Users section, and admin actions are refused', async ({ page, context, baseURL }, info) => {
  await newAccount(context, info, baseURL!);
  await page.goto('/');
  await createLibrary(page);
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  const nav = page.getByRole('dialog', { name: 'Settings' }).getByRole('navigation', { name: 'Settings sections' });
  await expect(nav.getByRole('button', { name: 'Account' })).toBeVisible();
  await expect(nav.getByRole('button', { name: 'Users' })).toHaveCount(0);
  const res = await page.request.get(`${baseURL}/api/_actions/admin/users`, { headers: { origin: baseURL! } });
  const body = await res.json();
  expect(body.serverError?.code).toBe('forbidden');
});
