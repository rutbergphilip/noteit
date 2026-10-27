import { editorOf, expect, expectSaved, noteRow, test } from './fixtures';
import type { Page } from '@playwright/test';

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true });

const noSideScroll = (page: Page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);

test('phone: one pane at a time, the drawer, and no sideways scrolling', async ({ page, account }) => {
  void account;
  expect(await noSideScroll(page)).toBe(true);
  await page.getByRole('button', { name: 'New note', exact: true }).click();
  await expect(editorOf(page)).toBeFocused();
  // The list is hidden while the editor shows.
  await expect(page.getByRole('region', { name: 'Notes' })).toBeHidden();
  await page.keyboard.type('Phone note');
  await page.keyboard.press('Enter');
  await page.keyboard.type('written on a small screen');
  await expectSaved(page);
  expect(await noSideScroll(page)).toBe(true);

  await page.getByRole('button', { name: 'Back to notes' }).click();
  await expect(noteRow(page, 'Phone note')).toBeVisible();
  await expect(editorOf(page)).toBeHidden();

  // The sidebar is a drawer.
  await page.getByRole('button', { name: 'Show notebooks and tags' }).click();
  const drawer = page.getByRole('dialog').filter({ has: page.getByRole('navigation', { name: 'Library' }) });
  await expect(drawer).toBeVisible();
  await drawer.getByRole('button', { name: 'Today' }).click();
  await expect(drawer).toBeHidden();
  await expect(editorOf(page)).toBeVisible();

  // Search lives behind a button; the palette finds the note.
  await page.getByRole('button', { name: 'Back to notes' }).click();
  await page.getByRole('button', { name: 'Search notes and commands' }).click();
  await page.getByRole('dialog').getByPlaceholder('Search notes and commands').fill('small screen');
  await page.getByRole('dialog').getByRole('option', { name: /Phone note/ }).click();
  await expect(editorOf(page)).toContainText('written on a small screen');
  expect(await noSideScroll(page)).toBe(true);
});
