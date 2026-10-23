/**
 * Markdown import, as native `MarkdownImporter` + `MarkdownReader.note(from:fallbackTitle:)`: the shared reader,
 * a title from front matter, the first Title line or the file name, front matter tags the text lacks added as a
 * last line, and dates from front matter (else the file's).
 */
import { deriveTags } from './derive.js';
import { parseMarkdown, resolveMarkdownAttachments, type FrontMatter } from './markdown-read.js';
import type { Block, BodyContainer, Inline } from './schema.js';

export interface ImportedNote {
  title: string;
  body: BodyContainer;
  created?: Date;
  updated?: Date;
  pinned: boolean;
  /** Images and files the Markdown named that weren't among the chosen files. */
  missingAttachments: number;
}

const inlineText = (content: Inline[] | undefined) => (content ?? []).map((n) => (n.type === 'text' ? n.text : '')).join('');

/** `title:` from the front matter's other keys (native MarkdownFrontMatter.title), unquoted. */
export function frontMatterTitle(fm: FrontMatter): string | undefined {
  const m = /^title:[ \t]*(.*)$/im.exec(fm.extra);
  if (!m) return undefined;
  let v = m[1]!.trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  return v || undefined;
}

export function importMarkdown(
  text: string,
  opts: { fallbackTitle: string; txt?: boolean; read?: (path: string) => Uint8Array | undefined; resolveNoteLink?: (target: string) => string | undefined },
): ImportedNote {
  const heading = (t: string): Block => ({ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: t }] });
  if (opts.txt) {
    // Plain text: the first line is the title when there is one, else the file name.
    const lines = text.replace(/\r\n?/g, '\n').split('\n');
    const first = lines[0]?.trim() ?? '';
    const title = first || opts.fallbackTitle;
    const rest = first ? lines.slice(1) : lines;
    const content: Block[] = [...(title ? [heading(title)] : []), ...rest.map((l): Block => (l ? { type: 'paragraph', content: [{ type: 'text', text: l }] } : { type: 'paragraph' }))];
    return { title, body: { format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content } }, pinned: false, missingAttachments: 0 };
  }
  const parsed = parseMarkdown(text, { ...(opts.resolveNoteLink ? { resolveNoteLink: opts.resolveNoteLink } : {}) });
  const resolved = resolveMarkdownAttachments(parsed, opts.read ?? (() => undefined));
  const body = resolved.body;
  const blocks = [...(body.doc.content ?? [])];
  const first = blocks.find((b) => !(b.type === 'paragraph' && !inlineText(b.content).trim()));
  const firstTitle = first?.type === 'heading' && first.attrs.level === 1 ? inlineText(first.content).trim() : undefined;
  const fmTitle = frontMatterTitle(parsed.frontMatter);
  let title: string;
  if (fmTitle) {
    title = fmTitle;
    if (firstTitle?.toLowerCase() !== fmTitle.toLowerCase()) blocks.unshift(heading(fmTitle));
  } else if (firstTitle) {
    title = firstTitle;
  } else {
    title = opts.fallbackTitle;
    if (title) blocks.unshift(heading(title));
  }
  const doc = { type: 'doc' as const, content: blocks };
  const existing = new Set(deriveTags(doc));
  const missing = parsed.frontMatter.tags.filter((t) => !existing.has(t.toLowerCase()));
  if (missing.length) blocks.push({ type: 'paragraph', content: [{ type: 'text', text: missing.map((t) => `#${t}`).join(' ') }] });
  return {
    title,
    body: { ...body, doc },
    ...(parsed.frontMatter.created ? { created: parsed.frontMatter.created } : {}),
    ...(parsed.frontMatter.updated ? { updated: parsed.frontMatter.updated } : {}),
    pinned: parsed.frontMatter.pinned,
    missingAttachments: resolved.unresolvedImages.length,
  };
}
