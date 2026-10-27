/**
 * Notion's "Markdown & CSV" export, as native `NotionImporter`, `NotionNames` and `NotionCSV`: each page (`.md`)
 * and database (`.csv`) becomes a note; a top-level page with subpages becomes a notebook holding it and everything
 * below it, other top-level pages go to "Notion"; links between pages become note links, `<aside>` callouts quotes,
 * and images on the web links to them.
 */
import { parseMarkdown, resolveMarkdownAttachments } from './markdown-read.js';
import { noteLinkURL } from './linking.js';
import { parseNoteLink, type Block, type BodyContainer, type Inline, type TableRow } from './schema.js';

export const NOTION_MAX_TABLE_ROWS = 1_000;
export const NOTION_LOOSE_NOTEBOOK = 'Notion';
export const NOTION_HTML_EXPORT = 'This is an HTML export. In Notion, choose Export › Markdown & CSV and try again.';

// MARK: - Names

/** "Plan 1a2b…c3d4" → title "Plan", id "1a2b…c3d4"; a name without an id comes back as it is. */
export function notionStripID(name: string): { title: string; id?: string } {
  const m = /^(.*?)\s+([0-9a-f]{32})$/i.exec(name);
  if (!m) return { title: name.trim() };
  return { title: m[1]!.trim(), id: m[2]!.toLowerCase() };
}

export function notionStem(name: string): string {
  const dot = name.lastIndexOf('.');
  const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
  if (ext !== 'md' && ext !== 'csv') return name;
  let stem = name.slice(0, dot);
  if (ext === 'csv' && stem.endsWith('_all')) stem = stem.slice(0, -4);
  return stem;
}

/** A title from a folder name or a file name without its extension. */
export function notionTitleOfStem(stem: string): string {
  return notionStripID(stem).title || 'Untitled';
}

/** A page or database title from its file name: no `.md` or `.csv`, no `_all`, no id. */
export function notionTitleOfFile(name: string): string {
  return notionTitleOfStem(notionStem(name));
}

// MARK: - CSV

/** CSV as Notion writes it (RFC 4180): the header and up to `limit` rows; `truncated` when more follow. */
export function readNotionCSV(text: string, limit: number): { header: string[]; rows: string[][]; truncated: boolean } {
  const records: string[][] = [];
  let field = '';
  let record: string[] = [];
  let quoted = false;
  let afterQuote = false;
  let truncated = false;
  const chars = [...(text.startsWith('﻿') ? text.slice(1) : text)];
  const endRecord = (): boolean => {
    record.push(field);
    field = '';
    if (!(record.length === 1 && record[0] === '')) {
      if (records.length === limit + 1) {
        truncated = true;
        return false;
      }
      records.push(record);
    }
    record = [];
    return true;
  };
  let i = 0;
  scan: while (i < chars.length) {
    const c = chars[i++]!;
    if (quoted) {
      if (c === '"') {
        if (chars[i] === '"') {
          field += '"';
          i++;
        } else {
          quoted = false;
          afterQuote = true;
        }
      } else field += c;
      continue;
    }
    if (c === '"' && field === '' && !afterQuote) quoted = true;
    else if (c === ',') {
      record.push(field);
      field = '';
      afterQuote = false;
    } else if (c === '\r' || c === '\n') {
      if (c === '\r' && chars[i] === '\n') i++;
      afterQuote = false;
      if (!endRecord()) break scan;
    } else field += c;
  }
  if (!truncated && (field !== '' || record.length)) endRecord();
  const header = records[0];
  if (!header) return { header: [], rows: [], truncated: false };
  return { header: header.map((h) => h.trim()), rows: records.slice(1), truncated };
}

// MARK: - Pages

export interface NotionFile {
  /** Path inside its root, "/"-separated. */
  path: string;
  /** Which root (the export, or one of its part ZIPs) the file is in. */
  root: number;
}

export interface NotionPage extends NotionFile {
  /** Path inside the export without the extension (and `_all`), "/"-separated. */
  key: string;
  notebook: string;
  /** The top-level folder the notebook comes from ("" for loose pages); pages with the same one share it. */
  notebookKey: string;
  title: string;
  isTable: boolean;
}

const compareNames = (a: string, b: string) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' });
const extOf = (name: string) => {
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
};

/** Every page and database among `files`, merged by their path inside the export, parents first. */
export function notionPages(files: NotionFile[]): { pages: NotionPage[]; sawHTML: boolean } {
  let found: { parts: string[]; file: NotionFile }[] = [];
  let sawHTML = false;
  for (const f of files) {
    const parts = f.path.split('/').filter(Boolean);
    if (parts.some((p) => p.startsWith('.') || p === '__MACOSX')) continue;
    const ext = extOf(parts.at(-1) ?? '');
    if (ext === 'md' || ext === 'csv') found.push({ parts, file: f });
    else if (ext === 'html') sawHTML = true;
  }
  if (!found.length) return { pages: [], sawHTML };
  // A folder every page sits in (Notion's export or workspace folder) isn't part of the page tree.
  for (;;) {
    const first = found[0]!.parts[0];
    if (!found.every((x) => x.parts.length > 1 && x.parts[0] === first)) break;
    found = found.map((x) => ({ ...x, parts: x.parts.slice(1) }));
  }
  const keyOf = (parts: string[]) => [...parts.slice(0, -1), notionStem(parts.at(-1) ?? '')].join('/');
  // A database exported as both `X.csv` (one view) and `X_all.csv` keeps the full one; a page wins over both.
  const rank = (parts: string[]) => {
    const name = parts.at(-1) ?? '';
    if (extOf(name) === 'md') return 2;
    return name.slice(0, name.lastIndexOf('.')).endsWith('_all') ? 1 : 0;
  };
  const chosen = new Map<string, { parts: string[]; file: NotionFile }>();
  for (const x of found) {
    const k = keyOf(x.parts);
    const existing = chosen.get(k);
    if (existing && rank(existing.parts) >= rank(x.parts)) continue;
    chosen.set(k, x);
  }
  const topWithChildren = new Set([...chosen.keys()].filter((k) => k.includes('/')).map((k) => k.split('/')[0]!));
  const pages = [...chosen.values()].map(({ parts, file }): NotionPage => {
    const key = keyOf(parts);
    const first = key.split('/')[0] ?? key;
    const loose = parts.length === 1 && !topWithChildren.has(first);
    return {
      ...file,
      key,
      notebook: loose ? NOTION_LOOSE_NOTEBOOK : notionTitleOfStem(first),
      notebookKey: loose ? '' : first,
      title: notionTitleOfFile(parts.at(-1) ?? ''),
      isTable: extOf(parts.at(-1) ?? '') === 'csv',
    };
  });
  pages.sort((a, b) => {
    const x = a.key.split('/');
    const y = b.key.split('/');
    for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return compareNames(x[i]!, y[i]!);
    return x.length - y.length;
  });
  return { pages, sawHTML };
}

/** The page key a link target written in a page in `folder` points at. */
export function notionResolvedKey(target: string, folder: string[]): string {
  const parts = [...folder];
  for (const part of target.split('/').filter(Boolean)) {
    if (part === '.') continue;
    if (part === '..') parts.pop();
    else parts.push(part);
  }
  return parts.join('/');
}

// MARK: - Preparing the Markdown

interface OpenFence {
  char: string;
  count: number;
  depth: number;
  indent: number;
}

function indentation(line: string): [number, string] {
  let width = 0;
  let i = 0;
  while (i < line.length && (line[i] === ' ' || line[i] === '\t')) {
    width += line[i] === '\t' ? 4 - (width % 4) : 1;
    i++;
  }
  return [width, line.slice(i)];
}

function dropQuotes(line: string, depth: number): string | undefined {
  let rest = line;
  for (let d = 0; d < depth; d++) {
    const [indent, body] = indentation(rest);
    if (indent > 3 || !body.startsWith('>')) return undefined;
    rest = body.slice(1);
    if (rest.startsWith(' ')) rest = rest.slice(1);
  }
  return rest;
}

function fenceMarker(body: string): { char: string; count: number } | undefined {
  const c = body[0];
  if (c !== '`' && c !== '~') return undefined;
  let count = 0;
  while (body[count] === c) count++;
  return count >= 3 ? { char: c, count } : undefined;
}

/**
 * Tracks fenced code blocks (``` and ~~~, also inside quotes) line by line, as CommonMark closes them: only a fence
 * of the same character, at least as long, at the opener's quote depth.
 */
export class NotionCodeFence {
  private open: OpenFence | undefined;

  /** True for a fence line or a line inside a fenced block. */
  isCode(line: string): boolean {
    const current = this.open;
    if (current) {
      const rest = dropQuotes(line, current.depth);
      if (rest === undefined) {
        this.open = undefined;
        return this.isCode(line);
      }
      const [indent, body] = indentation(rest);
      const marker = fenceMarker(body);
      if (indent <= current.indent + 3 && marker && marker.char === current.char && marker.count >= current.count && !body.slice(marker.count).trim()) this.open = undefined;
      return true;
    }
    let rest = line;
    let depth = 0;
    for (let inner = dropQuotes(rest, 1); inner !== undefined; inner = dropQuotes(rest, 1)) {
      rest = inner;
      depth++;
    }
    const [indent, body] = indentation(rest);
    const marker = fenceMarker(body);
    if (!marker || (marker.char === '`' && body.slice(marker.count).includes('`'))) return false;
    this.open = { ...marker, depth, indent };
    return true;
  }
}

/** Rewrites the parts of `line` outside backtick code spans. */
function outsideCodeSpans(line: string, rewrite: (s: string) => string): string {
  if (!line.includes('`')) return rewrite(line);
  const chars = [...line];
  let out = '';
  let plain = '';
  let i = 0;
  while (i < chars.length) {
    if (chars[i] !== '`') {
      plain += chars[i];
      i++;
      continue;
    }
    let n = 0;
    while (chars[i + n] === '`') n++;
    let j = i + n;
    let close: number | undefined;
    while (j < chars.length) {
      if (chars[j] === '`') {
        let m = 0;
        while (chars[j + m] === '`') m++;
        if (m === n) {
          close = j;
          break;
        }
        j += m;
      } else j++;
    }
    if (close === undefined) {
      plain += chars.slice(i, i + n).join('');
      i += n;
      continue;
    }
    out += rewrite(plain) + chars.slice(i, close + n).join('');
    plain = '';
    i = close + n;
  }
  return out + rewrite(plain);
}

/** `text` with `rewrite` applied outside fenced code blocks and code spans, one line of prose at a time. */
export function notionOutsideCode(text: string, rewrite: (s: string) => string): string {
  const fence = new NotionCodeFence();
  return text
    .split('\n')
    .map((l) => (fence.isCode(l) ? l : outsideCodeSpans(l, rewrite)))
    .join('\n');
}

const REMOTE_IMAGE = /!\[((?:[^[\]\\]|\\.)*)\]\(\s*(?:<(https?:\/\/[^<>\n]+)>|(https?:\/\/[^\s()]+))(?:\s+"[^"\n]*")?\s*\)/gi;

function imagesAsLinks(text: string): string {
  return text.replace(REMOTE_IMAGE, (_, alt: string, angled: string | undefined, bare: string | undefined) => {
    const url = (angled ?? bare)!;
    let label = alt.trim();
    if (!label) label = url.replace(/\\/g, '\\\\').replace(/\[/g, '\\[').replace(/\]/g, '\\]');
    return `[${label}](${url.replace(/ /g, '%20')})`;
  });
}

/** `![alt](https://…)` → `[alt](https://…)`, named by the address when it has no alt text, outside code. */
export function notionRemoteImagesAsLinks(text: string): string {
  return notionOutsideCode(text, imagesAsLinks);
}

const CSV_LINK = /\]\(([^()\s]*?)(?:_all)?\.csv\)/gi;

/**
 * `<aside>` callouts become quotes, links to a database's `.csv` point at its note, and images on the web become
 * links to them. Code (fenced blocks and code spans) is never changed.
 */
export function notionPrepared(markdown: string): string {
  const out: string[] = [];
  let inAside = false;
  const fence = new NotionCodeFence();
  for (const line of markdown.split('\n')) {
    if (fence.isCode(line)) {
      out.push(inAside ? (line ? `> ${line}` : '>') : line);
      continue;
    }
    let rest = line;
    if (!inAside && rest.trim().startsWith('<aside>')) {
      inAside = true;
      rest = rest.slice(rest.indexOf('<aside>') + 7);
      if (!rest.trim()) continue;
    }
    if (!inAside) {
      out.push(line);
      continue;
    }
    const close = rest.indexOf('</aside>');
    if (close >= 0) {
      inAside = false;
      const content = rest.slice(0, close).trim();
      if (content) out.push(`> ${content}`);
      const after = rest.slice(close + 8).trim();
      if (after) out.push('', after);
      continue;
    }
    const content = rest.trim();
    out.push(content ? `> ${content}` : '>');
  }
  return notionOutsideCode(out.join('\n'), (prose) => imagesAsLinks(prose.replace(CSV_LINK, ']($1.md)')));
}

// MARK: - Bodies

const heading = (text: string): Block => ({ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text }] });

function firstLineText(blocks: Block[]): string {
  const b = blocks[0];
  if (!b) return '';
  if (b.type === 'table' || b.type === 'horizontalRule') return '';
  const content = b.type === 'blockquote' ? b.content[0]?.content : b.content;
  return (content ?? []).map((n: Inline) => (n.type === 'text' ? n.text : n.type === 'hardBreak' ? '\n' : '￼')).join('').split('\n')[0]!.trim();
}

/** Title links left from page links pointing outside the export show the page's title, not its file name. */
function retitleUnresolvedLinks(node: unknown): void {
  if (!node || typeof node !== 'object') return;
  const n = node as { marks?: { type: string; attrs?: { href?: string } }[]; content?: unknown[] };
  for (const m of n.marks ?? []) {
    if (m.type !== 'link' || !m.attrs?.href) continue;
    const link = parseNoteLink(m.attrs.href);
    if (!link || !('title' in link)) continue;
    const heading = new URL(m.attrs.href).searchParams.get('heading') ?? undefined;
    const clean = notionTitleOfStem(link.title.split('/').at(-1) ?? link.title);
    if (clean !== link.title) m.attrs.href = noteLinkURL({ title: clean, ...(heading ? { heading } : {}) });
  }
  n.content?.forEach(retitleUnresolvedLinks);
}

/**
 * A page's note body. `read` gets a path inside the export relative to the page's own folder (images); `ids` maps
 * page keys to the notes' ids for links between pages.
 */
export function notionPageBody(text: string, page: Pick<NotionPage, 'key' | 'title'>, opts: { read: (path: string) => Uint8Array | undefined; ids: Map<string, string> }): { body: BodyContainer; missingAttachments: number } {
  const folder = page.key.split('/').slice(0, -1);
  const parsed = parseMarkdown(notionPrepared(text.startsWith('﻿') ? text.slice(1) : text), { resolveNoteLink: (target) => opts.ids.get(notionResolvedKey(target, folder)) });
  const resolved = resolveMarkdownAttachments(parsed, (p) => (/^[a-z][a-z0-9+.-]*:/i.test(p) ? undefined : opts.read(p)));
  const body = resolved.body;
  retitleUnresolvedLinks(body.doc);
  const blocks = [...(body.doc.content ?? [])];
  if (firstLineText(blocks).toLowerCase() !== page.title.toLowerCase()) blocks.unshift(heading(page.title));
  return { body: { ...body, doc: { type: 'doc', content: blocks } }, missingAttachments: resolved.unresolvedImages.length };
}

/** A database's note: its title and a table of its rows (up to `NOTION_MAX_TABLE_ROWS`); undefined without a header. */
export function notionTableBody(text: string, title: string): { body: BodyContainer; truncated: boolean } | undefined {
  const table = readNotionCSV(text, NOTION_MAX_TABLE_ROWS);
  if (!table.header.length) return undefined;
  const columns = table.header.length;
  const flat = (cell: string) => cell.split(/\r\n|\r|\n/).join(' ');
  const row = (cells: string[], type: 'tableHeader' | 'tableCell'): TableRow => ({
    type: 'tableRow',
    content: Array.from({ length: columns }, (_, i) => {
      const t = flat(cells[i] ?? '');
      return { type, content: [t ? { type: 'paragraph', content: [{ type: 'text', text: t }] } : { type: 'paragraph' }] };
    }),
  });
  const content: Block[] = [heading(title), { type: 'table', content: [row(table.header, 'tableHeader'), ...table.rows.map((r) => row(r, 'tableCell'))] }];
  return { body: { format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content } }, truncated: table.truncated };
}
