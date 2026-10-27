import { editorOf, expect, expectSaved, newNote, noteRow, test, unlockLibrary } from './fixtures';

test('Markdown as you type: headings, lists, quote, code, divider and inline marks', async ({ page, account }) => {
  void account;
  await newNote(page, 'Markdown');
  const ed = editorOf(page);
  const line = async (text: string) => {
    await page.keyboard.press('Enter');
    await page.keyboard.type(text);
  };
  await line('## Section');
  await expect(ed.locator('h2')).toHaveText('Section');
  await line('- first bullet');
  await expect(ed.locator('.ni-li-bullet .ni-li-content')).toHaveText('first bullet');
  // Return twice leaves the list.
  await page.keyboard.press('Enter');
  await page.keyboard.press('Enter');
  await page.keyboard.type('1. numbered');
  await expect(ed.locator('.ni-li-ordered .ni-li-content')).toHaveText('numbered');
  await page.keyboard.press('Enter');
  await page.keyboard.press('Enter');
  await page.keyboard.type('[ ] a task');
  await expect(ed.locator('.ni-li-task .ni-li-content')).toHaveText('a task');
  await ed.locator('.ni-li-task input[type=checkbox]').click();
  await expect(ed.locator('.ni-li-task')).toHaveClass(/is-checked/);
  await page.keyboard.press('End');
  await page.keyboard.press('Enter');
  await page.keyboard.press('Enter');
  await page.keyboard.type('> quoted');
  await expect(ed.locator('blockquote')).toHaveText('quoted');
  await page.keyboard.press('Enter');
  await page.keyboard.press('Enter');
  await page.keyboard.type('plain **bold** and *italic* and `code` and ~~gone~~ end');
  await expect(ed.locator('strong')).toHaveText('bold');
  await expect(ed.locator('em')).toHaveText('italic');
  await expect(ed.locator('p code')).toHaveText('code');
  await expect(ed.locator('s')).toHaveText('gone');
  await line('---');
  await page.keyboard.press('Enter');
  await expect(ed.locator('hr')).toHaveCount(1);
  await page.keyboard.type('```');
  await page.keyboard.press('Enter');
  await page.keyboard.type('let x = 1');
  await expect(ed.locator('pre.ni-code')).toHaveText('let x = 1');

  // ⌘Z right after a conversion gives back the literal Markdown.
  await page.keyboard.press('ControlOrMeta+a');
  await page.keyboard.press('Delete');
  await page.keyboard.type('# Undo me');
  await expect(ed.locator('h1')).toHaveText('Undo me');
  await expectSaved(page);

  // Formatting survives a reload (the doc went through the encrypted store and back).
  await page.keyboard.press('ControlOrMeta+a');
  await page.keyboard.type('Formatted');
  await page.keyboard.press('Enter');
  await page.keyboard.type('**kept** bold');
  await page.keyboard.press('Enter');
  await page.keyboard.type('- item');
  await expectSaved(page);
  await page.reload();
  await unlockLibrary(page);
  await noteRow(page, 'Formatted').click();
  await expect(editorOf(page).locator('strong')).toHaveText('kept');
  await expect(editorOf(page).locator('.ni-li-bullet .ni-li-content')).toHaveText('item');
});

test('toolbar marks and keyboard shortcuts toggle formatting', async ({ page, account }) => {
  void account;
  await newNote(page, 'Toolbar');
  await page.keyboard.press('Enter');
  await page.keyboard.type('word');
  for (let i = 0; i < 4; i++) await page.keyboard.press('Shift+ArrowLeft');
  // ProseMirror picks up a keyboard selection from the async selectionchange event; let it land first.
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  await page.keyboard.press('ControlOrMeta+b');
  const ed = editorOf(page);
  await expect(ed.locator('strong')).toHaveText('word');
  await page.keyboard.press('ControlOrMeta+i');
  await expect(ed.locator('em')).toHaveText('word');
  const bar = page.getByRole('toolbar', { name: 'Formatting' });
  await expect(bar.getByRole('button', { name: 'Bold' })).toHaveAttribute('aria-pressed', 'true');
  await bar.getByRole('button', { name: 'Bold' }).click();
  await expect(ed.locator('strong')).toHaveCount(0);
  await bar.getByRole('button', { name: 'Clear Formatting' }).click();
  await expect(ed.locator('em')).toHaveCount(0);
  await expectSaved(page);
});
