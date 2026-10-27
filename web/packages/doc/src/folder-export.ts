/**
 * Export a notebook or every note as folders (native NoteExporter.prepareNotebook / prepareAll, ExportNaming and
 * ExportLinkContext): one folder per notebook, nested notebooks as subfolders, one file per note named after its
 * title, Markdown images and files in a `<file name> assets` folder, and links between exported notes pointing at
 * their files. The web writes the folder into a zip.
 */
import { zipSync } from 'fflate';
import { docToHtml, headingSlug } from './html.js';
import { docToMarkdown, escapeMarkdownText } from './markdown.js';
import type { BodyContainer, Inline } from './schema.js';
import { searchFold } from './search.js';

export type FolderExportFormat = 'markdown' | 'html';
export const FOLDER_EXPORT_EXTENSIONS: Record<FolderExportFormat, string> = { markdown: 'md', html: 'html' };
export const ALL_NOTES_FOLDER = 'NoteIt Export';
export const NO_NOTEBOOK_FOLDER = 'No Notebook';
export const EXPORT_NAME_MAX = 120;

export interface ExportNotebook {
  id: string;
  name: string;
  parent?: string;
  sortIndex: number;
}

export interface ExportNote {
  id: string;
  title: string;
  notebookID?: string;
  createdAt: string;
  deletedAt?: string;
}

/** Native NoteMeta.displayTitle. */
export const exportDisplayTitle = (title: string) => title || 'New Note';

const UNSAFE = /[/\\:*?"<>|\uFFFC]/gu;
// CharacterSet.controlCharacters (Cc, Cf), newlines and the Unicode line/paragraph separators become spaces.
const SPACES = /[\p{Cc}\p{Cf}\u2028\u2029\u0085]/gu;

function graphemes(s: string): string[] {
  const Seg = (Intl as unknown as { Segmenter?: new (l?: string, o?: { granularity: string }) => { segment(s: string): Iterable<{ segment: string }> } }).Segmenter;
  return Seg ? [...new Seg(undefined, { granularity: 'grapheme' }).segment(s)].map((x) => x.segment) : Array.from(s);
}

/** `name` without characters that are unsafe in file names (native ExportNaming.sanitized). */
export function sanitizedFileName(name: string, fallback = 'Untitled'): string {
  let s = name.replace(UNSAFE, '').replace(SPACES, ' ');
  s = s.split(/\s+/u).filter(Boolean).join(' ');
  s = s.replace(/^\.+/, '').trim();
  const chars = graphemes(s);
  if (chars.length > EXPORT_NAME_MAX) s = chars.slice(0, EXPORT_NAME_MAX).join('').trim();
  return s || fallback;
}

/** `base[.ext]`, or `base 2[.ext]`… when taken; compared case-insensitively, as on APFS (native ExportNaming.unique). */
export function uniqueFileName(base: string, ext: string, taken: Set<string>): string {
  const name = (n: number) => {
    const stem = n === 1 ? base : `${base} ${n}`;
    return ext ? `${stem}.${ext}` : stem;
  };
  let n = 1;
  while (taken.has(name(n).toLowerCase())) n += 1;
  taken.add(name(n).toLowerCase());
  return name(n);
}

const key = (id: string) => id.toUpperCase();

/** Notebooks as a tree (native NotebookTree): a missing parent makes a notebook top level; a cycle is cut at its lowest id. */
export function notebookTree(notebooks: ExportNotebook[]): { roots: string[]; children: (id: string) => string[] } {
  const byID = new Map<string, ExportNotebook>();
  for (const nb of notebooks) if (!byID.has(key(nb.id))) byID.set(key(nb.id), nb);
  const parents = new Map<string, string>();
  for (const [id, nb] of byID) {
    const p = nb.parent ? key(nb.parent) : undefined;
    if (p && p !== id && byID.has(p)) parents.set(id, p);
  }
  for (const start of [...byID.keys()].sort()) {
    const seen: string[] = [];
    let current: string | undefined = start;
    while (current) {
      const at = seen.indexOf(current);
      if (at >= 0) {
        parents.delete(seen.slice(at).sort()[0]!);
        break;
      }
      seen.push(current);
      current = parents.get(current);
    }
  }
  const order = (a: string, b: string) => {
    const x = byID.get(a)!;
    const y = byID.get(b)!;
    if (x.sortIndex !== y.sortIndex) return x.sortIndex - y.sortIndex;
    const byName = x.name.localeCompare(y.name, undefined, { numeric: true });
    return byName || (a < b ? -1 : a > b ? 1 : 0);
  };
  const children = new Map<string, string[]>();
  const roots: string[] = [];
  for (const id of byID.keys()) {
    const p = parents.get(id);
    if (p) children.set(p, [...(children.get(p) ?? []), id]);
    else roots.push(id);
  }
  for (const list of children.values()) list.sort(order);
  roots.sort(order);
  return { roots, children: (id) => children.get(key(id)) ?? [] };
}

export interface PlannedExportFile {
  note: ExportNote;
  /** Inside the export, starting with its top folder: `NoteIt Export/Work/Plan.md`. */
  path: string;
}

export interface FolderExportPlan {
  format: FolderExportFormat;
  /** The export's top folder, which names the zip. */
  root: string;
  /** Every folder, empty ones too, as paths like `files`'. */
  folders: string[];
  files: PlannedExportFile[];
}

const assetsFolderName = (base: string) => `${base} assets`;
const stripExt = (name: string) => name.slice(0, name.lastIndexOf('.'));

/** The notes that get exported: everything except Recently Deleted (native exportableNotes). */
export const exportableNotes = <T extends ExportNote>(notes: T[]) => notes.filter((n) => !n.deletedAt);

function layout(notebooks: ExportNotebook[], notes: ExportNote[], format: FolderExportFormat, folders: string[], files: PlannedExportFile[]) {
  const tree = notebookTree(notebooks);
  const byID = new Map(notebooks.map((nb) => [key(nb.id), nb] as const));
  const byNotebook = new Map<string, ExportNote[]>();
  for (const n of notes) if (n.notebookID) byNotebook.set(key(n.notebookID), [...(byNotebook.get(key(n.notebookID)) ?? []), n]);
  const folderName = (id: string, taken: Set<string>) => uniqueFileName(sanitizedFileName(byID.get(key(id))?.name ?? '', 'Notebook'), '', taken);
  const prepareFolder = (folder: string, folderNotes: ExportNote[], taken: Set<string>) => {
    folders.push(folder);
    // Oldest first, so the first of several same-named notes keeps the plain name.
    const ordered = [...folderNotes].sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt) || (key(a.id) < key(b.id) ? -1 : key(a.id) > key(b.id) ? 1 : 0));
    for (const note of ordered) {
      const name = uniqueFileName(sanitizedFileName(exportDisplayTitle(note.title)), FOLDER_EXPORT_EXTENSIONS[format], taken);
      if (format === 'markdown') taken.add(assetsFolderName(stripExt(name)).toLowerCase());
      files.push({ note, path: `${folder}/${name}` });
    }
  };
  const prepare = (id: string, folder: string) => {
    const taken = new Set<string>();
    prepareFolder(folder, byNotebook.get(key(id)) ?? [], taken);
    for (const child of tree.children(id)) prepare(child, `${folder}/${folderName(child, taken)}`);
  };
  return { tree, folderName, prepareFolder, prepare };
}

/** One notebook as a folder named after it, its nested notebooks as subfolders (native prepareNotebook). */
export function planNotebookExport(notebookID: string, notebooks: ExportNotebook[], notes: ExportNote[], format: FolderExportFormat): FolderExportPlan {
  const notebook = notebooks.find((nb) => key(nb.id) === key(notebookID));
  const root = sanitizedFileName(notebook?.name ?? '', 'Notebook');
  const folders: string[] = [];
  const files: PlannedExportFile[] = [];
  layout(notebooks, exportableNotes(notes), format, folders, files).prepare(notebookID, root);
  return { format, root, folders, files };
}

/** Every notebook as a folder inside `NoteIt Export`, nested like the notebooks; notes without one in `No Notebook` (native prepareAll). */
export function planAllExport(notebooks: ExportNotebook[], notes: ExportNote[], format: FolderExportFormat): FolderExportPlan {
  const root = ALL_NOTES_FOLDER;
  const kept = exportableNotes(notes);
  const ids = new Set(notebooks.map((nb) => key(nb.id)));
  const folders: string[] = [root];
  const files: PlannedExportFile[] = [];
  const l = layout(notebooks, kept, format, folders, files);
  const taken = new Set<string>();
  for (const id of l.tree.roots) l.prepare(id, `${root}/${l.folderName(id, taken)}`);
  const loose = kept.filter((n) => !n.notebookID || !ids.has(key(n.notebookID)));
  if (loose.length) l.prepareFolder(`${root}/${uniqueFileName(NO_NOTEBOOK_FOLDER, '', taken)}`, loose, new Set());
  return { format, root, folders, files };
}

const lastPart = (path: string) => path.slice(path.lastIndexOf('/') + 1);
const parentPath = (path: string) => path.slice(0, path.lastIndexOf('/'));
const cleaned = (s: string, chars: RegExp) => s.replace(chars, '').replace(/[\n\r\u2028\u2029\u0085]/g, '');
const WIKI_UNSAFE = /[[\]|#^]/g;

/** Native ExportLinkContext.files: exported names, their folders, and `Folder/Name` where a name is used twice. */
export function exportLinkContext(plan: FolderExportPlan, notes: ExportNote[]) {
  const titles = new Map<string, string>();
  for (const n of notes) if (!titles.has(key(n.id))) titles.set(key(n.id), exportDisplayTitle(n.title));
  const names = new Map<string, string>();
  const folders = new Map<string, string>();
  const uses = new Map<string, number>();
  for (const f of plan.files) {
    const name = stripExt(lastPart(f.path));
    names.set(key(f.note.id), name);
    folders.set(key(f.note.id), lastPart(parentPath(f.path)));
    uses.set(searchFold(name), (uses.get(searchFold(name)) ?? 0) + 1);
  }
  const qualified = new Map<string, string>();
  for (const [id, name] of names) {
    if ((uses.get(searchFold(name)) ?? 0) <= 1) continue;
    const folder = cleaned(folders.get(id) ?? '', WIKI_UNSAFE).trim();
    if (folder) qualified.set(id, `${folder}/${name}`);
  }
  return {
    /** `[[…]]` target, or null to write only the link's text. */
    wikiName(link: { id: string } | { title: string }): string | null {
      if ('id' in link) {
        const name = qualified.get(key(link.id)) ?? names.get(key(link.id));
        if (name) return name;
        const title = titles.get(key(link.id));
        const c = title === undefined ? '' : cleaned(title, WIKI_UNSAFE);
        return c || null;
      }
      return cleaned(link.title, WIKI_UNSAFE) || null;
    },
    /** A relative link from `source`'s file to the linked note's file; undefined when it isn't in this export. */
    href(source: string, link: { id: string; heading?: string }, ext: string): string | undefined {
      const name = names.get(key(link.id));
      if (!name) return undefined;
      let parts = [`${name}.${ext}`];
      const target = folders.get(key(link.id))!;
      if (target !== folders.get(key(source))) parts = ['..', target, ...parts];
      let out = parts.map(encodePathPart).join('/');
      if (link.heading) out += `#${headingSlug(link.heading)}`;
      return out;
    },
  };
}

// CharacterSet.urlPathAllowed without `#?;`.
const PATH_ALLOWED = /^[A-Za-z0-9\-._~!$&'()*+,=:@/]$/;
function encodePathPart(s: string): string {
  let out = '';
  for (const ch of s) {
    if (PATH_ALLOWED.test(ch)) out += ch;
    else for (const b of new TextEncoder().encode(ch)) out += `%${b.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return out;
}

/** NSString pathExtension / deletingPathExtension. */
function splitExt(name: string): [string, string] {
  const dot = name.lastIndexOf('.');
  if (dot <= 0 || dot === name.length - 1) return [name, ''];
  return [name.slice(0, dot), name.slice(dot + 1)];
}

/** A Markdown link destination as native export writes it: `<…>` around one with spaces or brackets. */
function destination(raw: string): string {
  const s = raw.replace(/\\/g, '\\\\').replace(/&/g, '\\&');
  return /[ ()<>]/.test(s) ? `<${s}>` : s;
}

function base64Bytes(data: string): Uint8Array {
  const bin = atob(data);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export interface FolderExportResult {
  /** Path → bytes; folders end in `/`. */
  entries: Record<string, Uint8Array>;
  written: number;
  /** Titles of notes whose body couldn't be read here (locked or from an older Mac). */
  skipped: string[];
}

/**
 * Writes the planned files. `body` gives a note's container, or undefined when it can't be read; `notes` is every note
 * (deleted ones too), for the titles of links to notes outside the export.
 */
export function writeFolderExport(plan: FolderExportPlan, notes: ExportNote[], body: (id: string) => BodyContainer | undefined): FolderExportResult {
  const links = exportLinkContext(plan, notes);
  const entries: Record<string, Uint8Array> = {};
  for (const folder of plan.folders) entries[`${folder}/`] = new Uint8Array(0);
  const enc = new TextEncoder();
  let written = 0;
  const skipped: string[] = [];
  for (const file of plan.files) {
    const title = exportDisplayTitle(file.note.title);
    const container = body(file.note.id);
    if (!container) {
      skipped.push(title);
      continue;
    }
    if (plan.format === 'markdown') {
      const folder = parentPath(file.path);
      const assets = assetsFolderName(stripExt(lastPart(file.path)));
      const taken = new Set<string>();
      let images = 0;
      const attachment = (node: Extract<Inline, { type: 'image' | 'attachment' }>) => {
        const entry = container.attachments[node.attrs.sha];
        if (!entry) return '';
        let filename: string;
        if (node.type === 'image') {
          images += 1;
          filename = uniqueFileName(`image-${images}`, splitExt(node.attrs.name || entry.name || '')[1].toLowerCase() || 'png', taken);
        } else {
          const [base, ext] = splitExt(node.attrs.name || entry.name || 'file');
          filename = uniqueFileName(sanitizedFileName(base, 'file'), ext, taken);
        }
        entries[`${folder}/${assets}/${filename}`] = base64Bytes(entry.data);
        const path = destination(`${assets}/${filename}`);
        return node.type === 'image' ? `![](${path})` : `[${escapeMarkdownText(filename)}](${path})`;
      };
      const md = docToMarkdown(container.doc, { attachment, wikiName: (l) => links.wikiName(l) });
      if (Object.keys(entries).some((p) => p.startsWith(`${folder}/${assets}/`))) entries[`${folder}/${assets}/`] = new Uint8Array(0);
      entries[file.path] = enc.encode(md);
    } else {
      const html = docToHtml(container.doc, {
        title,
        imageSrc: (sha) => {
          const a = container.attachments[sha];
          return a && /^image\//.test(a.mime) ? `data:${a.mime};base64,${a.data}` : undefined;
        },
        noteHref: (l) => links.href(file.note.id, l, 'html'),
      });
      entries[file.path] = enc.encode(html);
    }
    written += 1;
  }
  return { entries, written, skipped };
}

/** The export as a zip whose top folder is the plan's root. */
export function zipFolderExport(result: FolderExportResult, mtime = new Date()): Uint8Array {
  return zipSync(result.entries, { mtime, level: 6 });
}
