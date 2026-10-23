/**
 * Subsequence matcher for short titles: a port of Swift `FuzzyMatcher` (NoteItCore/Text/FuzzyMatcher.swift), same
 * scores, so "gn" finds "Grocery Notes" and results rank as in the Mac palette. Folds per character like
 * `searchFold` (case, diacritics, width) so match positions map back to the original string.
 */
import { searchFold } from './search.js';

export interface FuzzyMatch {
  score: number;
  /** Character offsets into the original candidate, ascending. */
  matchedIndices: number[];
}

const MATCH = 16;
const WORD_START = 12;
const FIRST_CHAR = 4;
const MIN_CONSECUTIVE = 6;
const GAP_OPEN = 3;
const MAX_LEAD = 6;
const PREFIX = 100;
const MAX_LENGTH_PENALTY = 20;
const UNREACHABLE = Number.MIN_SAFE_INTEGER / 4;

const ASCII_ALNUM = /^[A-Za-z0-9]$/;
const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
/** Swift Characters: extended grapheme clusters. */
const graphemes = (s: string): string[] => Array.from(segmenter.segment(s), (x) => x.segment);

/** One Character folded to its folded Characters (each compared as a whole, like Swift's integer codes). */
function foldChar(ch: string): string[] {
  const c = ch.codePointAt(0)!;
  if (ch.length === 1 && c < 128) return [c >= 65 && c <= 90 ? String.fromCharCode(c + 32) : ch];
  // Foundation's case folding is full folding (ß → ss); toLowerCase in searchFold keeps ß.
  return graphemes(searchFold(ch).replace(/ß/g, 'ss'));
}

const foldedCodes = (s: string): string[] => graphemes(s).flatMap(foldChar);

function isWordStart(ch: string, prev: string | undefined): boolean {
  if (prev === undefined) return true;
  const p = prev.codePointAt(0)!;
  const c = ch.codePointAt(0)!;
  if (prev.length === 1 && ch.length === 1 && p < 128 && c < 128) {
    const pLower = p >= 97 && p <= 122;
    if (!ASCII_ALNUM.test(prev)) return true;
    return pLower && c >= 65 && c <= 90;
  }
  if (!/[\p{L}\p{N}]/u.test(prev)) return true;
  return /\p{Ll}/u.test(prev) && /\p{Lu}/u.test(ch);
}

interface Prepared {
  codes: string[];
  origin: number[];
  bonus: number[];
  characters: number;
}

function prepare(s: string): Prepared {
  const codes: string[] = [];
  const origin: number[] = [];
  const bonus: number[] = [];
  let prev: string | undefined;
  let offset = 0;
  for (const ch of graphemes(s)) {
    const start = isWordStart(ch, prev) ? WORD_START : 0;
    foldChar(ch).forEach((code, i) => {
      codes.push(code);
      origin.push(offset);
      bonus.push(i === 0 ? start : 0);
    });
    prev = ch;
    offset += 1;
  }
  return { codes, origin, bonus, characters: offset };
}

export interface FuzzyQuery {
  terms: string[][];
  whole: string[];
}

export function fuzzyQuery(query: string): FuzzyQuery {
  return { terms: query.split(/\s+/).map(foldedCodes).filter((t) => t.length > 0), whole: foldedCodes(query.trim()) };
}

function isSubsequence(needle: string[], hay: string[]): boolean {
  let i = 0;
  for (const c of hay) if (c === needle[i] && ++i === needle.length) return true;
  return false;
}

const firstScore = (j: number, t: Prepared) => MATCH + t.bonus[j]! - Math.min(j, MAX_LEAD) + (j === 0 ? FIRST_CHAR : 0);

function bestContiguous(needle: string[], t: Prepared): { score: number; start: number } | undefined {
  const m = needle.length;
  let best: { score: number; start: number } | undefined;
  for (let start = 0; start + m <= t.codes.length; start++) {
    let ok = true;
    for (let i = 0; i < m; i++) if (t.codes[start + i] !== needle[i]) ok = false;
    if (!ok) continue;
    let score = firstScore(start, t);
    let carry = t.bonus[start]!;
    for (let i = 1; i < m; i++) {
      const own = t.bonus[start + i]!;
      score += MATCH + Math.max(own, carry, MIN_CONSECUTIVE);
      carry = Math.max(carry, own);
    }
    if (!best || score > best.score) best = { score, start };
  }
  return best;
}

function bestScattered(needle: string[], t: Prepared): [number, number[]] | undefined {
  const m = needle.length;
  const n = t.codes.length;
  const scores = new Array<number>(m * n).fill(UNREACHABLE);
  const parents = new Array<number>(m * n).fill(-1);
  const carries = new Array<number>(m * n).fill(0);
  for (let j = 0; j < n; j++) {
    if (t.codes[j] !== needle[0]) continue;
    scores[j] = firstScore(j, t);
    carries[j] = t.bonus[j]!;
  }
  for (let i = 1; i < m; i++) {
    const row = i * n;
    const prevRow = row - n;
    let gapValue = UNREACHABLE;
    let gapIndex = -1;
    for (let j = i; j < n; j++) {
      const k = j - 2;
      if (k >= 0 && scores[prevRow + k]! > UNREACHABLE) {
        const value = scores[prevRow + k]! + k;
        if (value > gapValue) {
          gapValue = value;
          gapIndex = k;
        }
      }
      if (t.codes[j] !== needle[i]) continue;
      const own = t.bonus[j]!;
      let best = UNREACHABLE;
      let parent = -1;
      let carry = own;
      if (scores[prevRow + j - 1]! > UNREACHABLE) {
        const prevCarry = carries[prevRow + j - 1]!;
        best = scores[prevRow + j - 1]! + Math.max(own, prevCarry, MIN_CONSECUTIVE);
        parent = j - 1;
        carry = Math.max(own, prevCarry);
      }
      if (gapIndex >= 0) {
        const gapped = gapValue - (j - 1) - GAP_OPEN + own;
        if (gapped > best) {
          best = gapped;
          parent = gapIndex;
          carry = own;
        }
      }
      if (parent >= 0) {
        scores[row + j] = best + MATCH;
        parents[row + j] = parent;
        carries[row + j] = carry;
      }
    }
  }
  const lastRow = (m - 1) * n;
  let bestScore = UNREACHABLE;
  let bestEnd = -1;
  for (let j = m - 1; j < n; j++) {
    if (scores[lastRow + j]! > bestScore) {
      bestScore = scores[lastRow + j]!;
      bestEnd = j;
    }
  }
  if (bestEnd < 0) return undefined;
  const positions = new Array<number>(m).fill(0);
  let j = bestEnd;
  for (let i = m - 1; i >= 0; i--) {
    positions[i] = j;
    j = parents[i * n + j]!;
  }
  return [bestScore, positions];
}

function align(needle: string[], t: Prepared): [number, number[]] | undefined {
  const m = needle.length;
  if (m === 0 || m > t.codes.length) return undefined;
  const run = bestContiguous(needle, t);
  if (run) return [run.score + (m > 1 ? 8 * m + 32 : 0), Array.from({ length: m }, (_, i) => run.start + i)];
  return bestScattered(needle, t);
}

/** undefined when the query doesn't match; an empty query matches everything with score 0. */
export function fuzzyEvaluate(query: FuzzyQuery | string, candidate: string): { match: FuzzyMatch; isExact: boolean } | undefined {
  const q = typeof query === 'string' ? fuzzyQuery(query) : query;
  if (q.terms.length === 0) return { match: { score: 0, matchedIndices: [] }, isExact: false };
  const t = prepare(candidate);
  if (q.terms.some((term) => !isSubsequence(term, t.codes))) return undefined;
  let total = 0;
  const indices: number[] = [];
  for (const term of q.terms) {
    const aligned = align(term, t);
    if (!aligned) return undefined;
    total += aligned[0];
    for (const p of aligned[1]) indices.push(t.origin[p]!);
  }
  const isExact = t.codes.length === q.whole.length && t.codes.every((c, i) => c === q.whole[i]);
  if (isExact) total += 1000 + 80 * q.whole.length;
  else if (q.whole.every((c, i) => t.codes[i] === c)) total += PREFIX;
  total -= Math.min(Math.floor(t.characters / 4), MAX_LENGTH_PENALTY);
  const unique = [...new Set(indices.sort((a, b) => a - b))];
  return { match: { score: Math.max(1, total), matchedIndices: unique }, isExact };
}

export function fuzzyMatch(query: FuzzyQuery | string, candidate: string): FuzzyMatch | undefined {
  return fuzzyEvaluate(query, candidate)?.match;
}
