/**
 * Rename, merge and delete tags everywhere (native TagRewriter + QueryRewriter.renamingTag): `#tag` tokens and the
 * tags nested in them are rewritten in note text outside code and links; renaming onto a tag in use merges them.
 */
import { lexQuery } from './query.js';
import type { Block, Inline, NoteItDoc } from './schema.js';
import { isValidTagName, MAX_TAG_DEPTH, normalizedTag, tagMatches } from './tokens.js';

export type TagEdit = { type: 'rename'; from: string; to: string } | { type: 'delete'; tag: string };

export const TAG_INVALID_NAME = 'Tags can use letters, numbers, - and _, and / to nest.';
export const TAG_INSIDE_ITSELF = 'A tag can’t be moved inside itself.';
export const TAG_TOO_DEEP = `Tags can nest up to ${MAX_TAG_DEPTH} levels, and this would put some deeper.`;

const strip = (t: string) => (t.startsWith('#') ? t.slice(1) : t);

/** Why `to` can't replace `from` (`TagRewriter.renameProblem`), or undefined. */
export function tagRenameProblem(from: string, to: string, tagsInUse: string[] = []): string | undefined {
  const target = strip(to);
  if (!isValidTagName(target)) return TAG_INVALID_NAME;
  const source = normalizedTag(from);
  const normalized = normalizedTag(target);
  if (normalized !== source && tagMatches(normalized, source)) return TAG_INSIDE_ITSELF;
  const sourceDepth = source.split('/').length;
  const deepest = Math.max(0, ...tagsInUse.map(normalizedTag).filter((t) => tagMatches(t, source)).map((t) => t.split('/').length - sourceDepth));
  if (normalized.split('/').length + deepest > MAX_TAG_DEPTH) return TAG_TOO_DEEP;
  return undefined;
}

const SEGMENT = String.raw`[\p{L}_][\p{L}\p{M}\p{N}_\-]*`;
const TAG_RE = new RegExp(String.raw`(?<![^\s\p{Ps}\p{Pi},;"'])#(${SEGMENT}(?:\/${SEGMENT}){0,4})`, 'gu');

interface TextEdit {
  start: number;
  end: number;
  replacement: string;
}

/** The edits for one line of masked text, descending (`TagRewriter.edits(for:inMasked:)`). */
export function tagEdits(edit: TagEdit, masked: string): TextEdit[] {
  const out: TextEdit[] = [];
  for (const m of masked.matchAll(TAG_RE)) {
    const start = m.index!;
    const end = start + m[0].length;
    const tag = normalizedTag(m[1]!);
    if (edit.type === 'rename') {
      const source = normalizedTag(edit.from);
      if (!tagMatches(tag, source)) continue;
      const rest = m[1]!.split('/').slice(source.split('/').length);
      const replacement = `#${[strip(edit.to), ...rest].join('/')}`;
      if (replacement !== m[0]) out.push({ start, end, replacement });
    } else {
      if (!tagMatches(tag, normalizedTag(edit.tag))) continue;
      // The token and one space next to it, preferring the one after.
      if (end < masked.length && (masked[end] === ' ' || masked[end] === '\t')) out.push({ start, end: end + 1, replacement: '' });
      else if (start > 0 && (masked[start - 1] === ' ' || masked[start - 1] === '\t')) out.push({ start: start - 1, end, replacement: '' });
      else out.push({ start, end, replacement: '' });
    }
  }
  return out.sort((a, b) => b.start - a.start);
}

const nodeText = (n: Inline): string => (n.type === 'text' ? n.text : n.type === 'hardBreak' ? ' ' : '￼');
const maskedNode = (n: Inline): boolean => n.type === 'text' && (n.marks ?? []).some((m) => m.type === 'code' || m.type === 'link');

/** Replaces [start, end) of the inline content's text; the replacement takes the first touched text node's marks. */
function spliceInline(content: Inline[], start: number, end: number, replacement: string): Inline[] {
  const out: Inline[] = [];
  let offset = 0;
  let placed = false;
  for (const n of content) {
    const text = nodeText(n);
    const a = offset;
    const b = offset + text.length;
    offset = b;
    if (b <= start || a >= end || (a === b && a !== start)) {
      out.push(n);
      continue;
    }
    if (n.type !== 'text') {
      out.push(n);
      continue;
    }
    const before = n.text.slice(0, Math.max(0, start - a));
    const after = n.text.slice(Math.max(0, end - a));
    const piece = before + (placed ? '' : replacement) + after;
    placed = true;
    if (piece) out.push({ ...n, text: piece });
  }
  return out;
}

function rewriteInline(content: Inline[] | undefined, edit: TagEdit): Inline[] | undefined {
  if (!content?.length) return undefined;
  const masked = content.map((n) => (maskedNode(n) ? ' '.repeat(nodeText(n).length) : nodeText(n))).join('');
  const edits = tagEdits(edit, masked);
  if (!edits.length) return undefined;
  let next = content;
  for (const e of edits) next = spliceInline(next, e.start, e.end, e.replacement);
  return next;
}

/** The document with `edit` applied to every line outside code blocks, or undefined when nothing changes. */
export function rewriteTags(doc: NoteItDoc, edit: TagEdit): NoteItDoc | undefined {
  let changed = false;
  const inline = <T extends { content?: Inline[] }>(node: T): T => {
    const next = rewriteInline(node.content, edit);
    if (!next) return node;
    changed = true;
    const copy = { ...node };
    if (next.length) copy.content = next;
    else delete copy.content;
    return copy;
  };
  const content = (doc.content ?? []).map((block): Block => {
    switch (block.type) {
      case 'paragraph':
      case 'heading':
      case 'listItem':
        return inline(block);
      case 'blockquote':
        return { ...block, content: (block.content ?? []).map(inline) };
      case 'table':
        return {
          ...block,
          content: (block.content ?? []).map((row) => ({ ...row, content: row.content.map((cell) => ({ ...cell, content: (cell.content ?? []).map(inline) })) })),
        } as Block;
      default:
        return block;
    }
  });
  return changed ? { ...doc, content } : undefined;
}

/** `tag:` values naming `from` or a tag nested in it, renamed (QueryRewriter.renamingTag). */
export function renameTagInQuery(from: string, to: string, query: string): string {
  const old = normalizedTag(strip(from));
  const target = strip(to);
  let result = query;
  for (const lx of [...lexQuery(query)].reverse()) {
    if (lx.kind !== 'term' || lx.key !== 'tag') continue;
    const raw = query.slice(lx.start, lx.end);
    const colon = raw.indexOf(':');
    const valueStart = lx.start + colon + 1 + (lx.quoted ? 1 : 0);
    const valueEnd = lx.quoted && query[lx.end - 1] === '"' ? lx.end - 1 : lx.end;
    const value = query.slice(valueStart, valueEnd);
    const hash = value.startsWith('#') ? '#' : '';
    const name = normalizedTag(value.slice(hash.length));
    let next: string | undefined;
    if (name === old) next = hash + target;
    else if (name.startsWith(`${old}/`)) next = hash + target + name.slice(old.length);
    if (next === undefined) continue;
    const needsQuotes = !lx.quoted && /[\s"()]/.test(next);
    result = result.slice(0, valueStart) + (needsQuotes ? `"${next}"` : next) + result.slice(valueEnd);
  }
  return result;
}
