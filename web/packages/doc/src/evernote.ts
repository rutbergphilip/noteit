/**
 * Evernote `.enex` import, as native `EvernoteImporter`, `ENEXReader`, `ENEXNoteParser` and `ENMLConverter`: each
 * `<note>` is parsed on its own (one that isn't well-formed XML is skipped, the rest still import), ENML becomes
 * HTML with `en-todo` as checklist markers, `en-media` as placeholders for its resource (matched by MD5) and
 * `en-crypt` dropped; then the HTML importer, resources as attachments, checklists, Evernote note links as title
 * links, and a last line with the tags and the reminder.
 */
import { addAttachment } from './container.js';
import { htmlToBlocks } from './html-import.js';
import type { ImportTags } from './import-tags.js';
import { noteLinkURL } from './linking.js';
import { md5Hex } from './md5.js';
import { MAX_ATTACHMENT_BYTES, parseNoteLink, type Block, type BodyContainer, type Inline, type Mark, type NoteItDoc, type ParagraphNode } from './schema.js';
import { localDateTimeToken, localFromDate } from './tokens.js';

export interface EvernoteResource {
  data: Uint8Array;
  mime: string;
  fileName?: string;
}

export interface EvernoteNote {
  title: string;
  created?: Date;
  updated?: Date;
  tags: string[];
  /** ENML. */
  content: string;
  resources: EvernoteResource[];
  /** Resources over the attachment limit, left out. */
  resourcesTooLarge: number;
  reminder?: Date;
  reminderDone: boolean;
}

const UNCHECKED_TODO = '';
const CHECKED_TODO = '';
const MEDIA_START = '';
const MEDIA_END = '';
const MARKERS = /[-]/g;

// MARK: - Reading

interface XEl {
  name: string;
  children: (XEl | string)[];
}

const ENTITY: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

function decodeEntities(s: string): string | undefined {
  if (!s.includes('&')) return s;
  let bad = false;
  const out = s.replace(/&([^;&\s]*);?/g, (all, name: string) => {
    if (!all.endsWith(';')) return ((bad = true), '');
    if (name in ENTITY) return ENTITY[name]!;
    const m = /^#(x[0-9a-f]+|[0-9]+)$/i.exec(name);
    if (!m) return ((bad = true), '');
    const code = m[1]![0] === 'x' || m[1]![0] === 'X' ? parseInt(m[1]!.slice(1), 16) : parseInt(m[1]!, 10);
    if (!(code > 0 && code <= 0x10ffff)) return ((bad = true), '');
    return String.fromCodePoint(code);
  });
  return bad ? undefined : out;
}

/** A small, strict XML reader for one `<note>`: undefined when it isn't well-formed (as `XMLParser` fails). */
function parseXML(src: string): XEl | undefined {
  const root: XEl = { name: '', children: [] };
  const stack: XEl[] = [root];
  let i = 0;
  while (i < src.length) {
    const lt = src.indexOf('<', i);
    const end = lt < 0 ? src.length : lt;
    if (end > i) {
      const text = decodeEntities(src.slice(i, end));
      if (text === undefined) return undefined;
      stack.at(-1)!.children.push(text);
    }
    if (lt < 0) break;
    if (src.startsWith('<![CDATA[', lt)) {
      const close = src.indexOf(']]>', lt + 9);
      if (close < 0) return undefined;
      stack.at(-1)!.children.push(src.slice(lt + 9, close));
      i = close + 3;
      continue;
    }
    const skip = (open: string, close: string) => {
      if (!src.startsWith(open, lt)) return false;
      const at = src.indexOf(close, lt + open.length);
      i = at < 0 ? -1 : at + close.length;
      return true;
    };
    if (skip('<!--', '-->') || skip('<?', '?>') || skip('<!', '>')) {
      if (i < 0) return undefined;
      continue;
    }
    const gt = src.indexOf('>', lt);
    if (gt < 0) return undefined;
    const tag = src.slice(lt + 1, gt);
    i = gt + 1;
    if (tag.startsWith('/')) {
      const name = tag.slice(1).trim();
      const top = stack.pop();
      if (!top || top === root || top.name !== name) return undefined;
      continue;
    }
    const m = /^([A-Za-z_][\w.:-]*)((?:\s+[\w.:-]+\s*=\s*(?:"[^"<]*"|'[^'<]*'))*)\s*(\/?)$/.exec(tag);
    if (!m) return undefined;
    const el: XEl = { name: m[1]!, children: [] };
    stack.at(-1)!.children.push(el);
    if (!m[3]) stack.push(el);
  }
  if (stack.length !== 1) return undefined;
  return root.children.find((c): c is XEl => typeof c !== 'string');
}

const text = (el: XEl) => el.children.filter((c): c is string => typeof c === 'string').join('');
const elements = (el: XEl, name?: string) => el.children.filter((c): c is XEl => typeof c !== 'string' && (!name || c.name === name));

/** `20240102T030405Z` (UTC), as Evernote writes its dates. */
export function enexDate(value: string): Date | undefined {
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(value.trim());
  if (!m) return undefined;
  const d = new Date(Date.UTC(+m[1]!, +m[2]! - 1, +m[3]!, +m[4]!, +m[5]!, +m[6]!));
  return Number.isNaN(d.getTime()) ? undefined : d;
}

/** Base64 is a third larger than its data, plus line breaks. */
const MAX_BASE64_BYTES = Math.floor(MAX_ATTACHMENT_BYTES / 3) * 4 + Math.floor(MAX_ATTACHMENT_BYTES / 8);

function base64Bytes(b64: string): Uint8Array | undefined {
  try {
    const bin = atob(b64.replace(/[^A-Za-z0-9+/]/g, ''));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return undefined;
  }
}

/** One `<note>…</note>`, parsed; undefined when it isn't well-formed. */
export function parseEnexNote(xml: string): EvernoteNote | undefined {
  const el = parseXML(xml);
  if (!el || el.name !== 'note') return undefined;
  const note: EvernoteNote = { title: '', tags: [], content: '', resources: [], resourcesTooLarge: 0, reminderDone: false };
  for (const child of elements(el)) {
    const value = text(child).trim();
    switch (child.name) {
      case 'title':
        note.title = value;
        break;
      case 'created': {
        const d = enexDate(value);
        if (d) note.created = d;
        break;
      }
      case 'updated': {
        const d = enexDate(value);
        if (d) note.updated = d;
        break;
      }
      case 'tag':
        if (value) note.tags.push(value);
        break;
      case 'content':
        note.content = text(child);
        break;
      case 'note-attributes':
        for (const a of elements(child)) {
          if (a.name === 'reminder-time') {
            const d = enexDate(text(a));
            if (d) note.reminder = d;
          } else if (a.name === 'reminder-done-time') note.reminderDone = enexDate(text(a)) !== undefined;
        }
        break;
      case 'resource': {
        let tooLarge = false;
        const resource: EvernoteResource = { data: new Uint8Array(), mime: '' };
        for (const r of elements(child)) {
          if (r.name === 'data') {
            const raw = text(r);
            if (raw.length > MAX_BASE64_BYTES) tooLarge = true;
            else {
              const bytes = base64Bytes(raw);
              if (bytes && bytes.length > MAX_ATTACHMENT_BYTES) tooLarge = true;
              else if (bytes) resource.data = bytes;
            }
          } else if (r.name === 'mime') resource.mime = text(r).trim();
          else if (r.name === 'resource-attributes') {
            const name = elements(r, 'file-name')[0];
            const v = name ? text(name).trim() : '';
            if (v) resource.fileName = v;
          }
        }
        if (tooLarge) note.resourcesTooLarge += 1;
        else if (resource.data.length) note.resources.push(resource);
        break;
      }
    }
  }
  return note;
}

/**
 * The notes of an `.enex` file in order, each parsed on its own (undefined for one that can't be read, or is cut
 * off at the end). `isExport` is true when the file starts an `<en-export>`.
 */
export function readEnex(file: string): { notes: (EvernoteNote | undefined)[]; isExport: boolean } {
  const notes: (EvernoteNote | undefined)[] = [];
  let at = 0;
  for (;;) {
    const start = file.indexOf('<note>', at);
    if (start < 0) break;
    const close = file.indexOf('</note>', start + 6);
    if (close < 0) {
      notes.push(undefined);
      break;
    }
    at = close + 7;
    notes.push(parseEnexNote(file.slice(start, at)));
  }
  return { notes, isExport: file.slice(0, 64 * 1024).includes('<en-export') };
}

// MARK: - ENML

export function hasEncryptedSections(enml: string): boolean {
  return /<en-crypt/i.test(enml);
}

/** ENML → HTML, rewritten with patterns rather than parsed, so ENML that isn't well-formed still comes through. */
export function enmlToHtml(enml: string, hashes: Set<string>): string {
  let t = enml.replace(MARKERS, '');
  t = t.replace(/<\?xml[^>]*\?>|<!DOCTYPE[^>]*>/gis, '');
  t = t.replace(/<en-crypt\b[^>]*\/>|<en-crypt\b[^>]*>.*?(?:<\/en-crypt\s*>|$)/gis, '');
  t = t.replace(/<en-todo\b([^>]*?)\/?>/gis, (_, attrs: string) => (/\bchecked\s*=\s*["']?true/i.test(attrs) ? CHECKED_TODO : UNCHECKED_TODO));
  t = t.replace(/<en-media\b([^>]*?)\/?>/gis, (_, attrs: string) => {
    const hash = /\bhash\s*=\s*["']?([0-9a-f]{32})/i.exec(attrs)?.[1]?.toLowerCase();
    return hash && hashes.has(hash) ? MEDIA_START + hash + MEDIA_END : '';
  });
  t = t.replace(/<\/en-(?:todo|media)\s*>/gis, '');
  t = t.replace(/<en-note\b/gis, '<div');
  t = t.replace(/<\/en-note\s*>/gis, '</div>');
  return t;
}

// MARK: - Note bodies

const EXTENSION_FOR_MIME: Record<string, string> = {
  'image/png': 'png', 'image/jpeg': 'jpeg', 'image/jpg': 'jpeg', 'image/gif': 'gif', 'image/webp': 'webp', 'image/heic': 'heic',
  'image/heif': 'heif', 'image/tiff': 'tiff', 'image/bmp': 'bmp', 'image/svg+xml': 'svg', 'application/pdf': 'pdf',
  'text/plain': 'txt', 'text/html': 'html', 'text/csv': 'csv', 'text/markdown': 'md', 'application/json': 'json',
  'application/rtf': 'rtf', 'text/rtf': 'rtf', 'application/zip': 'zip', 'audio/mpeg': 'mp3', 'audio/mp4': 'm4a',
  'audio/x-m4a': 'm4a', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/amr': 'amr', 'video/mp4': 'mp4',
  'video/quicktime': 'mov', 'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx', 'application/vnd.ms-excel': 'xls',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx', 'application/vnd.ms-powerpoint': 'ppt',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
};

/** The resource's own file name, given the extension its MIME type calls for when it has none (native `fileName(for:index:)`). */
export function evernoteFileName(resource: Pick<EvernoteResource, 'mime' | 'fileName'>, index: number): string {
  const mime = resource.mime.toLowerCase();
  const ext = EXTENSION_FOR_MIME[mime];
  const own = resource.fileName?.replace(/[/:]/g, '-').trim();
  if (own && !own.startsWith('.')) {
    const dot = own.lastIndexOf('.');
    if (!(dot > 0 && dot < own.length - 1) && ext) return `${own}.${ext}`;
    return own;
  }
  const stem = mime.startsWith('image/') ? 'image' : 'attachment';
  return ext ? `${stem}-${index}.${ext}` : `${stem}-${index}`;
}

/** `evernote:///view/…` and `https://www.evernote.com/shard/…/nl/…` note links. */
export function isEvernoteNoteLink(href: string): boolean {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return false;
  }
  const scheme = url.protocol.slice(0, -1).toLowerCase();
  if (scheme === 'evernote') return true;
  const host = url.hostname.toLowerCase();
  if ((scheme !== 'https' && scheme !== 'http') || !(host === 'evernote.com' || host.endsWith('.evernote.com'))) return false;
  const parts = url.pathname.split('/').filter(Boolean);
  return parts[0] === 'shard' && parts.includes('nl');
}

/** `@remind(2024-01-05 10:00 done)` in local time. */
export function evernoteReminderToken(date: Date, done: boolean): string {
  return `@remind(${localDateTimeToken(localFromDate(date, true))}${done ? ' done' : ''})`;
}

const isImageMime = (mime: string) => /^image\//i.test(mime) && !/svg/i.test(mime);

type InlineHost = { content?: Inline[] };

/** Every inline run in the doc: top-level blocks and table cells. */
function inlineHosts(blocks: Block[]): InlineHost[] {
  const out: InlineHost[] = [];
  for (const b of blocks) {
    if (b.type === 'table') for (const row of b.content) for (const cell of row.content) out.push(...cell.content);
    else if (b.type === 'blockquote') out.push(...b.content);
    else if (b.type !== 'horizontalRule') out.push(b);
  }
  return out;
}

/** Drops the leading spaces, the marker and the spaces after it; undefined when the line doesn't start with a to-do marker. */
function takeTodo(content: Inline[] | undefined): { checked: boolean; rest: Inline[] } | undefined {
  const first = content?.[0];
  if (first?.type !== 'text') return undefined;
  const m = /^[ \t]*([]) */.exec(first.text);
  if (!m) return undefined;
  const remaining = first.text.slice(m[0].length);
  const rest = [...(remaining ? [{ ...first, text: remaining }] : []), ...content!.slice(1)];
  return { checked: m[1] === CHECKED_TODO, rest };
}

function applyChecklists(blocks: Block[]): Block[] {
  return blocks.map((b): Block => {
    if (b.type === 'table') {
      for (const row of b.content)
        for (const cell of row.content)
          for (const para of cell.content) {
            // A checklist item can't sit in a table cell, so the cell shows ☐ or ☑ instead.
            const todo = takeTodo(para.content);
            if (!todo) continue;
            const lead = (para.content![0] as { text: string }).text.match(/^[ \t]*/)![0];
            const rest = todo.checked ? todo.rest.map((n) => (n.type === 'text' ? { ...n, marks: [...(n.marks ?? []).filter((m) => m.type !== 'strike'), { type: 'strike' } as Mark] } : n)) : todo.rest;
            para.content = [{ type: 'text', text: `${lead}${todo.checked ? '☑' : '☐'} ` }, ...rest];
          }
      return b;
    }
    if (b.type !== 'paragraph' && b.type !== 'heading' && b.type !== 'listItem' && b.type !== 'codeBlock') return b;
    const todo = takeTodo(b.content);
    if (!todo) return b;
    const level = b.type === 'listItem' ? b.attrs.level : 0;
    return { type: 'listItem', attrs: { kind: 'task', level, checked: todo.checked }, ...(todo.rest.length ? { content: todo.rest } : {}) };
  });
}

/** Links to Evernote notes become title links named by the link's text; title links resolve through `resolveTitle`. */
function convertLinks(hosts: InlineHost[], resolveTitle: ((title: string) => string | undefined) | undefined): void {
  const hrefOf = (n: Inline) => (n.type === 'text' ? n.marks?.find((m): m is Extract<Mark, { type: 'link' }> => m.type === 'link')?.attrs.href : undefined);
  for (const host of hosts) {
    const content = host.content;
    if (!content) continue;
    let i = 0;
    while (i < content.length) {
      const href = hrefOf(content[i]!);
      if (!href) {
        i++;
        continue;
      }
      let j = i;
      while (j < content.length && hrefOf(content[j]!) === href) j++;
      let next: string | undefined = href;
      if (isEvernoteNoteLink(href)) {
        const label = content
          .slice(i, j)
          .map((n) => (n.type === 'text' ? n.text : ''))
          .join('')
          .replace(/￼/g, '')
          .trim();
        next = label ? noteLinkURL({ title: label }) : undefined;
      }
      if (next && resolveTitle) {
        const link = parseNoteLink(next);
        const id = link && 'title' in link ? resolveTitle(link.title) : undefined;
        if (id) next = noteLinkURL({ id });
      }
      for (let k = i; k < j; k++) {
        const n = content[k] as Extract<Inline, { type: 'text' }>;
        const marks: Mark[] = (n.marks ?? []).filter((m) => m.type !== 'link');
        if (next) marks.push({ type: 'link', attrs: { href: next } });
        content[k] = marks.length ? { type: 'text', text: n.text, marks } : { type: 'text', text: n.text };
      }
      i = j;
    }
  }
}

export interface EvernoteBody {
  body: BodyContainer;
  /** Resources left out for being over the attachment limit. */
  attachmentsSkipped: number;
  /** The note had `en-crypt` sections, which were dropped. */
  encrypted: boolean;
}

/**
 * A note's body (native `EvernoteImporter.body(for:title:tagNames:report:)`). `resolveTitle` maps a title link's
 * title to an imported note's id (native resolves them after the import, by folded title).
 */
export function evernoteBody(note: EvernoteNote, title: string, tags: ImportTags, opts: { resolveTitle?: (title: string) => string | undefined } = {}): EvernoteBody {
  const resources = new Map<string, EvernoteResource>();
  const order: string[] = [];
  for (const r of note.resources) {
    const hash = md5Hex(r.data);
    if (!resources.has(hash)) order.push(hash);
    resources.set(hash, r);
  }
  const container: BodyContainer = { format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content: [] } };
  const node = (r: EvernoteResource, index: number): Inline => {
    const name = evernoteFileName(r, index);
    const sha = addAttachment(container, r.data, name, r.mime || 'application/octet-stream');
    return isImageMime(r.mime) ? { type: 'image', attrs: { sha, name, mime: r.mime } } : { type: 'attachment', attrs: { sha, name, mime: r.mime || 'application/octet-stream' } };
  };
  const used = new Set<string>();
  let index = 0;
  const token = /([0-9a-f]{32})/g;
  const expand = (s: string): (string | Inline)[] => {
    if (!s.includes(MEDIA_START)) return [s];
    const out: (string | Inline)[] = [];
    let last = 0;
    for (const m of s.matchAll(token)) {
      out.push(s.slice(last, m.index));
      last = m.index! + m[0].length;
      index += 1;
      const r = resources.get(m[1]!);
      if (!r) continue;
      used.add(m[1]!);
      out.push(node(r, index));
    }
    out.push(s.slice(last));
    return out;
  };
  let blocks = htmlToBlocks(enmlToHtml(note.content, new Set(resources.keys())), { title, expand });
  order
    .filter((h) => !used.has(h))
    .forEach((hash, n) => blocks.push({ type: 'paragraph', content: [node(resources.get(hash)!, used.size + n + 1)] }));
  blocks = applyChecklists(blocks);
  const hosts = inlineHosts(blocks);
  convertLinks(hosts, opts.resolveTitle);
  for (const host of hosts) {
    if (!host.content) continue;
    const cleaned = host.content
      .map((n) => (n.type === 'text' ? { ...n, text: n.text.replace(MARKERS, '') } : n))
      .filter((n) => n.type !== 'text' || n.text.length > 0);
    if (cleaned.length) host.content = cleaned;
    else delete host.content;
  }
  const doc: NoteItDoc = { type: 'doc', content: blocks };
  const footer: string[] = [];
  const tagLine = tags.line(note.tags, doc);
  if (tagLine) footer.push(tagLine);
  if (note.reminder) footer.push(evernoteReminderToken(note.reminder, note.reminderDone));
  if (footer.length) blocks.push({ type: 'paragraph', content: [{ type: 'text', text: footer.join(' ') }] } as ParagraphNode);
  if (!blocks.length) blocks.push(title ? { type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: title }] } : { type: 'paragraph' });
  container.doc = doc;
  return { body: container, attachmentsSkipped: note.resourcesTooLarge, encrypted: hasEncryptedSections(note.content) };
}
