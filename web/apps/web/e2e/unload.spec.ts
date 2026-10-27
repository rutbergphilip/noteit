import { editorOf, expect, expectSaved, newNote, noteRow, test, unlockLibrary } from './fixtures';

// An edit typed just before the tab goes away is flushed at once instead of after the 600 ms debounce, and while
// that save is on its way beforeunload asks to stay.

test('closing the tab right after typing asks to stay, then keeps the edit when you leave', async ({ page, context, account, browserName }) => {
  // WebKit stops the page's worker as soon as "Leave" is accepted and runs nothing while the prompt is up, so the
  // flushed save never lands (it doesn't with the prompt held for 1.5 s either). Chromium and Firefox finish it.
  // Staying (the next test) is the safe answer there; tracked in the E2E report.
  test.fail(browserName === 'webkit', 'WebKit drops the in-flight save when Leave is accepted');
  void account;
  await newNote(page, 'Closing', 'first line');
  await page.keyboard.press('Enter');
  await page.keyboard.type('typed right before closing');
  const dialog = page.waitForEvent('dialog');
  const closed = page.close({ runBeforeUnload: true });
  const d = await dialog;
  expect(d.type()).toBe('beforeunload');
  await d.accept();
  await closed;

  const again = await context.newPage();
  await again.goto('/');
  await unlockLibrary(again);
  await noteRow(again, 'Closing').click();
  await expect(editorOf(again)).toContainText('typed right before closing', { timeout: 5_000 });
});

test('staying on the beforeunload prompt lets the save finish', async ({ page, context, account }) => {
  void account;
  await newNote(page, 'Staying', 'first line');
  await page.keyboard.press('Enter');
  await page.keyboard.type('typed right before closing');
  const dialog = page.waitForEvent('dialog');
  await page.close({ runBeforeUnload: true });
  await (await dialog).dismiss();
  await expectSaved(page);
  await page.close();

  const again = await context.newPage();
  await again.goto('/');
  await unlockLibrary(again);
  await noteRow(again, 'Staying').click();
  await expect(editorOf(again)).toContainText('typed right before closing');
});

test('reloading right after typing keeps the edit', async ({ page, account }) => {
  void account;
  await newNote(page, 'Reloading', 'first line');
  await page.keyboard.press('Enter');
  await page.keyboard.type('typed right before reloading');
  page.on('dialog', (d) => void d.accept());
  await page.reload();
  await unlockLibrary(page);
  await noteRow(page, 'Reloading').click();
  await expect(editorOf(page)).toContainText('typed right before reloading');
});
