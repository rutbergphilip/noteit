/**
 * Import, as native's Import… sheet: Markdown and text files or a folder of them (native MarkdownImporter), Bear's
 * TextBundles (`.textbundle` folders, `.textpack` zips), Evernote `.enex` exports (EvernoteImporter) and Notion's
 * Markdown & CSV export, zipped or unzipped (NotionImporter). Markdown folders become nested notebooks and loose
 * files go to "Imported"; each `.enex` becomes a new notebook (subfolders of a chosen folder as its parents); a
 * Notion top-level page with subpages becomes a notebook, other pages go to "Notion".
 */
import { newUuid, toIsoSeconds } from '@noteit/core';
import {
  evernoteBody,
  importMarkdown,
  ImportTags,
  noteIDForTitle,
  NOTION_HTML_EXPORT,
  notionPageBody,
  notionPages,
  notionTableBody,
  readEnex,
  searchFold,
  standardZipLimits,
  textBundleDates,
  textBundleTextPath,
  textPackBundle,
  unzipArchive,
  ZipTooLargeError,
  type BodyContainer,
  type ImportedNote,
  type NotionFile,
  type ZipLimits,
} from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';
import { NOTEBOOK_COLORS } from '~/utils/notebooks';

const TEXT = /\.(md|markdown|mdown|txt)$/i;
const BUNDLE = /\.textbundle$/i;
const NOTION_NAME = /\s[0-9a-f]{32}(?:_all)?(?:\.(?:md|csv))?$/i;
/** Notebooks nest this deep; deeper folders are named `Folder / Subfolder` inside the deepest (native NotebookTree.maxDepth). */
const MAX_NOTEBOOK_DEPTH = 5;
const MAX_FILE_BYTES = 26_214_400;

/** What one import did, for the summary (native ImportReport). */
interface ImportReport {
  notesImported: number;
  notebookIDs: Set<string>;
  attachmentsSkipped: number;
  filesSkipped: number;
  notesSkipped: number;
  tagsSkipped: number;
  encryptedSectionsSkipped: number;
  archivesSkipped: string[];
  truncatedTables: string[];
}

const newReport = (): ImportReport => ({ notesImported: 0, notebookIDs: new Set(), attachmentsSkipped: 0, filesSkipped: 0, notesSkipped: 0, tagsSkipped: 0, encryptedSectionsSkipped: 0, archivesSkipped: [], truncatedTables: [] });

const count = (n: number, one: string, many: string) => `${n.toLocaleString()} ${n === 1 ? one : many}`;
const list = (items: string[]) => (items.length > 1 ? `${items.slice(0, -1).join(', ')} and ${items.at(-1)}` : (items[0] ?? ''));

/** "Imported 132 notes into 6 notebooks. Skipped 3 attachments." (native ImportReport.summary) */
function summary(r: ImportReport): string {
  const parts: string[] = [];
  const notes = count(r.notesImported, 'note', 'notes');
  parts.push(r.notebookIDs.size ? `Imported ${notes} into ${count(r.notebookIDs.size, 'notebook', 'notebooks')}.` : `Imported ${notes}.`);
  const skipped: string[] = [];
  if (r.attachmentsSkipped) skipped.push(count(r.attachmentsSkipped, 'attachment', 'attachments'));
  if (r.filesSkipped) skipped.push(count(r.filesSkipped, 'unreadable file', 'unreadable files'));
  if (r.notesSkipped) skipped.push(count(r.notesSkipped, 'unreadable note', 'unreadable notes'));
  if (r.tagsSkipped) skipped.push(count(r.tagsSkipped, 'tag with no letters or numbers', 'tags with no letters or numbers'));
  if (skipped.length) parts.push(`Skipped ${list(skipped)}.`);
  const archive = r.archivesSkipped[0];
  if (archive) parts.push(r.archivesSkipped.length === 1 ? `Couldn't open “${archive}”, so its pages weren't imported.` : `Couldn't open ${r.archivesSkipped.length} ZIP files (“${archive}” and others), so their pages weren't imported.`);
  if (r.encryptedSectionsSkipped) parts.push(r.encryptedSectionsSkipped === 1 ? '1 note had encrypted sections that were skipped.' : `${r.encryptedSectionsSkipped} notes had encrypted sections that were skipped.`);
  const table = r.truncatedTables[0];
  if (table) parts.push(r.truncatedTables.length === 1 ? `Only the first 1,000 rows of “${table}” were imported.` : `Only the first 1,000 rows of ${r.truncatedTables.length} tables were imported.`);
  return parts.join(' ');
}

/** `a/b/../c.png` relative to `base`, as a path among the chosen files. */
function joinPath(base: string, rel: string): string {
  const parts = [...base.split('/').filter(Boolean)];
  for (const seg of rel.split('/')) {
    if (seg === '..') parts.pop();
    else if (seg && seg !== '.') parts.push(seg);
  }
  return parts.join('/');
}

const dirOf = (p: string) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '');
const baseName = (p: string) => p.slice(p.lastIndexOf('/') + 1);
const stemOf = (name: string) => (name.lastIndexOf('.') > 0 ? name.slice(0, name.lastIndexOf('.')) : name);
const decodeText = (bytes: Uint8Array) => {
  const s = new TextDecoder().decode(bytes);
  return s.startsWith('﻿') ? s.slice(1) : s;
};

export function pickImport(folder: boolean): void {
  const input = document.createElement('input');
  input.type = 'file';
  input.multiple = true;
  if (folder) input.webkitdirectory = true;
  else input.accept = '.md,.markdown,.mdown,.txt,.enex,.zip,.textpack,text/markdown,text/plain,application/zip,image/*';
  input.onchange = () => void importFiles([...(input.files ?? [])]);
  input.click();
}

export async function importFiles(files: File[]): Promise<void> {
  const { state, client, refresh, toast } = useNoteit();
  const path = (f: File) => (f as File & { webkitRelativePath?: string }).webkitRelativePath || f.name;
  const report = newReport();

  // MARK: notebooks

  /** An existing notebook with this name among the children of `parent`, or a new one there (Markdown imports). */
  const notebookFor = async (folders: string[]): Promise<string> => {
    let parent: string | undefined;
    for (const name of (folders.length ? folders : ['Imported']).slice(0, MAX_NOTEBOOK_DEPTH)) {
      const existing = state.notebooks.find((n) => (n.parent ?? undefined) === parent && n.name.trim().toLowerCase() === name.trim().toLowerCase());
      parent = existing?.id ?? (await client().createNotebook({ name: name.trim() || 'Imported', colorHex: '#007AFF', symbol: 'folder', ...(parent ? { parent } : {}) }));
      if (!existing) await refresh();
    }
    return parent!;
  };
  /** A new notebook named `name`, or "name 2", "name 3"… when one beside it has that name (native newNotebookForImport). */
  const newNotebook = async (name: string, parent?: string): Promise<string> => {
    const taken = new Set(state.notebooks.filter((n) => (n.parent ?? undefined) === parent).map((n) => n.name.trim().toLowerCase()));
    let candidate = name;
    for (let n = 2; taken.has(candidate.toLowerCase()); n++) candidate = `${name} ${n}`;
    const color = NOTEBOOK_COLORS[state.notebooks.length % NOTEBOOK_COLORS.length]!.hex;
    const id = await client().createNotebook({ name: candidate, colorHex: color, symbol: 'folder', ...(parent ? { parent } : {}) });
    await refresh();
    return id;
  };
  /** The notebooks one run makes (native ImportNotebooks): never one that was there before; the same path, the same new notebook. */
  const made = new Map<string, string>();
  const runNotebook = async (path: string[]): Promise<string> => {
    const names = (path.length ? path : ['Imported']).map((n) => n.trim() || 'Imported');
    const nested = [...names.slice(0, MAX_NOTEBOOK_DEPTH - 1), names.slice(MAX_NOTEBOOK_DEPTH - 1).join(' / ')].filter(Boolean);
    let parent: string | undefined;
    for (let depth = 0; depth < nested.length; depth++) {
      const key = nested
        .slice(0, depth + 1)
        .map((n) => n.toLowerCase())
        .join('/');
      parent = made.get(key) ?? (await newNotebook(nested[depth]!, parent));
      made.set(key, parent);
    }
    return parent!;
  };

  const create = async (opts: { id?: string; notebookID: string; container: BodyContainer; created?: Date; updated?: Date; pinned?: boolean }): Promise<string> => {
    const updated = opts.updated ?? opts.created ?? new Date();
    const created = opts.created && opts.created < updated ? opts.created : updated;
    const id = await client().createNote({
      ...(opts.id ? { id: opts.id } : {}),
      notebookID: opts.notebookID,
      container: opts.container,
      createdAt: toIsoSeconds(created),
      updatedAt: toIsoSeconds(updated),
      isPinned: !!opts.pinned,
    });
    report.notesImported += 1;
    report.notebookIDs.add(opts.notebookID);
    return id;
  };

  // MARK: sorting the chosen files

  const all = files.filter((f) => !path(f).split('/').some((p) => p.startsWith('.') || p === '__MACOSX'));
  const enex = all.filter((f) => /\.enex$/i.test(f.name));
  const zips = all.filter((f) => /\.zip$/i.test(f.name));
  const packs = all.filter((f) => /\.textpack$/i.test(f.name));
  const inBundle = (f: File) => path(f).split('/').slice(0, -1).some((p) => BUNDLE.test(p));
  const rest = all.filter((f) => !enex.includes(f) && !zips.includes(f) && !packs.includes(f));
  // An unzipped Notion export: its pages are named with their 32-character ids.
  const notionFolder = rest.some((f) => /\.(md|csv)$/i.test(f.name) && path(f).split('/').some((p) => NOTION_NAME.test(p)));
  if (!all.length || (!enex.length && !zips.length && !packs.length && !rest.some((f) => TEXT.test(f.name) || /\.csv$/i.test(f.name)))) {
    return toast('Choose Markdown or text files, TextBundles, Evernote .enex files or a Notion export to import.', 'error');
  }

  try {
    for (const file of enex) await importEvernote(file);
    for (const zip of zips) await importNotion([{ name: zip.name, files: undefined, zip: new Uint8Array(await zip.arrayBuffer()) }]);
    if (notionFolder) {
      const map = new Map<string, Uint8Array>();
      for (const f of rest) if (f.size <= MAX_FILE_BYTES) map.set(path(f), new Uint8Array(await f.arrayBuffer()));
      await importNotion([{ name: 'Notion', files: map }]);
    } else {
      await importMarkdownFiles(rest.filter((f) => !inBundle(f)));
      await importBundles(rest.filter(inBundle));
    }
    for (const pack of packs) await importTextPack(pack);
  } catch (e) {
    await refresh();
    return toast(e instanceof Error ? e.message : 'Could not import', 'error');
  }
  await refresh();
  toast(summary(report), 'success');

  // MARK: Evernote

  async function importEvernote(file: File): Promise<void> {
    let text: string;
    try {
      text = await file.text();
    } catch {
      report.filesSkipped += 1;
      return;
    }
    const { notes, isExport } = readEnex(text);
    if (!notes.length && !isExport) {
      report.filesSkipped += 1;
      return;
    }
    // A chosen folder's subfolders (Evernote stacks) become parent notebooks of the file's notebook.
    const p = path(file).split('/');
    const notebookPath = [...p.slice(1, -1), stemOf(p.at(-1)!)];
    // Links to other notes in the export point at the first imported note with that title.
    const ids = notes.map((n) => (n ? newUuid() : undefined));
    const titles = new Map<string, string>();
    notes.forEach((n, i) => {
      const key = n ? searchFold((n.title || 'Untitled').trim()) : '';
      if (n && !titles.has(key)) titles.set(key, ids[i]!);
    });
    const tags = new ImportTags();
    let notebookID: string | undefined;
    for (const [i, n] of notes.entries()) {
      if (!n) {
        report.notesSkipped += 1;
        continue;
      }
      const title = n.title || 'Untitled';
      const r = evernoteBody(n, title, tags, { resolveTitle: (t) => titles.get(searchFold(t.trim())) });
      report.attachmentsSkipped += r.attachmentsSkipped;
      if (r.encrypted) report.encryptedSectionsSkipped += 1;
      notebookID ??= await runNotebook(notebookPath);
      await create({ id: ids[i]!, notebookID, container: r.body, ...(n.created ? { created: n.created } : {}), ...(n.updated ? { updated: n.updated } : {}) });
    }
    report.tagsSkipped += tags.dropped.size;
  }

  // MARK: Notion

  /** The export's roots: the chosen folder or the unzipped archive, plus each ZIP at its top unzipped (native contentRoots). */
  async function importNotion(sources: { name: string; files?: Map<string, Uint8Array>; zip?: Uint8Array }[]): Promise<void> {
    const limits: ZipLimits = standardZipLimits();
    const roots: Map<string, Uint8Array>[] = [];
    for (const s of sources) {
      const root = s.files ?? unzipArchive(s.zip!, s.name, limits);
      roots.push(root);
      const parts = [...root.keys()].filter((k) => !k.includes('/') && /\.zip$/i.test(k)).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
      for (const part of parts) {
        try {
          roots.push(unzipArchive(root.get(part)!, part, limits));
        } catch (e) {
          if (e instanceof ZipTooLargeError) throw e;
          report.archivesSkipped.push(part);
        }
      }
    }
    const notionFiles: NotionFile[] = roots.flatMap((root, i) => [...root.keys()].map((p) => ({ path: p, root: i })));
    const { pages, sawHTML } = notionPages(notionFiles);
    if (!pages.length) throw new Error(sawHTML ? NOTION_HTML_EXPORT : report.archivesSkipped[0] ? `“${report.archivesSkipped[0]}” couldn't be opened. Unzip it and choose the folder instead.` : 'No notes were found to import.');
    const ids = new Map(pages.map((p) => [p.key, newUuid()]));
    /** A file inside the export; a page's own files may sit in another part of a split export. */
    const read = (root: number, rel: string) => {
      const own = roots[root]!.get(rel);
      if (own) return own.length <= MAX_FILE_BYTES ? own : undefined;
      for (const other of roots) {
        const hit = other.get(rel);
        if (hit) return hit.length <= MAX_FILE_BYTES ? hit : undefined;
      }
      return undefined;
    };
    const notebooks = new Map<string, string>();
    for (const page of pages) {
      const bytes = roots[page.root]!.get(page.path);
      const text = bytes ? decodeText(bytes) : undefined;
      let body: BodyContainer | undefined;
      if (text !== undefined && page.isTable) {
        const t = notionTableBody(text, page.title);
        if (t?.truncated) report.truncatedTables.push(page.title);
        body = t?.body;
      } else if (text !== undefined) {
        const dir = dirOf(page.path);
        const r = notionPageBody(text, page, { ids, read: (rel) => read(page.root, joinPath(dir, rel)) });
        report.attachmentsSkipped += r.missingAttachments;
        body = r.body;
      }
      if (!body) {
        report.filesSkipped += 1;
        ids.delete(page.key);
        continue;
      }
      let notebookID = notebooks.get(page.notebookKey);
      if (!notebookID) {
        notebookID = await newNotebook(page.notebook);
        notebooks.set(page.notebookKey, notebookID);
      }
      await create({ id: ids.get(page.key)!, notebookID, container: body });
    }
  }

  // MARK: Markdown and TextBundle

  async function importMarkdownFiles(chosen: File[]): Promise<void> {
    const byPath = new Map(chosen.map((f) => [path(f), f]));
    const notes = chosen.filter((f) => TEXT.test(f.name)).sort((a, b) => path(a).localeCompare(path(b), undefined, { numeric: true }));
    if (!notes.length) return;
    const bytes = new Map<string, Uint8Array>();
    for (const [p, f] of byPath) if (!TEXT.test(f.name) && f.size <= MAX_FILE_BYTES) bytes.set(p, new Uint8Array(await f.arrayBuffer()));
    for (const file of notes) {
      const p = path(file);
      const dir = dirOf(p);
      let text: string;
      try {
        text = await file.text();
      } catch {
        report.filesSkipped += 1;
        continue;
      }
      const note = importMarkdown(text, {
        fallbackTitle: file.name.replace(TEXT, ''),
        txt: /\.txt$/i.test(file.name),
        read: (rel) => bytes.get(joinPath(dir, decodeURI(rel))) ?? bytes.get(joinPath(dir, rel)),
        resolveNoteLink: (title) => noteIDForTitle(state.notes, title),
      });
      // A chosen folder is the top notebook; with loose files there's none, so they go to "Imported".
      await saveMarkdown(note, dir ? dir.split('/') : [], new Date(file.lastModified || Date.now()));
    }
  }

  async function saveMarkdown(note: ImportedNote, folders: string[], modified: Date, info: { created?: Date; modified?: Date } = {}): Promise<void> {
    report.attachmentsSkipped += note.missingAttachments;
    const created = note.created ?? info.created ?? modified;
    const updated = note.updated ?? info.modified ?? modified;
    await create({ notebookID: await notebookFor(folders), container: note.body, created, updated, pinned: note.pinned });
  }

  /** One TextBundle: its text, its assets and Bear's dates (native importBundle). */
  async function importBundle(name: string, files: Map<string, Uint8Array>, folders: string[], modified: Date): Promise<void> {
    const textPath = textBundleTextPath([...files.keys()]);
    const raw = textPath ? files.get(textPath) : undefined;
    if (!textPath || !raw) {
      report.filesSkipped += 1;
      return;
    }
    const note = importMarkdown(decodeText(raw), {
      fallbackTitle: stemOf(name),
      txt: /\.txt$/i.test(textPath),
      read: (rel) => {
        const hit = files.get(joinPath('', decodeURI(rel))) ?? files.get(joinPath('', rel));
        return hit && hit.length <= MAX_FILE_BYTES ? hit : undefined;
      },
      resolveNoteLink: (title) => noteIDForTitle(state.notes, title),
    });
    const info = files.get('info.json');
    await saveMarkdown(note, folders, modified, textBundleDates(info ? decodeText(info) : undefined));
  }

  async function importBundles(chosen: File[]): Promise<void> {
    const bundles = new Map<string, File[]>();
    for (const f of chosen) {
      const parts = path(f).split('/');
      const at = parts.findIndex((p) => BUNDLE.test(p));
      const key = parts.slice(0, at + 1).join('/');
      bundles.set(key, [...(bundles.get(key) ?? []), f]);
    }
    for (const [key, members] of [...bundles].sort(([a], [b]) => a.localeCompare(b, undefined, { numeric: true }))) {
      const map = new Map<string, Uint8Array>();
      for (const f of members) if (f.size <= MAX_FILE_BYTES) map.set(path(f).slice(key.length + 1), new Uint8Array(await f.arrayBuffer()));
      const modified = new Date(Math.max(...members.map((f) => f.lastModified || 0)) || Date.now());
      await importBundle(baseName(key), map, dirOf(key) ? dirOf(key).split('/') : [], modified);
    }
  }

  async function importTextPack(file: File): Promise<void> {
    let files: Map<string, Uint8Array>;
    try {
      files = unzipArchive(new Uint8Array(await file.arrayBuffer()), file.name, standardZipLimits());
    } catch (e) {
      if (e instanceof ZipTooLargeError) throw e;
      report.filesSkipped += 1;
      return;
    }
    const prefix = textPackBundle([...files.keys()]);
    if (prefix === undefined) {
      report.filesSkipped += 1;
      return;
    }
    const inside = new Map([...files].filter(([p]) => p.startsWith(prefix)).map(([p, b]) => [p.slice(prefix.length), b] as const));
    await importBundle(file.name, inside, [], new Date(file.lastModified || Date.now()));
  }
}
