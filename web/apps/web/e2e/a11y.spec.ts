import AxeBuilder from '@axe-core/playwright';
import { expect, newAccount, newNote, test } from './fixtures';
import { test as plain } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Rules left out of the smoke test, each a known finding rather than a regression (see the E2E report):
 * - color-contrast: the design palette's muted text, the amber primary button's label and the wordmark accent are
 *   under 4.5:1. That is a design decision (design/), recorded rather than failed here.
 * - label-content-name-mismatch: the account menu button shows the user's initials and is named "Account".
 */
const KNOWN = ['color-contrast', 'label-content-name-mismatch'];

/** Serious and critical WCAG 2.1 A/AA violations on the page as it is now. */
async function violations(page: Page, alsoKnown: string[] = []): Promise<string[]> {
  const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).disableRules([...KNOWN, ...alsoKnown]).analyze();
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
  // Known: Nuxt UI's command palette renders its results listbox without a name.
  expect(await violations(page, ['aria-input-field-name'])).toEqual([]);
  await page.keyboard.press('Escape');
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Settings' })).toBeVisible();
  expect(await violations(page)).toEqual([]);
});
