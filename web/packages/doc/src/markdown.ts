/**
 * noteit-doc → Markdown, for Export (the "portable" profile of Swift `MarkdownCodec`: clean Markdown with no
 * NoteIt comments or font sizes). Links to notes become `[[wiki links]]`, as native export writes them. The
 * Swift codec's fixtures in `Tests/NoteItMarkdownTests/Fixtures` that carry no library-only syntax are this
 * writer's conformance tests.
 */
import { listRuns } from './list-runs.js';
import { type Block, type Inline, type Mark, type NoteItDoc, type ParagraphNode, parseNoteLink } from './schema.js';

export interface MarkdownOptions {
  /** Where an attachment is written; defaults to `_attachments/<sha prefix>-<name>`. */
  attachmentPath?: (sha: string, name: string) => string;
  /** A linked note's name for `[[Name]]`; undefined → the link's own text. */
  noteName?: (id: string) => string | undefined;
}

/** Native's yellow highlight, written as `==text==`. */
export const HIGHLIGHT_YELLOW = '#FFED8C';
const YELLOW = HIGHLIGHT_YELLOW;

export function defaultAttachmentPath(sha: string, name: string): string {
  return `_attachments/${sha.slice(0, 12)}-${name}`;
}

function escapeText(text: string, lineStart: boolean, inTable: boolean): string {
  let s = text
    .replace(/\\/g, '\\\\')
    .replace(/([*`<])/g, '\\$1')
    .replace(/\[\[/g, '\\[[')
    .replace(/~~/g, '\\~~')
    .replace(/==/g, '\\==');
  if (inTable) s = s.replace(/\|/g, '\\|');
  if (lineStart) {
    if (/^(#{1,6}|[-+>])(\s|$)/.test(s)) s = `\\${s}`;
    else s = s.replace(/^(\d+)([.)])(?=\s|$)/, '$1\\$2');
  }
  return s;
}

type Wrap = { key: string; open: string; close: string };

function wrapFor(mark: Mark): Wrap | undefined {
  switch (mark.type) {
    case 'bold':
      return { key: 'bold', open: '**', close: '**' };
    case 'italic':
      return { key: 'italic', open: '*', close: '*' };
    case 'strike':
      return { key: 'strike', open: '~~', close: '~~' };
    case 'underline':
      return { key: 'underline', open: '<u>', close: '</u>' };
    case 'highlight': {
      const c = mark.attrs.color.toUpperCase();
      return c === YELLOW ? { key: 'hl', open: '==', close: '==' } : { key: `hl${c}`, open: `<mark style="background-color: ${c}">`, close: '</mark>' };
    }
    case 'textColor': {
      const c = mark.attrs.color.toUpperCase();
      return { key: `color${c}`, open: `<span style="color: ${c}">`, close: '</span>' };
    }
    default:
      return undefined;
  }
}

class InlineWriter {
  constructor(
    private readonly opts: MarkdownOptions,
    private readonly inTable: boolean,
  ) {}

  write(content: Inline[] | undefined): string {
    const nodes = content ?? [];
    let out = '';
    const stack: Wrap[] = [];
    const closeTo = (n: number) => {
      while (stack.length > n) out += stack.pop()!.close;
    };
    let i = 0;
    while (i < nodes.length) {
      const node = nodes[i]!;
      if (node.type !== 'text') {
        closeTo(0);
        if (node.type === 'hardBreak') out += '\\\n';
        else if (node.type === 'image') out += `![${node.attrs.name}${node.attrs.width ? `|${node.attrs.width}` : ''}](${this.path(node.attrs.sha, node.attrs.name)})`;
        else out += `[${node.attrs.name}](${this.path(node.attrs.sha, node.attrs.name)})`;
        i += 1;
        continue;
      }
      const marks = node.marks ?? [];
      const link = marks.find((m): m is Extract<Mark, { type: 'link' }> => m.type === 'link');
      if (link) {
        // A link spans every following run with the same href; its inner marks are written inside it.
        let j = i;
        const runs: Inline[] = [];
        while (j < nodes.length) {
          const n = nodes[j]!;
          const h = n.type === 'text' ? n.marks?.find((m) => m.type === 'link') : undefined;
          if (!h || h.type !== 'link' || h.attrs.href !== link.attrs.href) break;
          runs.push({ ...n, marks: (n as { marks?: Mark[] }).marks?.filter((m) => m.type !== 'link') } as Inline);
          j += 1;
        }
        closeTo(0);
        out += this.link(link.attrs.href, runs, out.length === 0 || out.endsWith('\n'));
        i = j;
        continue;
      }
      if (marks.some((m) => m.type === 'code')) {
        closeTo(0);
        const fence = node.text.includes('`') ? '``' : '`';
        const pad = node.text.startsWith('`') || node.text.endsWith('`') ? ' ' : '';
        out += `${fence}${pad}${node.text}${pad}${fence}`;
        i += 1;
        continue;
      }
      const wraps = marks.map(wrapFor).filter((w): w is Wrap => !!w);
      const keys = new Set(wraps.map((w) => w.key));
      const keep = stack.findIndex((w) => !keys.has(w.key));
      closeTo(keep < 0 ? stack.length : keep);
      for (const w of wraps) {
        if (stack.some((s) => s.key === w.key)) continue;
        out += w.open;
        stack.push(w);
      }
      out += escapeText(node.text, out.length === 0 || out.endsWith('\n'), this.inTable);
      i += 1;
    }
    closeTo(0);
    return out;
  }

  private path(sha: string, name: string): string {
    return (this.opts.attachmentPath ?? defaultAttachmentPath)(sha, name).replace(/ /g, '%20');
  }

  private link(href: string, runs: Inline[], lineStart: boolean): string {
    const text = runs.map((r) => (r.type === 'text' ? r.text : '')).join('');
    const note = parseNoteLink(href);
    if (note) {
      const target = 'id' in note ? (this.opts.noteName?.(note.id) ?? text) : note.title;
      let s = `[[${target}`;
      const heading = new URL(href).searchParams.get('heading');
      if (heading) s += `#${heading}`;
      if (text && text !== target) s += `${this.inTable ? '\\|' : '|'}${text}`;
      return `${s}]]`;
    }
    if (text === href && runs.every((r) => r.type === 'text' && !r.marks?.length)) return href;
    const inner = new InlineWriter(this.opts, this.inTable).write(runs);
    void lineStart;
    return `[${inner}](${href.replace(/ /g, '%20').replace(/\)/g, '%29')})`;
  }
}

function listPrefix(attrs: Extract<Block, { type: 'listItem' }>['attrs']): string {
  const indent = '    '.repeat(Math.max(0, attrs.level));
  if (attrs.kind === 'ordered') return `${indent}${attrs.number ?? 1}. `;
  if (attrs.kind === 'task') return `${indent}- [${attrs.checked ? 'x' : ' '}] `;
  return `${indent}- `;
}

function codeText(content: Inline[] | undefined): string {
  return (content ?? []).map((n) => (n.type === 'text' ? n.text : n.type === 'hardBreak' ? '\n' : '')).join('');
}

/** The note as portable Markdown, ending in a newline. */
export function docToMarkdown(doc: NoteItDoc, opts: MarkdownOptions = {}): string {
  const inline = new InlineWriter(opts, false);
  const cells = new InlineWriter(opts, true);
  // An empty paragraph is one more blank line before the next block, as the Swift codec writes it (and reads back).
  const chunks: { text: string; list: boolean; newList?: boolean; emptiesBefore: number }[] = [];
  const newList = listRuns();
  let empties = 0;
  const take = () => {
    const n = empties;
    empties = 0;
    return n;
  };
  const blocks = doc.content;
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i]!;
    switch (b.type) {
      case 'paragraph':
        if (!b.content?.length) empties += 1;
        else chunks.push({ text: inline.write(b.content), list: false, emptiesBefore: take() });
        break;
      case 'heading':
        chunks.push({ text: `${'#'.repeat(b.attrs.level)} ${inline.write(b.content)}`, list: false, emptiesBefore: take() });
        break;
      case 'codeBlock': {
        // Consecutive code blocks in one language are one fenced block, a line each.
        const language = b.attrs?.language ?? '';
        const lines = [codeText(b.content)];
        while (blocks[i + 1]?.type === 'codeBlock' && ((blocks[i + 1] as { attrs?: { language?: string } }).attrs?.language ?? '') === language && language) {
          i += 1;
          lines.push(codeText((blocks[i] as { content?: Inline[] }).content));
        }
        const body = lines.join('\n');
        const fence = body.includes('```') ? '````' : '```';
        chunks.push({ text: `${fence}${language}\n${body}\n${fence}`, list: false, emptiesBefore: take() });
        break;
      }
      case 'blockquote':
        chunks.push({ text: b.content.map((p: ParagraphNode) => `> ${inline.write(p.content)}`.trimEnd()).join('\n>\n'), list: false, emptiesBefore: take() });
        break;
      case 'horizontalRule':
        chunks.push({ text: '---', list: false, emptiesBefore: take() });
        break;
      case 'listItem':
        chunks.push({ text: `${listPrefix(b.attrs)}${inline.write(b.content)}`, list: true, newList: newList(b), emptiesBefore: take() });
        break;
      case 'table': {
        const rows = b.content ?? [];
        const width = Math.max(1, ...rows.map((r) => r.content.length));
        const cellText = (c: { content: ParagraphNode[] } | undefined) => (c ? c.content.map((p) => cells.write(p.content)).join('<br>') : '');
        const line = (texts: string[]) => `| ${texts.join(' | ')} |`;
        const hasHeader = rows.length > 0 && rows[0]!.content.every((c) => c.type === 'tableHeader');
        const header = hasHeader ? Array.from({ length: width }, (_, k) => cellText(rows[0]!.content[k])) : Array.from({ length: width }, () => '');
        const out = [hasHeader ? line(header) : `|${' '.repeat(2)}${'|  '.repeat(width - 1)}|`, line(Array.from({ length: width }, () => '---'))];
        for (const r of rows.slice(hasHeader ? 1 : 0)) out.push(line(Array.from({ length: width }, (_, k) => cellText(r.content[k]))));
        chunks.push({ text: out.join('\n'), list: false, emptiesBefore: take() });
        break;
      }
      default:
        break;
    }
  }
  let md = '';
  chunks.forEach((c, k) => {
    if (k > 0) md += c.list && chunks[k - 1]!.list && !c.newList ? '\n' : '\n\n';
    md += '\n'.repeat(c.emptiesBefore) + c.text;
  });
  return md ? `${md.replace(/\n+$/, '')}\n` : '';
}
