/**
 * Search highlights and snippets (native NoteItCore SearchHighlighter, spec 5.3): folded terms found in the original
 * text, as UTF-16 [start, end) ranges, and the best window of a note's text around them for the note list.
 */
import { searchFold } from './search.js';

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

export type TextRange = [start: number, end: number];

export interface Snippet {
  text: string;
  highlights: TextRange[];
}

/** Ranges of each term, in original UTF-16 offsets. Each character is folded on its own, keeping a map back. */
function termRanges(terms: readonly string[], text: string): TextRange[][] {
  if (!terms.some((t) => t) || !text) return terms.map(() => []);
  let folded = '';
  const starts: number[] = [];
  const ends: number[] = [];
  let offset = 0;
  for (const { segment } of segmenter.segment(text)) {
    const width = segment.length;
    const code = segment.charCodeAt(0);
    const piece = width === 1 && code < 128 ? (code >= 65 && code <= 90 ? String.fromCharCode(code + 32) : segment) : searchFold(segment);
    for (let k = 0; k < piece.length; k++) {
      starts.push(offset);
      ends.push(offset + width);
    }
    folded += piece;
    offset += width;
  }
  return terms.map((term) => {
    const out: TextRange[] = [];
    if (!term) return out;
    for (let at = folded.indexOf(term); at >= 0; at = folded.indexOf(term, at + term.length)) out.push([starts[at]!, ends[at + term.length - 1]!]);
    return out;
  });
}

function merge(ranges: TextRange[]): TextRange[] {
  const out: TextRange[] = [];
  for (const r of [...ranges].sort((a, b) => a[0] - b[0])) {
    const last = out[out.length - 1];
    if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1]);
    else out.push([r[0], r[1]]);
  }
  return out;
}

/** Where the folded `terms` occur in `text`, merged. */
export function searchHighlightRanges(terms: readonly string[], text: string): TextRange[] {
  return merge(termRanges(terms, text).flat());
}

const isSpace = (c: number) => c === 0x20 || c === 0x09 || c === 0x0a || c === 0x0d;
/** Keeps a boundary off the middle of a surrogate pair. */
function adjusted(text: string, index: number, forward: boolean): number {
  if (index <= 0 || index >= text.length) return index;
  const c = text.charCodeAt(index);
  if (c < 0xdc00 || c > 0xdfff) return index;
  return forward ? index + 1 : index - 1;
}

/**
 * The window of `maxLength` UTF-16 units with the most distinct terms, preferring a line or sentence start, with `…`
 * on cut sides; undefined when no term occurs.
 */
export function searchSnippet(text: string, terms: readonly string[], maxLength: number): Snippet | undefined {
  const all = termRanges(terms, text)
    .flatMap((ranges, term) => ranges.map((range) => ({ range, term })))
    .sort((a, b) => a.range[0] - b.range[0]);
  const firstHit = all[0];
  if (!firstHit || maxLength <= 0) return undefined;
  const length = text.length;
  let bestStart = firstHit.range[0];
  let bestCount = 0;
  for (const hit of all) {
    const start = hit.range[0];
    const end = start + maxLength;
    const distinct = new Set(all.filter((h) => h.range[0] >= start && h.range[1] <= end).map((h) => h.term)).size;
    if (distinct > bestCount) {
      bestCount = distinct;
      bestStart = start;
    }
  }
  // Back up to a line or sentence start close before the match, else to a word start.
  const lookBack = Math.max(0, bestStart - Math.min(40, Math.trunc(maxLength / 3)));
  let start = bestStart;
  let foundBoundary = false;
  for (let i = bestStart; i > lookBack; i--) {
    const c = text.charCodeAt(i - 1);
    if (c === 0x0a || c === 0x0d || (i >= 2 && c === 0x20 && [0x2e, 0x21, 0x3f].includes(text.charCodeAt(i - 2)))) {
      start = i;
      foundBoundary = true;
      break;
    }
  }
  if (!foundBoundary) {
    start = lookBack;
    if (start > 0) while (start < bestStart && text.charCodeAt(start - 1) !== 0x20) start += 1;
  }
  if (start === 0 || foundBoundary) while (start < bestStart && isSpace(text.charCodeAt(start))) start += 1;
  let end = Math.min(length, start + maxLength);
  if (end < length) {
    let cut = end;
    while (cut > bestStart && text.charCodeAt(cut) !== 0x20) cut -= 1;
    if (cut > bestStart) end = cut;
  }
  start = adjusted(text, start, true);
  end = adjusted(text, end, false);
  const body = text.slice(start, end).replace(/[\n\v\f\r\u0085\u2028\u2029]/g, ' ');
  const prefix = start > 0 ? '…' : '';
  const suffix = end < length ? '…' : '';
  const highlights = merge(all.map((h) => h.range).filter((r) => r[0] >= start && r[1] <= end)).map(([a, b]): TextRange => [a - start + prefix.length, b - start + prefix.length]);
  return { text: prefix + body + suffix, highlights };
}
