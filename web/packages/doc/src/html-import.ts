/**
 * HTML → noteit-doc blocks for importers, as native `AppleNotesImporter.convert(html:title:)` (which the Evernote
 * importer also uses): headings by size (h1 Title, h2 Heading, h3 Subheading), monospaced paragraphs as code,
 * nested lists with their numbers, tables as plain-text cells with a header row, and only bold, italic, underline,
 * strikethrough, links and inline code kept. Fonts, colours and sizes are dropped; the note's name becomes the
 * title line unless the first line already is it. Needs a DOM (`DOMParser`), so it runs in the browser.
 */
import { isAllowedLink, type Block, type Inline, type Mark, type ParagraphNode, type TableRow } from './schema.js';

type Run = { text: string; marks: Mark[]; mono: boolean } | { node: Inline };

interface SourceParagraph {
  runs: Run[];
  list?: { level: number; ordered: boolean };
  heading?: number;
  pre: boolean;
}

interface SourceTable {
  rows: Run[][][];
}

type Source = { para: SourceParagraph } | { table: SourceTable };

export interface HtmlImportOptions {
  /** The note's name: the title line, unless the first paragraph already says it. */
  title?: string;
  /** Splits a text run into text and nodes (Evernote's resource placeholders); applied in document order. */
  expand?: (text: string) => (string | Inline)[];
  /** An embedded `data:` image as an image node (native `extractImages`); undefined drops it. */
  dataImage?: (bytes: Uint8Array, ext: string, index: number) => Inline | undefined;
}

const BLOCK_TAGS = new Set([
  'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'pre', 'blockquote', 'ul', 'ol', 'table', 'tr', 'section', 'article',
  'header', 'footer', 'center', 'address', 'dl', 'dt', 'dd', 'hr', 'figure', 'figcaption', 'main', 'nav', 'aside', 'body', 'html',
]);
const SKIP_TAGS = new Set(['script', 'style', 'head', 'title', 'template', 'noscript', 'iframe', 'object', 'svg', 'math']);
const MONO_FONT = /mono|courier|menlo|consolas|monaco/i;
const MARK_ORDER = ['bold', 'italic', 'underline', 'strike', 'code', 'link'];

const visible = (s: string) => /[^\s-]/u.test(s);

function decodeBase64(b64: string): Uint8Array | undefined {
  try {
    const bin = atob(b64.replace(/&#10;|\s/g, ''));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return undefined;
  }
}

class Walker {
  sources: Source[] = [];
  private current: SourceParagraph = { runs: [], pre: false };
  private lists: { ordered: boolean }[] = [];
  private images = 0;

  constructor(private opts: HtmlImportOptions) {}

  private hasContent(p: SourceParagraph): boolean {
    return p.runs.some((r) => ('node' in r ? true : r.text.length > 0));
  }

  flush(force: boolean): void {
    if (force || this.hasContent(this.current)) this.sources.push({ para: this.current });
    const { list, heading, pre } = this.current;
    this.current = { runs: [], pre, ...(list ? { list } : {}), ...(heading ? { heading } : {}) };
  }

  /** Starts a fresh paragraph with this block's context. */
  private context(ctx: { list?: SourceParagraph['list']; heading?: number; pre: boolean }): void {
    this.current = { runs: [], pre: ctx.pre, ...(ctx.list ? { list: ctx.list } : {}), ...(ctx.heading ? { heading: ctx.heading } : {}) };
  }

  walk(node: Node, marks: Mark[], mono: boolean, ctx: { list?: SourceParagraph['list']; heading?: number; pre: boolean }, cell?: Run[]): void {
    const push = (run: Run) => (cell ? cell.push(run) : this.current.runs.push(run));
    if (node.nodeType === 3) {
      const raw = node.nodeValue ?? '';
      if (ctx.pre && !cell) {
        raw.split('\n').forEach((line, i) => {
          if (i > 0) this.flush(true);
          if (line) push({ text: line, marks, mono });
        });
      } else {
        const text = raw.replace(/[ \t\n\r\f]+/g, ' ');
        if (text) push({ text, marks, mono });
      }
      return;
    }
    if (node.nodeType !== 1) return;
    const el = node as Element;
    const tag = el.tagName.toLowerCase();
    if (SKIP_TAGS.has(tag)) return;
    if (tag === 'br') {
      if (cell) cell.push({ text: ' ', marks, mono });
      else this.flush(true);
      return;
    }
    if (tag === 'img') {
      const m = /^data:image\/([a-z0-9.+-]+);base64,(.+)$/is.exec(el.getAttribute('src') ?? '');
      const bytes = m ? decodeBase64(m[2]!) : undefined;
      if (!m || !bytes || !this.opts.dataImage) return;
      const subtype = m[1]!.toLowerCase();
      const ext = ({ jpeg: 'jpg', 'svg+xml': 'svg' } as Record<string, string>)[subtype] ?? subtype;
      const inline = this.opts.dataImage(bytes, ext, ++this.images);
      if (inline) push({ node: inline });
      return;
    }
    if (tag === 'table' && !cell) {
      this.flush(false);
      const rows: Run[][][] = [];
      for (const tr of el.querySelectorAll('tr')) {
        if (tr.closest('table') !== el) continue;
        const cells: Run[][] = [];
        for (const td of tr.children) {
          const t = td.tagName.toLowerCase();
          if (t !== 'td' && t !== 'th') continue;
          const runs: Run[] = [];
          for (const child of td.childNodes) this.walk(child, [], false, { pre: false }, runs);
          cells.push(runs);
        }
        rows.push(cells);
      }
      if (rows.length) this.sources.push({ table: { rows } });
      this.context(ctx);
      return;
    }

    let next = marks;
    let nextMono = mono;
    const add = (m: Mark) => {
      if (!next.some((x) => x.type === m.type)) next = [...next, m];
    };
    if (tag === 'b' || tag === 'strong') add({ type: 'bold' });
    if (tag === 'i' || tag === 'em' || tag === 'cite' || tag === 'var' || tag === 'dfn') add({ type: 'italic' });
    if (tag === 'u' || tag === 'ins') add({ type: 'underline' });
    if (tag === 's' || tag === 'strike' || tag === 'del') add({ type: 'strike' });
    if (tag === 'code' || tag === 'tt' || tag === 'kbd' || tag === 'samp' || tag === 'pre') nextMono = true;
    if (tag === 'a') {
      const href = el.getAttribute('href')?.trim();
      if (href) next = [...next.filter((x) => x.type !== 'link'), { type: 'link', attrs: { href } }];
    }
    const style = (el.getAttribute('style') ?? '').toLowerCase();
    if (style) {
      if (/font-weight\s*:\s*(bold|[6-9]00)/.test(style)) add({ type: 'bold' });
      if (/font-style\s*:\s*italic/.test(style)) add({ type: 'italic' });
      if (/text-decoration(-line)?\s*:[^;]*underline/.test(style)) add({ type: 'underline' });
      if (/text-decoration(-line)?\s*:[^;]*line-through/.test(style)) add({ type: 'strike' });
      const family = /font-family\s*:([^;]*)/.exec(style)?.[1];
      if (family && MONO_FONT.test(family)) nextMono = true;
    }
    if (tag === 'font' && MONO_FONT.test(el.getAttribute('face') ?? '')) nextMono = true;

    const block = BLOCK_TAGS.has(tag) && !cell;
    let inner = ctx;
    if (block) {
      this.flush(false);
      if (tag === 'ul' || tag === 'ol') this.lists.push({ ordered: tag === 'ol' });
      if (tag === 'li') {
        const top = this.lists.at(-1);
        inner = { ...ctx, list: { level: Math.max(0, this.lists.length - 1), ordered: !!top?.ordered } };
      }
      if (/^h[1-6]$/.test(tag)) inner = { ...ctx, heading: Number(tag[1]) };
      if (tag === 'pre') inner = { ...ctx, pre: true };
      this.context(inner);
    }
    for (const child of el.childNodes) this.walk(child, next, nextMono, inner, cell);
    if (block) {
      this.flush(false);
      if (tag === 'ul' || tag === 'ol') this.lists.pop();
      this.context(ctx);
    }
  }
}

function sameMarks(a: Mark[], b: Mark[]): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

/** Runs → inline content: text merged by marks, `expand` applied, marks in a stable order. */
function inlines(runs: Run[], opts: HtmlImportOptions, markFor: (r: { marks: Mark[]; mono: boolean }) => Mark[], trim: boolean): Inline[] {
  const out: Inline[] = [];
  const pushText = (text: string, marks: Mark[]) => {
    if (!text) return;
    const last = out.at(-1);
    if (last?.type === 'text' && sameMarks(last.marks ?? [], marks)) last.text += text;
    else out.push(marks.length ? { type: 'text', text, marks } : { type: 'text', text });
  };
  const items = runs.slice();
  if (trim) {
    // Leading and trailing spaces of a line are dropped, as HTML layout does.
    while (items.length && !('node' in items[0]!) && !items[0]!.text.trim()) items.shift();
    while (items.length && !('node' in items.at(-1)!) && !(items.at(-1) as { text: string }).text.trim()) items.pop();
    const first = items[0];
    if (first && !('node' in first)) items[0] = { ...first, text: first.text.replace(/^ +/, '') };
    const last = items.at(-1);
    if (last && !('node' in last)) items[items.length - 1] = { ...last, text: last.text.replace(/ +$/, '') };
  }
  for (let i = 0; i < items.length; i++) {
    const r = items[i]!;
    if ('node' in r) {
      out.push(r.node);
      continue;
    }
    // Collapse a space that follows another (whitespace across element boundaries).
    let text = r.text;
    const prev = out.at(-1);
    if (trim && prev?.type === 'text' && prev.text.endsWith(' ') && text.startsWith(' ')) text = text.slice(1);
    const marks = markFor(r)
      .filter((m) => m.type !== 'link' || isAllowedLink(m.attrs.href) || /^evernote:/i.test(m.attrs.href))
      .sort((a, b) => MARK_ORDER.indexOf(a.type) - MARK_ORDER.indexOf(b.type));
    const parts = opts.expand ? opts.expand(text) : [text];
    for (const p of parts) {
      if (typeof p === 'string') pushText(p, marks);
      else out.push(p);
    }
  }
  return out;
}

/** Converts a note's HTML to blocks: the title line first, then its paragraphs, lists and tables. */
export function htmlToBlocks(html: string, opts: HtmlImportOptions = {}): Block[] {
  const doc = new DOMParser().parseFromString(/<html/i.test(html) ? html : `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>${html}</body></html>`, 'text/html');
  const walker = new Walker(opts);
  walker.walk(doc.body, [], false, { pre: false });
  walker.flush(false);
  const sources = walker.sources;

  const isBlank = (s: Source) => 'para' in s && !s.para.runs.some((r) => ('node' in r ? true : visible(r.text)));
  while (sources.length && isBlank(sources.at(-1)!)) sources.pop();
  while (sources.length && isBlank(sources[0]!)) sources.shift();

  const cleanTitle = (opts.title ?? '').trim();
  const first = sources[0];
  const firstText = first && 'para' in first ? first.para.runs.map((r) => ('node' in r ? '￼' : r.text)).join('').trim() : '';
  const firstIsTitle = !!first && 'para' in first && !first.para.list && (!cleanTitle || firstText.toLowerCase() === cleanTitle.toLowerCase());

  const blocks: Block[] = [];
  if (!firstIsTitle && cleanTitle) blocks.push({ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: cleanTitle }] });

  let counters = new Map<number, number>();
  sources.forEach((source, index) => {
    if ('table' in source) {
      counters = new Map();
      const columns = Math.max(...source.table.rows.map((r) => r.length));
      if (!columns) return;
      const rows: TableRow[] = source.table.rows.map((row, r) => ({
        type: 'tableRow',
        content: Array.from({ length: columns }, (_, c) => {
          const content = inlines(row[c] ?? [], opts, () => [], true);
          const para: ParagraphNode = content.length ? { type: 'paragraph', content } : { type: 'paragraph' };
          return { type: r === 0 ? 'tableHeader' : 'tableCell', content: [para] } as TableRow['content'][number];
        }),
      }));
      blocks.push({ type: 'table', content: rows });
      return;
    }
    const p = source.para;
    if (p.list) {
      const level = Math.min(8, p.list.level);
      for (const k of [...counters.keys()]) if (k > level) counters.delete(k);
      let number: number | undefined;
      if (p.list.ordered) {
        number = (counters.get(level) ?? 0) + 1;
        counters.set(level, number);
      } else counters.delete(level);
      const content = inlines(p.runs, opts, (r) => (r.mono ? [...r.marks, { type: 'code' }] : r.marks), true);
      blocks.push({ type: 'listItem', attrs: { kind: p.list.ordered ? 'ordered' : 'bullet', level, ...(number !== undefined ? { number } : {}) }, ...(content.length ? { content } : {}) });
      return;
    }
    counters = new Map();
    const visibleRuns = p.runs.filter((r): r is Extract<Run, { text: string }> => !('node' in r) && visible(r.text));
    let kind: 'title' | 'heading' | 'subheading' | 'code' | 'body' = 'body';
    if (index === 0 && firstIsTitle) kind = 'title';
    else if (p.heading === 1) kind = 'title';
    else if (p.heading === 2) kind = 'heading';
    else if (p.heading === 3) kind = 'subheading';
    else if (p.pre || (visibleRuns.length && visibleRuns.every((r) => r.mono))) kind = 'code';
    const headingLike = kind === 'title' || kind === 'heading' || kind === 'subheading';
    const boldHeading = (p.heading ?? 0) >= 4;
    const content = inlines(
      p.runs,
      opts,
      (r) => {
        let marks = r.marks;
        if (headingLike) marks = marks.filter((m) => m.type !== 'bold');
        else if (boldHeading && !marks.some((m) => m.type === 'bold')) marks = [{ type: 'bold' }, ...marks];
        if (kind !== 'code' && r.mono) marks = [...marks, { type: 'code' }];
        return marks;
      },
      kind !== 'code',
    );
    const c = content.length ? { content } : {};
    if (headingLike) blocks.push({ type: 'heading', attrs: { level: kind === 'title' ? 1 : kind === 'heading' ? 2 : 3 }, ...c });
    else if (kind === 'code') blocks.push({ type: 'codeBlock', ...c });
    else blocks.push({ type: 'paragraph', ...c });
  });
  return blocks;
}
