import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { strFromU8, unzipSync } from 'fflate';
import { editorOf, expect, newNote, noteRow, runCommand, test } from './fixtures';
import type { Page } from '@playwright/test';

async function importFiles(page: Page, files: string[]): Promise<void> {
  const chooser = page.waitForEvent('filechooser');
  await runCommand(page, 'Import…');
  await (await chooser).setFiles(files);
}

test('import Markdown files from an Obsidian vault: titles, front matter tags and [[links]] between them', async ({ page, account }, info) => {
  void account;
  const dir = info.outputPath('vault');
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, 'Alpha.md'), '---\ntags: [obsidian, project]\n---\n# Alpha\n\nSee [[Beta]] for **details**.\n\n- [ ] follow up\n');
  await writeFile(join(dir, 'Beta.md'), '# Beta\n\nThe second note.\n');
  await importFiles(page, [join(dir, 'Alpha.md'), join(dir, 'Beta.md')]);
  await expect(page.getByText('Imported 2 notes into 1 notebook.', { exact: true })).toBeVisible();

  await noteRow(page, 'Alpha').click();
  const ed = editorOf(page);
  await expect(ed.locator('strong')).toHaveText('details');
  // Links to notes in the same import link by title on the web (docs/feature-parity.md).
  await expect(ed.locator('a', { hasText: 'Beta' })).toHaveAttribute('href', 'noteit://note?title=Beta');
  await expect(ed.locator('.ni-li-task')).toContainText('follow up');
  const sidebar = page.getByRole('navigation', { name: 'Library' });
  await expect(sidebar.getByRole('button', { name: '#obsidian' })).toBeVisible();
  await expect(sidebar.getByRole('button', { name: '#project' })).toBeVisible();
});

test('import an Evernote ENEX export', async ({ page, account }, info) => {
  void account;
  const file = info.outputPath('Travel.enex');
  await writeFile(
    file,
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd">
<en-export export-date="20240101T120000Z" application="Evernote" version="10">
<note><title>Packing list</title><created>20240101T120000Z</created><updated>20240102T120000Z</updated><tag>travel</tag>
<content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note><div>Bring <b>passport</b></div><div><en-todo checked="true"/>book hotel</div><div><en-todo/>buy adapter</div></en-note>]]></content></note>
<note><title>Second</title><content><![CDATA[<en-note><div>Just text</div></en-note>]]></content></note>
</en-export>`,
  );
  await importFiles(page, [file]);
  await expect(page.getByText('Imported 2 notes into 1 notebook.', { exact: true })).toBeVisible();
  await noteRow(page, 'Packing list').click();
  const ed = editorOf(page);
  await expect(ed.locator('strong')).toHaveText('passport');
  await expect(ed.locator('.ni-li-task.is-checked')).toContainText('book hotel');
  await expect(ed.locator('.ni-li-task:not(.is-checked)')).toContainText('buy adapter');
  await expect(page.getByRole('navigation', { name: 'Library' }).getByRole('button', { name: '#travel' })).toBeVisible();
});

test('export all notes as a Markdown zip', async ({ page, account }) => {
  void account;
  await page.getByRole('button', { name: 'New Notebook' }).click();
  const dialog = page.getByRole('dialog', { name: 'New Notebook' });
  await dialog.getByLabel('Name').fill('Work');
  await dialog.getByRole('button', { name: 'Create Notebook' }).click();
  await newNote(page, 'Loose note', 'top level **bold**');
  const sidebar = page.getByRole('navigation', { name: 'Library' });
  await sidebar.getByRole('button', { name: /Work/ }).click();
  await newNote(page, 'Filed note', '- one', 'two');

  await sidebar.getByRole('button', { name: /All Notes/ }).click({ button: 'right' });
  await page.getByRole('menuitem', { name: 'Export All Notes' }).click();
  const download = page.waitForEvent('download');
  await page.getByRole('menuitem', { name: 'As Markdown' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toMatch(/\.zip$/);
  const entries = unzipSync(new Uint8Array(await readFile(await file.path())));
  const names = Object.keys(entries);
  const loose = names.find((n) => n.endsWith('Loose note.md'));
  const filed = names.find((n) => n.endsWith('Work/Filed note.md'));
  expect(loose, names.join(', ')).toBeTruthy();
  expect(filed, names.join(', ')).toBeTruthy();
  expect(strFromU8(entries[loose!]!)).toContain('top level **bold**');
  expect(strFromU8(entries[filed!]!)).toMatch(/- one\n- two/);
});
