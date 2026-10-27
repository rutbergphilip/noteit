import { action, editorOf, expect, expectSaved, newAccount, newNote, noteRow, randomIp, runCommand, test as base, unlockLibrary, createLibrary } from './fixtures';
import type { Page } from '@playwright/test';

const test = base;

/** Every note's text in this tab, opened one by one. */
async function allTexts(page: Page): Promise<string[]> {
  const rows = page.getByRole('region', { name: 'Notes' }).getByRole('listitem');
  const out: string[] = [];
  for (let i = 0; i < (await rows.count()); i++) {
    await rows.nth(i).click();
    await expect(rows.nth(i)).toHaveAttribute('aria-current', 'true');
    out.push((await editorOf(page).textContent()) ?? '');
  }
  return out;
}

test('two tabs: an edit in one shows in the other, and edits at the same moment both survive', async ({ page, context, account }) => {
  void account;
  await newNote(page, 'Shared', 'line one');
  const other = await context.newPage();
  await other.goto('/');
  await unlockLibrary(other);
  await noteRow(other, 'Shared').click();
  await expect(editorOf(other)).toContainText('line one');

  // Tab 1 edits; tab 2 reloads the note in place.
  await editorOf(page).getByText('line one').click();
  await page.keyboard.press('End');
  await page.keyboard.type(' from tab one');
  await expectSaved(page);
  await expect(editorOf(other)).toContainText('line one from tab one');

  // Both type before either save goes out: neither edit is lost (one becomes a conflict copy).
  await editorOf(page).getByText('line one from tab one').click();
  await page.keyboard.press('End');
  await page.keyboard.type(' AAA');
  await editorOf(other).getByText('line one from tab one').click();
  await other.keyboard.press('End');
  await other.keyboard.type(' BBB');
  await expectSaved(page);
  await expectSaved(other);
  await other.close();
  await page.reload();
  await unlockLibrary(page);
  const texts = (await allTexts(page)).join('\n');
  expect(texts).toContain('AAA');
  expect(texts).toContain('BBB');
});

test('two devices: offline edits on both make exactly one conflict copy, seen on both', async ({ browser, baseURL }, info) => {
  const a = await browser.newContext({ baseURL });
  const pageA = await a.newPage();
  const account = await newAccount(a, info, baseURL!);
  await pageA.goto('/');
  await createLibrary(pageA);
  await newNote(pageA, 'Plan', 'draft');
  await runCommand(pageA, 'Sync Now');
  await expect(pageA.getByRole('status', { name: /Synced/ })).toBeVisible();

  const b = await browser.newContext({ baseURL });
  const signedIn = await action(b.request, baseURL!, 'sign-in', { username: account.username, password: account.password }, { headers: { 'x-forwarded-for': randomIp() } });
  expect(signedIn.data).toBeTruthy();
  const pageB = await b.newPage();
  await pageB.goto('/');
  await unlockLibrary(pageB);
  await noteRow(pageB, 'Plan').click();
  await expect(editorOf(pageB)).toContainText('draft');

  // A edits offline; B edits and syncs; A comes back.
  await a.setOffline(true);
  await editorOf(pageA).getByText('draft').click();
  await pageA.keyboard.press('End');
  await pageA.keyboard.type(' edited on A');
  await expectSaved(pageA);
  await editorOf(pageB).getByText('draft').click();
  await pageB.keyboard.press('End');
  await pageB.keyboard.type(' edited on B');
  await expectSaved(pageB);
  await runCommand(pageB, 'Sync Now');
  await expect(pageB.getByRole('status', { name: /Synced/ })).toBeVisible();
  await a.setOffline(false);
  await runCommand(pageA, 'Sync Now');

  const copies = (p: Page) => p.getByRole('region', { name: 'Notes' }).getByRole('listitem').filter({ hasText: 'Conflict copy' });
  await expect(copies(pageA)).toHaveCount(1);
  await expect(pageA.getByRole('region', { name: 'Notes' }).getByRole('listitem')).toHaveCount(2);
  const textsA = (await allTexts(pageA)).join('\n');
  expect(textsA).toContain('draft edited on A');
  expect(textsA).toContain('draft edited on B');

  await runCommand(pageB, 'Sync Now');
  await expect(copies(pageB)).toHaveCount(1);
  await expect(pageB.getByRole('region', { name: 'Notes' }).getByRole('listitem')).toHaveCount(2);
  await a.close();
  await b.close();
});
