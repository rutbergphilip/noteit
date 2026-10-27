import { editorOf, expect, expectSaved, newNote, noteRow, test, unlockLibrary } from './fixtures';

test('notes and notebooks: create, edit, move, trash, recover, and they survive a reload', async ({ page, account }) => {
  void account;
  // A notebook from the sidebar.
  await page.getByRole('button', { name: 'New Notebook' }).click();
  const dialog = page.getByRole('dialog', { name: 'New Notebook' });
  await dialog.getByLabel('Name').fill('Projects');
  await dialog.getByRole('button', { name: 'Create Notebook' }).click();
  await expect(dialog).toBeHidden();
  const sidebar = page.getByRole('navigation', { name: 'Library' });
  await expect(sidebar.getByRole('button', { name: /Projects/ })).toBeVisible();

  await newNote(page, 'Groceries', 'Milk and eggs');
  await expect(noteRow(page, 'Groceries')).toContainText('Milk and eggs');

  // Edit: the title follows the first line.
  const ed = editorOf(page);
  await ed.getByText('Groceries').click();
  await page.keyboard.press('End');
  await page.keyboard.type(' list');
  await expectSaved(page);
  await expect(noteRow(page, 'Groceries list')).toBeVisible();

  // Move it into the notebook from the editor's notebook menu.
  await page.getByRole('combobox', { name: 'Notebook' }).click();
  await page.getByRole('option', { name: 'Projects' }).click();
  await sidebar.getByRole('button', { name: /Projects/ }).click();
  await expect(page.getByRole('heading', { level: 1, name: 'Projects' })).toBeVisible();
  await expect(noteRow(page, 'Groceries list')).toBeVisible();
  await expect(sidebar.getByRole('button', { name: /Projects/ })).toContainText('1');

  // Trash, then recover from Recently Deleted.
  await page.getByRole('button', { name: 'Move to Recently Deleted' }).click();
  await expect(noteRow(page, 'Groceries list')).toHaveCount(0);
  await sidebar.getByRole('button', { name: /Recently Deleted/ }).click();
  await noteRow(page, 'Groceries list').click();
  await page.getByRole('button', { name: 'Recover' }).click();
  await expect(noteRow(page, 'Groceries list')).toHaveCount(0);
  await sidebar.getByRole('button', { name: /Projects/ }).click();
  await expect(noteRow(page, 'Groceries list')).toBeVisible();

  // A reload locks the library; unlocking shows the same notes and notebook from the encrypted store.
  await page.reload();
  await unlockLibrary(page);
  await sidebar.getByRole('button', { name: /Projects/ }).click();
  await noteRow(page, 'Groceries list').click();
  await expect(editorOf(page)).toContainText('Milk and eggs');
});

test('delete for good from Recently Deleted', async ({ page, account }) => {
  void account;
  await newNote(page, 'Scratch', 'temporary');
  await page.getByRole('button', { name: 'Move to Recently Deleted' }).click();
  const sidebar = page.getByRole('navigation', { name: 'Library' });
  await sidebar.getByRole('button', { name: /Recently Deleted/ }).click();
  await noteRow(page, 'Scratch').click();
  await page.getByRole('button', { name: 'Delete Now' }).click();
  const confirm = page.getByRole('alertdialog').or(page.getByRole('dialog'));
  await confirm.getByRole('button', { name: /Delete/ }).last().click();
  await expect(page.getByText('Nothing in Recently Deleted.')).toBeVisible();
});

test('pin from the row menu puts the note in Pinned', async ({ page, account }) => {
  void account;
  await newNote(page, 'Important', 'pin me');
  await newNote(page, 'Other', 'not pinned');
  await noteRow(page, 'Important').click({ button: 'right' });
  await page.getByRole('menuitem', { name: 'Pin' }).click();
  await page.getByRole('navigation', { name: 'Library' }).getByRole('button', { name: /^Pinned/ }).click();
  await expect(noteRow(page, 'Important')).toBeVisible();
  await expect(noteRow(page, 'Other')).toHaveCount(0);
});

// Regression: an edit typed less than the 600 ms save debounce before switching notes was lost, because useEditor
// destroys the editor before the component's unmount flush could read it.
test('switching notes right after typing keeps the edit', async ({ page, account }) => {
  void account;
  await newNote(page, 'First', 'body');
  await page.keyboard.press('Enter');
  await page.keyboard.type('typed just before switching');
  await page.getByRole('button', { name: 'New note', exact: true }).click();
  await page.keyboard.type('Second');
  await noteRow(page, 'First').click();
  await expect(editorOf(page)).toContainText('typed just before switching');
});
