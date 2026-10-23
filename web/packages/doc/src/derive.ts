import type { Block, Inline, Mark, NoteItDoc, ParagraphNode } from './schema.js';

export const TITLE_LENGTH = 120;
export const PREVIEW_LENGTH = 140;
const BULLETS = ['•', '◦', '▪'];

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

export function prefixGraphemes(s: string, n: number): string {
  let out = '';
  let count = 0;
  for (const { segment } of segmenter.segment(s)) {
    if (count++ >= n) break;
    out += segment;
  }
  return out;
}

/** Native `clean(line)`: drop U+FFFC and control characters, tabs → spaces, trim. */
export function cleanLine(line: string): string {
  return line
    .replace(/￼/g, '')
    .replace(/\t/g, ' ')
    .replace(/\p{Cc}/gu, '')
    .trim();
}

interface Run {
  text: string;
  /** Masked for tag parsing: code and links. */
  masked: boolean;
}

function inlineRuns(content: Inline[] | undefined, code: boolean): Run[] {
  const runs: Run[] = [];
  for (const node of content ?? []) {
    switch (node.type) {
      case 'text': {
        const marks: Mark[] = node.marks ?? [];
        runs.push({ text: node.text, masked: code || marks.some((m) => m.type === 'code' || m.type === 'link') });
        break;
      }
      case 'hardBreak':
        runs.push({ text: ' ', masked: code });
        break;
      case 'image':
      case 'attachment':
        runs.push({ text: '￼', masked: code });
        break;
    }
  }
  return runs;
}

const join = (runs: Run[]) => runs.map((r) => r.text).join('');
const mask = (runs: Run[]) => runs.map((r) => (r.masked ? ' '.repeat(r.text.length) : r.text)).join('');

function listMarker(attrs: Extract<Block, { type: 'listItem' }>['attrs']): string {
  switch (attrs.kind) {
    case 'bullet':
      return `${BULLETS[((attrs.level % 3) + 3) % 3]}\t`;
    case 'ordered':
      return `${attrs.number ?? 1}.\t`;
    case 'task':
      return `${attrs.checked ? '☑' : '☐'}\t`;
  }
}

interface Paragraph {
  runs: Run[];
}

/** Every native paragraph of the document, in order, tables kept apart. */
function paragraphs(doc: NoteItDoc): ({ kind: 'line'; p: Paragraph } | { kind: 'table'; rows: { header: boolean; cells: Paragraph[] }[] })[] {
  const out: ({ kind: 'line'; p: Paragraph } | { kind: 'table'; rows: { header: boolean; cells: Paragraph[] }[] })[] = [];
  const para = (p: ParagraphNode): Paragraph => ({ runs: inlineRuns(p.content, false) });
  for (const block of doc.content ?? []) {
    switch (block.type) {
      case 'paragraph':
      case 'heading':
        out.push({ kind: 'line', p: { runs: inlineRuns(block.content, false) } });
        break;
      case 'codeBlock':
        out.push({ kind: 'line', p: { runs: inlineRuns(block.content, true) } });
        break;
      case 'blockquote':
        for (const p of block.content ?? []) out.push({ kind: 'line', p: para(p) });
        break;
      case 'horizontalRule':
        out.push({ kind: 'line', p: { runs: [{ text: ' ', masked: false }] } });
        break;
      case 'listItem':
        out.push({ kind: 'line', p: { runs: [{ text: listMarker(block.attrs), masked: false }, ...inlineRuns(block.content, false)] } });
        break;
      case 'table':
        out.push({
          kind: 'table',
          rows: (block.content ?? []).map((row) => ({
            header: row.content.length > 0 && row.content.every((c) => c.type === 'tableHeader'),
            cells: row.content.flatMap((c) => (c.content ?? []).map(para)),
          })),
        });
        break;
      default:
        break;
    }
  }
  return out;
}

/** Native-equivalent display lines: list markers kept, each table collapsed into one line without its header row. */
export function plainLines(doc: NoteItDoc): string[] {
  const lines: string[] = [];
  for (const item of paragraphs(doc)) {
    if (item.kind === 'line') {
      lines.push(cleanLine(join(item.p.runs)));
      continue;
    }
    const rows = item.rows
      .filter((r) => !r.header)
      .map((r) => r.cells.map((c) => cleanLine(join(c.runs))).filter((c) => c.length > 0))
      .filter((cells) => cells.length > 0)
      .map((cells) => cells.join(' · '));
    if (rows.length > 0) lines.push(rows.join('  '));
  }
  return lines;
}

export function deriveTitleAndPreview(doc: NoteItDoc): { title: string; preview: string } {
  const lines = plainLines(doc).map(cleanLine);
  const first = lines.findIndex((l) => l.length > 0);
  if (first < 0) return { title: '', preview: '' };
  return {
    title: prefixGraphemes(lines[first]!, TITLE_LENGTH),
    preview: prefixGraphemes(
      lines
        .slice(first + 1)
        .filter((l) => l.length > 0)
        .join(' '),
      PREVIEW_LENGTH,
    ),
  };
}

export const deriveTitle = (doc: NoteItDoc) => deriveTitleAndPreview(doc).title;
export const derivePreview = (doc: NoteItDoc) => deriveTitleAndPreview(doc).preview;

const SEGMENT = String.raw`[\p{L}_][\p{L}\p{M}\p{N}_\-]*`;
const TAG_RE = new RegExp(String.raw`(?<![^\s\p{Ps}\p{Pi},;"'])#(${SEGMENT}(?:\/${SEGMENT}){0,4})`, 'gu');

/** The full native text with code and link ranges blanked, as `NoteStore.maskedForTokens`. */
export function maskedText(doc: NoteItDoc): string {
  const parts: string[] = [];
  for (const item of paragraphs(doc)) {
    if (item.kind === 'line') parts.push(mask(item.p.runs));
    else for (const row of item.rows) for (const cell of row.cells) parts.push(mask(cell.runs));
  }
  return parts.join('\n');
}

export function tagsIn(maskedNfc: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const m of maskedNfc.normalize('NFC').matchAll(TAG_RE)) {
    const tag = m[1]!.normalize('NFC').toLowerCase().normalize('NFC');
    if (!seen.has(tag)) {
      seen.add(tag);
      out.push(tag);
    }
  }
  return out;
}

export function deriveTags(doc: NoteItDoc): string[] {
  return tagsIn(maskedText(doc));
}

/** The text search runs over: every line, tables included. */
export function searchableText(doc: NoteItDoc): string {
  const parts: string[] = [];
  for (const item of paragraphs(doc)) {
    if (item.kind === 'line') parts.push(join(item.p.runs));
    else for (const row of item.rows) for (const cell of row.cells) parts.push(join(cell.runs));
  }
  return parts.join('\n');
}

export function conflictTitleSuffix(deviceName: string, modifiedAt: Date, locale?: string): string {
  const when = new Intl.DateTimeFormat(locale, { dateStyle: 'short', timeStyle: 'short' }).format(modifiedAt);
  return ` (conflict — ${deviceName}, ${when})`;
}

function lineText(block: Block): string | undefined {
  switch (block.type) {
    case 'paragraph':
    case 'heading':
    case 'codeBlock':
    case 'listItem':
      return join(inlineRuns(block.content, false));
    default:
      return undefined;
  }
}

/** Appends `suffix` to the first non-blank line with that line's last marks; a blank body gets "Untitled" + suffix. */
export function withConflictSuffix(doc: NoteItDoc, suffix: string): NoteItDoc {
  const copy = JSON.parse(JSON.stringify(doc)) as NoteItDoc;
  const visit = (block: Block): boolean => {
    if (block.type === 'blockquote') return block.content.some((p) => visit(p));
    const text = lineText(block);
    if (text === undefined || text.replace(/￼/g, '').trim().length === 0) return false;
    const target = block as { content?: Inline[] };
    const content = target.content ?? [];
    const last = [...content].reverse().find((n): n is Extract<Inline, { type: 'text' }> => n.type === 'text');
    content.push(last?.marks ? { type: 'text', text: suffix, marks: last.marks } : { type: 'text', text: suffix });
    target.content = content;
    return true;
  };
  for (const block of copy.content) if (visit(block)) return copy;
  copy.content.unshift({ type: 'paragraph', content: [{ type: 'text', text: `Untitled${suffix}` }] });
  return copy;
}
