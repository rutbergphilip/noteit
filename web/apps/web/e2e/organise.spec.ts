import { editorOf, expect, expectSaved, newNote, noteRow, runCommand, test } from './fixtures';
import type { Page } from '@playwright/test';

/** The browser's local date as yyyy-MM-dd, `offset` days from today. */
const localDay = (page: Page, offset = 0) =>
  page.evaluate((o) => {
    const d = new Date();
    d.setDate(d.getDate() + o);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }, offset);

test('tasks: checklist items with @due show in Tasks, and checking one there updates the note', async ({ page, account }) => {
  void account;
  await newNote(page, 'Chores');
  await page.keyboard.press('Enter');
  await page.keyboard.type('[ ] pay rent @due(tomorrow)');
  // `@due(tomorrow)` becomes a date as its `)` is typed.
  const tomorrow = await localDay(page, 1);
  await expect(editorOf(page)).toContainText(`pay rent @due(${tomorrow})`);
  await page.keyboard.press('Enter');
  await page.keyboard.type('water plants');
  await expectSaved(page);

  await page.getByRole('navigation', { name: 'Library' }).getByRole('button', { name: 'Tasks' }).click();
  const tasks = page.getByRole('listbox', { name: 'Tasks' });
  await expect(tasks.getByRole('option')).toHaveCount(2);
  const rent = tasks.getByRole('option', { name: /pay rent/ });
  await expect(rent).toContainText('Chores');
  await expect(tasks.getByRole('group', { name: 'Upcoming' }).getByRole('option')).toHaveText([/pay rent/]);
  await expect(tasks.getByRole('group', { name: 'No Date' }).getByRole('option')).toHaveText([/water plants/]);
  await rent.getByRole('checkbox', { name: 'Mark done' }).click();
  await expect(tasks.getByRole('option')).toHaveCount(1);

  // The note shows it checked.
  await page.getByRole('navigation', { name: 'Library' }).getByRole('button', { name: /All Notes/ }).click();
  await noteRow(page, 'Chores').click();
  await expect(editorOf(page).locator('.ni-li-task').filter({ hasText: 'pay rent' })).toHaveClass(/is-checked/);
  await expect(editorOf(page).locator('.ni-li-task').filter({ hasText: 'water plants' })).not.toHaveClass(/is-checked/);
});

test("templates fill in {{title}} and {{date}}; today's note is made once", async ({ page, account }) => {
  void account;
  await runCommand(page, 'New Template');
  await expect(editorOf(page)).toBeFocused();
  await page.keyboard.type('Standup');
  await page.keyboard.press('Enter');
  await page.keyboard.type('Notes for {{title}} on {{date}}');
  await expectSaved(page);
  const sidebar = page.getByRole('navigation', { name: 'Library' });
  await expect(sidebar.getByRole('button', { name: /Templates/ })).toBeVisible();

  await sidebar.getByRole('button', { name: /All Notes/ }).click();
  await runCommand(page, 'New Note from Template…');
  const picker = page.getByRole('dialog', { name: 'New Note from Template' });
  await picker.getByRole('option', { name: /Standup/ }).click();
  const today = await localDay(page);
  await expect(editorOf(page)).toContainText(`on ${today}`);
  await expect(editorOf(page)).not.toContainText('{{date}}');

  // Today's note: in Daily Notes, titled with the date; a second click opens the same note.
  await sidebar.getByRole('button', { name: 'Today' }).click();
  await expect(editorOf(page)).toContainText(today);
  await expect(sidebar.getByRole('button', { name: /Daily Notes/ })).toContainText('1');
  await sidebar.getByRole('button', { name: /All Notes/ }).click();
  await sidebar.getByRole('button', { name: 'Today' }).click();
  await expect(sidebar.getByRole('button', { name: /Daily Notes/ })).toContainText('1');
});
