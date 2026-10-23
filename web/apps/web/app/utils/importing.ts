/**
 * Import Markdown, text files or a whole folder (native MarkdownImporter): each `.md`, `.markdown` or `.txt` file
 * becomes a note; a folder's subfolders become nested notebooks, loose files go to "Imported". Images and files the
 * Markdown names are read from the chosen files by their relative path.
 */
import { toIsoSeconds } from '@noteit/core';
import { importMarkdown, noteIDForTitle } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

const TEXT = /\.(md|markdown|mdown|txt)$/i;
const MAX_NOTEBOOK_DEPTH = 5;

/** `a/b/../c.png` relative to `base`, as a path among the chosen files. */
function joinPath(base: string, rel: string): string {
  const parts = [...base.split('/').filter(Boolean)];
  for (const seg of rel.split('/')) {
    if (seg === '..') parts.pop();
    else if (seg && seg !== '.') parts.push(seg);
  }
  return parts.join('/');
}

export function pickImport(folder: boolean): void {
  const input = document.createElement('input');
  input.type = 'file';
  input.multiple = true;
  if (folder) input.webkitdirectory = true;
  else input.accept = '.md,.markdown,.mdown,.txt,text/markdown,text/plain,image/*';
  input.onchange = () => void importFiles([...(input.files ?? [])]);
  input.click();
}

export async function importFiles(files: File[]): Promise<void> {
  const { state, client, refresh, toast } = useNoteit();
  const path = (f: File) => (f as File & { webkitRelativePath?: string }).webkitRelativePath || f.name;
  const byPath = new Map(files.map((f) => [path(f), f]));
  const notes = files.filter((f) => TEXT.test(f.name)).sort((a, b) => path(a).localeCompare(path(b), undefined, { numeric: true }));
  if (!notes.length) return toast('Choose Markdown (.md) or text files to import.', 'error');
  const bytes = new Map<string, Uint8Array>();
  for (const [p, f] of byPath) if (!TEXT.test(f.name) && f.size <= 26_214_400) bytes.set(p, new Uint8Array(await f.arrayBuffer()));

  const notebookFor = async (folders: string[]): Promise<string> => {
    let parent: string | undefined;
    for (const name of (folders.length ? folders : ['Imported']).slice(0, MAX_NOTEBOOK_DEPTH)) {
      const existing = state.notebooks.find((n) => (n.parent ?? undefined) === parent && n.name.trim().toLowerCase() === name.trim().toLowerCase());
      parent = existing?.id ?? (await client().createNotebook({ name: name.trim() || 'Imported', colorHex: '#007AFF', symbol: 'folder', ...(parent ? { parent } : {}) }));
      if (!existing) await refresh();
    }
    return parent!;
  };

  let imported = 0;
  let missing = 0;
  let skipped = 0;
  for (const file of notes) {
    const p = path(file);
    const dir = p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '';
    // A chosen folder is the top notebook; with loose files there's none, so they go to "Imported".
    const folders = dir ? dir.split('/') : [];
    let text: string;
    try {
      text = await file.text();
    } catch {
      skipped += 1;
      continue;
    }
    const note = importMarkdown(text, {
      fallbackTitle: file.name.replace(TEXT, ''),
      txt: /\.txt$/i.test(file.name),
      read: (rel) => bytes.get(joinPath(dir, decodeURI(rel))) ?? bytes.get(joinPath(dir, rel)),
      resolveNoteLink: (title) => noteIDForTitle(state.notes, title),
    });
    missing += note.missingAttachments;
    const modified = new Date(file.lastModified || Date.now());
    await client().createNote({
      notebookID: await notebookFor(folders),
      container: note.body,
      createdAt: toIsoSeconds(note.created ?? modified),
      updatedAt: toIsoSeconds(note.updated ?? modified),
      isPinned: note.pinned,
    });
    imported += 1;
  }
  await refresh();
  const extra = [missing ? `${missing} image${missing === 1 ? '' : 's'} not found` : '', skipped ? `${skipped} file${skipped === 1 ? '' : 's'} unreadable` : ''].filter(Boolean).join(', ');
  toast(`Imported ${imported} note${imported === 1 ? '' : 's'}${extra ? ` (${extra})` : ''}`, 'success');
}
