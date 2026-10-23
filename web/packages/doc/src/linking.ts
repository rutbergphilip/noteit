/**
 * `[[` links, as native types them (NoteItCore/NoteLink.swift LinkQuery and NoteLink.url,
 * NoteItTextView+Links.swift): `[[Title]]`, `[[Title#Heading]]`, `[[Title|shown text]]`.
 */
import { fuzzyEvaluate, fuzzyQuery } from './fuzzy.js';
import { searchFold } from './search.js';

export const NOTE_LINK_MAX_TEXT = 120;
/** `[[…]` before the closing `]` is typed (native wikiLinkRegex). */
export const WIKI_LINK_TRIGGER = /\[\[([^[\]\n]{1,240})\]$/;
/** `[[` and what's typed after it, while the suggestion list is open. */
export const WIKI_LINK_OPEN = /\[\[([^[\]\n]{0,240})$/;

export interface LinkQuery {
  title: string;
  heading?: string;
  alias?: string;
}

/** `title#heading|alias`: heading after the first `#`, alias after the first `|`; parts trimmed, empty → absent. */
export function parseLinkQuery(raw: string): LinkQuery {
  let head = raw;
  let alias: string | undefined;
  const bar = head.indexOf('|');
  if (bar >= 0) {
    alias = head.slice(bar + 1);
    head = head.slice(0, bar);
  }
  let heading: string | undefined;
  const hash = head.indexOf('#');
  if (hash >= 0) {
    heading = head.slice(hash + 1);
    head = head.slice(0, hash);
  }
  const trim = (s: string | undefined) => {
    const t = s?.replace(/^[ \t]+|[ \t]+$/g, '');
    return t ? t : undefined;
  };
  const q: LinkQuery = { title: trim(head) ?? '' };
  const h = trim(heading);
  const a = trim(alias);
  if (h) q.heading = h;
  if (a) q.alias = a;
  return q;
}

// URLComponents' query-allowed set without `&`, `=`, `+` and `#` (NoteLink.valueAllowed).
const VALUE_ALLOWED = /[A-Za-z0-9!$'()*,\-./:;?@_~]/;
function encodeValue(value: string): string {
  let out = '';
  for (const ch of value) {
    if (VALUE_ALLOWED.test(ch)) out += ch;
    else for (const b of new TextEncoder().encode(ch)) out += `%${b.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return out;
}

/** Native `NoteLink.url`: `noteit://note/<ID>[?heading=…]` or `noteit://note?title=…[&heading=…]`. */
export function noteLinkURL(link: { id: string; heading?: string } | { title: string; heading?: string }): string {
  const heading = link.heading ? `heading=${encodeValue(link.heading.slice(0, NOTE_LINK_MAX_TEXT))}` : '';
  if ('id' in link) return `noteit://note/${link.id.toUpperCase()}${heading ? `?${heading}` : ''}`;
  return `noteit://note?title=${encodeValue(link.title.slice(0, NOTE_LINK_MAX_TEXT))}${heading ? `&${heading}` : ''}`;
}

export interface LinkTarget {
  id: string;
  title: string;
  notebookID?: string;
  updatedAt: string;
  deletedAt?: string;
}

/** Native `noteID(forTitle:preferring:)`: same folded title, the same notebook first, then the most recently edited. */
export function noteIDForTitle(notes: LinkTarget[], title: string, preferNotebook?: string): string | undefined {
  const key = searchFold(title.trim());
  if (!key) return undefined;
  const hits = notes.filter((n) => !n.deletedAt && searchFold(n.title.trim()) === key);
  const newest = (xs: LinkTarget[]) => xs.sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt))[0]?.id;
  return (preferNotebook && newest(hits.filter((n) => n.notebookID === preferNotebook))) || newest(hits);
}

/**
 * What typing `[[inner]` + `]` becomes (handleWikiLinkTrigger): the link and the text shown, or undefined when
 * there's no title. An empty title links to a heading in this note.
 */
export function wikiLink(inner: string, ctx: { notes: LinkTarget[]; noteID: string; noteTitle: string; notebookID?: string }): { href: string; text: string } | undefined {
  const q = parseLinkQuery(inner);
  const title = (q.title || ctx.noteTitle).slice(0, NOTE_LINK_MAX_TEXT);
  if (!title.trim()) return undefined;
  const heading = q.heading?.slice(0, NOTE_LINK_MAX_TEXT);
  let href: string;
  if (!q.title) href = noteLinkURL({ id: ctx.noteID, ...(heading ? { heading } : {}) });
  else {
    const id = noteIDForTitle(ctx.notes, title, ctx.notebookID);
    href = id && (id !== ctx.noteID || heading) ? noteLinkURL({ id, ...(heading ? { heading } : {}) }) : noteLinkURL({ title, ...(heading ? { heading } : {}) });
  }
  const text = q.alias ?? (heading ? (q.title ? `${q.title} › ${heading}` : heading) : q.title);
  return { href, text };
}

/** Notes for the `[[` list: live, titled, not this one; fuzzy title matches first, then recency. */
export function linkSuggestions(notes: LinkTarget[], typed: string, opts: { exclude?: string; limit?: number } = {}): LinkTarget[] {
  const live = notes.filter((n) => !n.deletedAt && n.id !== opts.exclude && n.title.trim());
  const q = fuzzyQuery(typed.split(/[#|]/)[0] ?? '');
  const scored = live.flatMap((n) => {
    const r = fuzzyEvaluate(q, n.title);
    return r ? [{ n, score: r.match.score }] : [];
  });
  return scored
    .sort((a, b) => b.score - a.score || Date.parse(b.n.updatedAt) - Date.parse(a.n.updatedAt))
    .slice(0, opts.limit ?? 8)
    .map((x) => x.n);
}
