import { editorOf, expect, expectSaved, newNote, noteRow, test } from './fixtures';

test('[[wiki links]], backlinks, and updating link text when the target is renamed', async ({ page, account }) => {
  void account;
  await newNote(page, 'Target', 'the linked note');
  await newNote(page, 'Source');
  await page.keyboard.press('Enter');
  await page.keyboard.type('See [[Targ');
  // The `[[` list offers the note.
  await expect(page.getByRole('listbox', { name: 'Link to note' }).getByRole('option', { name: 'Target' })).toBeVisible();
  await page.keyboard.type('et]] for details');
  const link = editorOf(page).locator('a', { hasText: 'Target' });
  await expect(link).toHaveAttribute('href', /^noteit:\/\/note\/[0-9A-F-]{36}$/);
  await expectSaved(page);

  // Links and Outline: the outgoing link here, the backlink on the target.
  await page.getByRole('button', { name: 'Links and Outline' }).click();
  const panel = page.getByRole('complementary', { name: 'Links and Outline' });
  await expect(panel.getByRole('button', { name: /Target/ })).toBeVisible();
  await noteRow(page, 'Target').click();
  await expect(panel.getByRole('button', { name: /Source/ })).toContainText('See Target for details');

  // Rename the target: after a pause the editor offers to update the link text in Source.
  const ed = editorOf(page);
  await ed.getByText('Target', { exact: true }).click();
  await page.keyboard.press('End');
  await page.keyboard.type(' Renamed');
  await expect(page.getByText('1 note links here as “Target”. Update the link to “Target Renamed”?')).toBeVisible({ timeout: 15_000 });
  await page.getByRole('button', { name: 'Update', exact: true }).click();
  await expect(page.getByText('Updated 1 link.')).toBeVisible();
  await noteRow(page, 'Source').click();
  await expect(editorOf(page).locator('a')).toHaveText('Target Renamed');
  await expect(editorOf(page)).toContainText('See Target Renamed for details');
});
