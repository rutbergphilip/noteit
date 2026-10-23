/**
 * Best Match order (native SearchRanker, spec 5.1): BM25 over the folded text, with title, tag, whole-query,
 * proximity and recency boosts. Ties go to pinned notes, then the last edited. Lengths are UTF-8 bytes, as there.
 */
import type { QueryNode, SearchQuery } from './query.js';

export interface RankDocument {
  foldedText: string;
  foldedTitle: string;
  tags: string[];
  isPinned: boolean;
  updatedAt: Date;
}

const K1 = 1.2;
const B = 0.75;
const WINDOW = 80;
const enc = new TextEncoder();

/** Positive words and phrases, in order, without repeats. */
export function textTerms(node: QueryNode, positive = true): string[] {
  switch (node.type) {
    case 'word':
    case 'phrase':
      return positive && node.value ? [node.value] : [];
    case 'not':
      return textTerms(node.node, !positive);
    case 'and':
    case 'or': {
      const seen = new Set<string>();
      return node.nodes.flatMap((n) => textTerms(n, positive)).filter((t) => !seen.has(t) && !!seen.add(t));
    }
    default:
      return [];
  }
}

function indexOf(hay: Uint8Array, needle: Uint8Array, from: number): number {
  outer: for (let i = from; i + needle.length <= hay.length; i++) {
    for (let j = 0; j < needle.length; j++) if (hay[i + j] !== needle[j]) continue outer;
    return i;
  }
  return -1;
}
const isWordStart = (bytes: Uint8Array, i: number) => {
  if (i === 0) return true;
  const before = bytes[i - 1]!;
  if (before >= 0x80) return false;
  return !/[A-Za-z0-9]/.test(String.fromCharCode(before));
};
function weightedCount(needle: Uint8Array, hay: Uint8Array): number {
  let total = 0;
  for (let at = indexOf(hay, needle, 0); at >= 0; at = indexOf(hay, needle, at + 1)) total += isWordStart(hay, at) ? 1 : 0.5;
  return total;
}
function withinWindow(needles: Uint8Array[], text: Uint8Array): boolean {
  const events: { start: number; end: number; term: number }[] = [];
  for (const [t, needle] of needles.entries()) {
    let found = 0;
    for (let at = indexOf(text, needle, 0); at >= 0 && found < 200; at = indexOf(text, needle, at + 1)) {
      events.push({ start: at, end: at + needle.length, term: t });
      found += 1;
    }
    if (!found) return false;
  }
  events.sort((a, b) => a.start - b.start);
  const counts = new Array<number>(needles.length).fill(0);
  let covered = 0;
  let left = 0;
  for (let right = 0; right < events.length; right++) {
    if ((counts[events[right]!.term] = counts[events[right]!.term]! + 1) === 1) covered += 1;
    while (covered === needles.length) {
      const end = Math.max(...events.slice(left, right + 1).map((e) => e.end));
      if (end - events[left]!.start <= WINDOW) return true;
      if (--counts[events[left]!.term]! === 0) covered -= 1;
      left += 1;
    }
  }
  return false;
}

/** Document indices, best first. */
export function rankSearch(docs: RankDocument[], query: SearchQuery, foldedQueryText: string, now: Date = new Date()): number[] {
  const terms = textTerms(query.root);
  const needles = terms.map((t) => enc.encode(t));
  if (!docs.length) return [];
  const texts = docs.map((d) => enc.encode(d.foldedText));
  const average = Math.max(1, texts.reduce((n, t) => n + t.length, 0) / docs.length);
  const tf = texts.map((text) => needles.map((n) => weightedCount(n, text)));
  const df = needles.map((_, t) => docs.filter((d, i) => tf[i]![t]! > 0 || d.foldedTitle.includes(terms[t]!)).length);
  const n = docs.length;
  const idf = df.map((x) => Math.log(1 + (n - x + 0.5) / (x + 0.5)));
  const idfAverage = idf.length ? idf.reduce((a, b) => a + b, 0) / idf.length : 0;
  const whole = foldedQueryText.trim();
  const scores = docs.map((d, i) => {
    let score = 0;
    const length = texts[i]!.length;
    for (let t = 0; t < needles.length; t++) {
      const f = tf[i]![t]!;
      if (f > 0) score += (idf[t]! * f * (K1 + 1)) / (f + K1 * (1 - B + (B * length) / average));
      if (d.foldedTitle.includes(terms[t]!)) {
        score += 2 * idf[t]!;
        if (d.foldedTitle.startsWith(terms[t]!)) score += idf[t]!;
      }
      if (d.tags.includes(terms[t]!)) score += idf[t]!;
    }
    if (whole && d.foldedTitle === whole) score += 3;
    if (needles.length > 1 && withinWindow(needles, texts[i]!)) score += 0.5 * idfAverage;
    const ageDays = Math.max(0, now.getTime() - d.updatedAt.getTime()) / 86_400_000;
    return score * (1 + 0.3 * Math.exp(-ageDays / 30));
  });
  return docs
    .map((_, i) => i)
    .sort((a, b) => {
      if (scores[a] !== scores[b]) return scores[b]! - scores[a]!;
      const x = docs[a]!;
      const y = docs[b]!;
      if (x.isPinned !== y.isPinned) return x.isPinned ? -1 : 1;
      if (x.updatedAt.getTime() !== y.updatedAt.getTime()) return y.updatedAt.getTime() - x.updatedAt.getTime();
      return a - b;
    });
}
