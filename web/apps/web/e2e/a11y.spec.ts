import AxeBuilder from '@axe-core/playwright';
import { expect, newAccount, newNote, test } from './fixtures';
import { test as plain } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Serious and critical WCAG 2.1 A/AA violations on the page as it is now, once its Vue and CSS
 * transitions have ended (a label still fading in measures as low contrast).
 */
async function violations(page: Page): Promise<string[]> {
  await page.waitForFunction(
    () =>
      !document.querySelector('[class*="-enter-active"], [class*="-leave-active"]') &&
      document.getAnimations().every((a) => a.playState !== 'running' || a.effect?.getTiming().iterations === Infinity),
  );
  const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  return results.violations
    .filter((v) => v.impact === 'serious' || v.impact === 'critical')
    .map((v) => `${v.id} (${v.impact}): ${v.help} — ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(' | ')}`);
}

plain('a11y: sign-in screen', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Sign In' })).toBeVisible();
  expect(await violations(page)).toEqual([]);
});

plain('a11y: unlock screen', async ({ page, context, baseURL }, info) => {
  await newAccount(context, info, baseURL!);
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Encrypt Your Notes' })).toBeVisible();
  expect(await violations(page)).toEqual([]);
});

test('a11y: the library with a note open, the palette and settings', async ({ page, account }) => {
  void account;
  await newNote(page, 'Accessible', 'some **text**', '- a list');
  expect(await violations(page)).toEqual([]);
  await page.keyboard.press('ControlOrMeta+k');
  await expect(page.getByRole('dialog').getByPlaceholder('Search notes and commands')).toBeVisible();
  expect(await violations(page)).toEqual([]);
  await page.keyboard.press('Escape');
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Settings' })).toBeVisible();
  expect(await violations(page)).toEqual([]);
  // The dark palette too (the theme follows the system by default).
  await page.emulateMedia({ colorScheme: 'dark' });
  await expect(page.locator('html')).toHaveClass(/\bdark\b/);
  expect(await violations(page)).toEqual([]);
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog', { name: 'Settings' })).toBeHidden();
  expect(await violations(page)).toEqual([]);
});

plain('a11y: sign-in screen, dark', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Sign In' })).toBeVisible();
  expect(await violations(page)).toEqual([]);
});
