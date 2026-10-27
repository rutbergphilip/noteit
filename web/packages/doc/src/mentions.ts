/**
 * Unlinked mentions (native MentionFinder): whole-word, case- diacritic- and width-insensitive matches of a note's
 * title in plain text (not links or code) after a note's first line, and turning them into links.
 */
import { searchFold } from './search.js';
import { parseDailyTitle } from './daily.js';
import { NOTE_LINK_MAX_TEXT } from './linking.js';
import { parseNoteLink, type Inline, type NoteItDoc } from './schema.js';

export const MENTION_MIN_TITLE = 3;

/** Titles shorter than 3 characters, and daily note titles, aren't searched for (mentionsAreSearched). */
export function mentionsAreSearched(title: string): boolean {
  const t = title.trim();
  return [...t].length >= MENTION_MIN_TITLE && !parseDailyTitle(t);
}

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
const isWordChar = (g: string | undefined) => !!g && /^[\p{L}\p{N}]/u.test(g);
const nodeText = (n: Inline): string => (n.type === 'text' ? n.text : n.type === 'hardBreak' ? '\n' : '￼');
const plain = (n: Inline) => n.type === 'text' && !(n.marks ?? []).some((m) => m.type === 'code' || m.type === 'link');

/** [start, end) UTF-16 ranges of whole-word, plain-text matches of `title` in one line's inline content. */
export function mentionRanges(content: Inline[] | undefined, title: string): [number, number][] {
  const needle = searchFold(title.trim());
  if (!needle || !content?.length) return [];
  const text = content.map(nodeText).join('');
  const plainAt: boolean[] = [];
  for (const n of content) for (let i = 0; i < nodeText(n).length; i++) plainAt.push(plain(n));
  // Fold grapheme by grapheme, keeping where each folded piece came from.
  const graphemes = Array.from(segmenter.segment(text));
  let folded = '';
  const from: number[] = [];
  const to: number[] = [];
  graphemes.forEach((g) => {
    const f = searchFold(g.segment);
    for (let i = 0; i < f.length; i++) {
      from.push(g.index);
      to.push(g.index + g.segment.length);
    }
    folded += f;
  });
  const out: [number, number][] = [];
  for (let at = folded.indexOf(needle); at >= 0; at = folded.indexOf(needle, at + 1)) {
    const start = from[at]!;
    const end = to[at + needle.length - 1]!;
    if (at > 0 && from[at - 1] === start) continue; // starts inside a grapheme
    const before = graphemes.find((g) => g.index + g.segment.length === start)?.segment;
    const after = graphemes.find((g) => g.index === end)?.segment;
    if (isWordChar(before) || isWordChar(after)) continue;
    if (plainAt.slice(start, end).every(Boolean)) out.push([start, end]);
  }
  return out;
}

/** Every inline line of a doc in order, with a setter; the first line (the title) is index 0. */
function lines(doc: NoteItDoc, withCode = false): { content: Inline[] | undefined; set: (c: Inline[]) => void }[] {
  const out: { content: Inline[] | undefined; set: (c: Inline[]) => void }[] = [];
  const holder = (node: { content?: Inline[] }) => out.push({ content: node.content, set: (c) => (node.content = c) });
  for (const block of doc.content ?? []) {
    switch (block.type) {
      case 'paragraph':
      case 'heading':
      case 'listItem':
        holder(block);
        break;
      case 'codeBlock':
        if (withCode) holder(block);
        else out.push({ content: undefined, set: () => undefined });
        break;
      case 'blockquote':
        for (const p of block.content ?? []) holder(p);
        break;
      case 'table':
        for (const row of block.content ?? []) for (const cell of row.content) for (const p of cell.content ?? []) holder(p);
        break;
      default:
        out.push({ content: undefined, set: () => undefined });
    }
  }
  return out;
}

/** The mentions in a note: up to 3 lines of context and the total count. */
export function findMentions(doc: NoteItDoc, title: string): { contexts: string[]; count: number } {
  const contexts: string[] = [];
  let count = 0;
  lines(doc).forEach((line, i) => {
    if (i === 0) return;
    const ranges = mentionRanges(line.content, title);
    count += ranges.length;
    if (ranges.length && contexts.length < 3) contexts.push((line.content ?? []).map(nodeText).join('').replace(/\s+/g, ' ').trim().slice(0, 160));
  });
  return { contexts, count };
}

/** The doc with every mention linked to `href`, keeping its text and other formatting; undefined when none. */
export function linkMentions(doc: NoteItDoc, title: string, href: string): NoteItDoc | undefined {
  const copy = JSON.parse(JSON.stringify(doc)) as NoteItDoc;
  let changed = false;
  lines(copy).forEach((line, i) => {
    if (i === 0 || !line.content) return;
    const ranges = mentionRanges(line.content, title);
    if (!ranges.length) return;
    const out: Inline[] = [];
    let offset = 0;
    for (const n of line.content) {
      const len = nodeText(n).length;
      if (n.type !== 'text') {
        out.push(n);
        offset += len;
        continue;
      }
      // Split this text node at range edges, linking the parts inside a range.
      const cuts = new Set([0, len]);
      for (const [s, e] of ranges) {
        if (s > offset && s < offset + len) cuts.add(s - offset);
        if (e > offset && e < offset + len) cuts.add(e - offset);
      }
      const points = [...cuts].sort((a, b) => a - b);
      for (let k = 0; k + 1 < points.length; k++) {
        const a = points[k]!;
        const b = points[k + 1]!;
        const inside = ranges.some(([s, e]) => offset + a >= s && offset + b <= e);
        const piece: Inline = { ...n, text: n.text.slice(a, b) };
        if (inside) piece.marks = [...(n.marks ?? []), { type: 'link', attrs: { href } }] as typeof n.marks;
        out.push(piece);
      }
      offset += len;
    }
    line.set(out);
    changed = true;
  });
  return changed ? copy : undefined;
}

// MARK: Update links on rename (native NoteStore.linkTextRanges / rewriteLinkText)

const linkHref = (n: Inline): string | undefined => (n.type === 'text' ? n.marks?.find((m) => m.type === 'link')?.attrs.href : undefined);

/** Whether `href` is a link to the note `id` itself (no heading), as native's `.note(id:, heading: nil)`. */
function linksToNote(href: string, id: string): boolean {
  const parsed = parseNoteLink(href);
  return !!parsed && 'id' in parsed && parsed.id.toUpperCase() === id.toUpperCase() && !parsed.heading;
}

/**
 * The doc with the text of every link to note `id` that reads `oldTitle` (trimmed, case-, diacritic- and
 * width-insensitive) replaced by `newTitle`, keeping the link's formatting; undefined when there's none.
 */
export function rewriteLinkText(doc: NoteItDoc, id: string, oldTitle: string, newTitle: string): { doc: NoteItDoc; count: number } | undefined {
  const wanted = searchFold(oldTitle.trim());
  const replacement = [...newTitle.trim()].slice(0, NOTE_LINK_MAX_TEXT).join('');
  if (!wanted || !replacement) return undefined;
  const copy = JSON.parse(JSON.stringify(doc)) as NoteItDoc;
  let count = 0;
  for (const line of lines(copy, true)) {
    const content = line.content;
    if (!content?.some((n) => linkHref(n))) continue;
    const out: Inline[] = [];
    let changed = false;
    for (let i = 0; i < content.length; ) {
      const href = linkHref(content[i]!);
      if (!href || !linksToNote(href, id)) {
        out.push(content[i]!);
        i += 1;
        continue;
      }
      // A link is the run of text nodes carrying the same href.
      let j = i;
      while (j < content.length && linkHref(content[j]!) === href) j += 1;
      const run = content.slice(i, j) as Extract<Inline, { type: 'text' }>[];
      if (searchFold(run.map((n) => n.text).join('').trim()) === wanted) {
        out.push({ ...run[0]!, text: replacement });
        count += 1;
        changed = true;
      } else out.push(...run);
      i = j;
    }
    if (changed) line.set(out);
  }
  return count ? { doc: copy, count } : undefined;
}

