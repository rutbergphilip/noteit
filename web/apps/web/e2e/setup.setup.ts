import { ADMIN, adminState, expect, expectReady, PASSPHRASE, SETUP_TOKEN } from './fixtures';
import { test } from '@playwright/test';

// The first-admin wizard on a brand-new server. It runs once per browser; the other specs reuse the admin it makes.
test('first-admin setup wizard', async ({ page }, info) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Create the admin account' })).toBeVisible();

  // A wrong token is refused under its field.
  await page.getByLabel('Setup token').fill('not-the-token');
  await page.getByLabel('Password').fill(ADMIN.password);
  await page.getByRole('button', { name: 'Continue' }).click();
  await expect(page.getByText('That setup token is not right.')).toBeVisible();

  await page.getByLabel('Setup token').fill(SETUP_TOKEN);
  await expect(page.getByLabel('Username')).toHaveValue(ADMIN.username);
  await page.getByRole('button', { name: 'Continue' }).click();

  await expect(page.getByRole('heading', { name: 'Where should notes be stored?' })).toBeVisible();
  await page.getByRole('button', { name: 'Continue' }).click();

  await expect(page.getByRole('heading', { name: 'Encrypt your notes' })).toBeVisible();
  await page.getByLabel('Encryption passphrase').fill('short');
  await page.getByLabel('Type it again').fill('short');
  await page.getByRole('button', { name: 'Create Encrypted Library' }).click();
  await expect(page.getByText('Use at least 8 characters.')).toBeVisible();
  await page.getByLabel('Encryption passphrase').fill(PASSPHRASE);
  await page.getByLabel('Type it again').fill(`${PASSPHRASE}!`);
  await page.getByRole('button', { name: 'Create Encrypted Library' }).click();
  await expect(page.getByText("The passphrases don't match.")).toBeVisible();
  await page.getByLabel('Type it again').fill(PASSPHRASE);
  await page.getByRole('button', { name: 'Create Encrypted Library' }).click();

  await expect(page.getByRole('heading', { name: 'Users & finish' })).toBeVisible({ timeout: 30_000 });
  await page.getByRole('button', { name: 'Create Invite Link' }).click();
  await expect(page.getByText(/#invite=/)).toBeVisible();
  await page.getByRole('button', { name: 'Create Access Key' }).click();
  await expect(page.getByText("Copy the secret now; it isn't shown again.")).toBeVisible();
  await page.getByRole('button', { name: 'Open NoteIt' }).click();
  await expectReady(page);

  // The token works once: a second setup is refused by the server.
  const again = await page.request.post('/api/_actions/setup', {
    headers: { origin: new URL(page.url()).origin, 'content-type': 'application/json' },
    data: JSON.stringify({ token: SETUP_TOKEN, username: 'other', password: 'other-password-1' }),
  });
  expect((await again.json()).businessError?.code).toBe('alreadySetUp');

  await page.context().storageState({ path: adminState(info) });
});
