import { expect, newNote, noteRow, runCommand, test } from './fixtures';
import type { Page } from '@playwright/test';

/** Types a query in the header search and waits for the list to settle on exactly `titles`. */
async function search(page: Page, query: string, titles: string[]): Promise<void> {
  await page.getByRole('searchbox', { name: 'Search notes' }).fill(query);
  const notes = page.getByRole('region', { name: 'Notes' });
  await expect(notes.getByRole('heading', { level: 1 })).toHaveText(query ? `Results for “${query}”` : 'All Notes');
  await expect(notes.getByRole('listitem')).toHaveCount(titles.length);
  for (const t of titles) await expect(noteRow(page, t)).toBeVisible();
}

test('the search language: words, phrases, tags, is:, title:, OR, negation and parentheses', async ({ page, account }) => {
  void account;
  await newNote(page, 'Alpha plan', 'ship the #work release on friday');
  await newNote(page, 'Beta list', '#home buy oat milk');
  await page.keyboard.press('Enter');
  await page.keyboard.type('[ ] call the plumber');
  await newNote(page, 'Gamma notes', 'the release party was fun');
  await noteRow(page, 'Gamma notes').click({ button: 'right' });
  await page.getByRole('menuitem', { name: 'Pin' }).click();

  await search(page, 'release', ['Alpha plan', 'Gamma notes']);
  // Highlighted hits in the list.
  await expect(noteRow(page, 'Alpha plan').locator('mark.search-hit').first()).toBeVisible();
  await search(page, '"release party"', ['Gamma notes']);
  await search(page, 'tag:work', ['Alpha plan']);
  await search(page, '#home', ['Beta list']);
  await search(page, 'release -tag:work', ['Gamma notes']);
  await search(page, 'is:pinned', ['Gamma notes']);
  await search(page, 'is:todo', ['Beta list']);
  await search(page, 'title:beta', ['Beta list']);
  await search(page, 'milk OR party', ['Beta list', 'Gamma notes']);
  await search(page, '(tag:work OR tag:home) -milk', ['Alpha plan']);
  await search(page, 'is:untagged', ['Gamma notes']);
  await search(page, 'nothingmatchesthis', []);
  await expect(page.getByText('No notes match “nothingmatchesthis”.')).toBeVisible();

  // A malformed filter is flagged, not silently ignored.
  await page.getByRole('searchbox', { name: 'Search notes' }).fill('is:bogus');
  await expect(page.getByLabel('Search problem')).toBeVisible();

  await search(page, '', ['Alpha plan', 'Beta list', 'Gamma notes']);
});

test('save a search as a smart folder', async ({ page, account }) => {
  void account;
  await newNote(page, 'Work one', '#work alpha');
  await newNote(page, 'Home one', '#home beta');
  await page.getByRole('searchbox', { name: 'Search notes' }).fill('tag:work');
  await expect(page.getByRole('region', { name: 'Notes' }).getByRole('listitem')).toHaveCount(1);
  await runCommand(page, 'Save Search as Smart Folder…');
  const dialog = page.getByRole('dialog', { name: 'New Smart Folder' });
  await expect(dialog.getByLabel('Search')).toHaveValue('tag:work');
  await dialog.getByLabel('Name').fill('Work stuff');
  await dialog.getByRole('button', { name: 'Create Smart Folder' }).click();
  await page.getByRole('searchbox', { name: 'Search notes' }).fill('');
  const sidebar = page.getByRole('navigation', { name: 'Library' });
  await sidebar.getByRole('button', { name: 'Work stuff' }).click();
  await expect(page.getByRole('region', { name: 'Notes' }).getByRole('listitem')).toHaveCount(1);
  await expect(noteRow(page, 'Work one')).toBeVisible();
});
