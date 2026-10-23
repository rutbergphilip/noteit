/**
 * The palette's results, ranked as native `PaletteRanker.items` (Sources/NoteIt/Palette/PaletteRanker.swift):
 * fuzzy title matches (shared `FuzzyMatcher` port) across notes, notebooks, smart folders, tags and commands in one
 * list, body-only note hits after title hits, and the New Note "…" row last, only when no note has that title.
 */
import { fuzzyEvaluate, fuzzyMatch, fuzzyQuery } from '@noteit/doc';

export interface RankNote {
  id: string;
  title: string;
  notebookID?: string;
  updatedAt: string;
  isPinned: boolean;
}
export interface RankNotebook {
  id: string;
  name: string;
  parent?: string;
}
export interface RankCommand {
  id: string;
  title: string;
  keywords?: string[];
}
export interface RankSmartFolder {
  id: string;
  name: string;
  query: string;
}

export type PaletteKind =
  | { kind: 'note'; id: string }
  | { kind: 'notebook'; id: string }
  | { kind: 'smartFolder'; id: string }
  | { kind: 'tag'; path: string }
  | { kind: 'command'; id: string }
  | { kind: 'create'; title: string };

export type PaletteRow = PaletteKind & { key: string; title: string; subtitle?: string; matchedIndices: number[] };

export const RECENT_NOTES_LIMIT = 10;

/** `>` (after leading spaces) lists commands only; the rest, trimmed, is the text. */
export function parsePaletteQuery(raw: string): { mode: 'everything' | 'commands'; text: string } {
  const leading = raw.trimStart();
  if (leading.startsWith('>')) return { mode: 'commands', text: leading.slice(1).trim() };
  return { mode: 'everything', text: raw.trim() };
}

export const displayTitle = (title: string) => title || 'Untitled';

interface Ranked {
  row: PaletteRow;
  score: number;
  kindRank: number;
  updatedAt: number;
  bodyScore: number;
}

function precedes(a: Ranked, b: Ranked): number {
  if (a.score !== b.score) return b.score - a.score;
  if (a.kindRank !== b.kindRank) return a.kindRank - b.kindRank;
  if (a.bodyScore !== b.bodyScore) return b.bodyScore - a.bodyScore;
  if (a.updatedAt !== b.updatedAt) return b.updatedAt - a.updatedAt;
  const order = a.row.title.localeCompare(b.row.title, undefined, { numeric: true });
  if (order) return order;
  return a.row.key < b.row.key ? -1 : a.row.key > b.row.key ? 1 : 0;
}

function rankedCommand(c: RankCommand, query: ReturnType<typeof fuzzyQuery>): Ranked | undefined {
  const row = (indices: number[]): PaletteRow => ({ kind: 'command', id: c.id, key: `command:${c.id}`, title: c.title, matchedIndices: indices });
  const m = fuzzyMatch(query, c.title);
  if (m) return { row: row(m.matchedIndices), score: m.score, kindRank: 2, updatedAt: 0, bodyScore: 0 };
  if (!c.keywords?.length) return undefined;
  const k = fuzzyMatch(query, [c.title, ...c.keywords].join(' '));
  return k ? { row: row([]), score: Math.max(1, Math.floor(k.score / 2)), kindRank: 2, updatedAt: 0, bodyScore: 0 } : undefined;
}

function notebookPaths(notebooks: RankNotebook[]): Map<string, string> {
  const byId = new Map(notebooks.map((n) => [n.id, n]));
  const path = (n: RankNotebook, seen = new Set<string>()): string => {
    const parent = n.parent ? byId.get(n.parent) : undefined;
    if (!parent || seen.has(parent.id)) return n.name;
    seen.add(n.id);
    return `${path(parent, seen)} › ${n.name}`;
  };
  return new Map(notebooks.map((n) => [n.id, path(n)]));
}

export function rankPalette(input: {
  query: string;
  notes: RankNote[];
  notebooks: RankNotebook[];
  commands: RankCommand[];
  /** Notes the search language found by their text (not their title). */
  bodyMatches?: Set<string>;
  smartFolders?: RankSmartFolder[];
  tags?: { path: string; count: number }[];
  limit?: number;
}): PaletteRow[] {
  const { mode, text } = parsePaletteQuery(input.query);
  const cap = Math.max(0, input.limit ?? 50);
  if (mode === 'commands') {
    if (!text) return [...input.commands].sort((a, b) => a.title.localeCompare(b.title, undefined, { numeric: true })).slice(0, cap).map((c) => ({ kind: 'command', id: c.id, key: `command:${c.id}`, title: c.title, matchedIndices: [] }));
    const q = fuzzyQuery(text);
    return input.commands.flatMap((c) => rankedCommand(c, q) ?? []).sort(precedes).slice(0, cap).map((r) => r.row);
  }
  const paths = notebookPaths(input.notebooks);
  const noteRow = (n: RankNote, indices: number[]): PaletteRow => ({
    kind: 'note',
    id: n.id,
    key: `note:${n.id}`,
    title: displayTitle(n.title),
    ...(n.notebookID && paths.get(n.notebookID) ? { subtitle: paths.get(n.notebookID)! } : {}),
    matchedIndices: indices,
  });
  if (!text) {
    return [...input.notes]
      .sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt))
      .slice(0, Math.min(cap, RECENT_NOTES_LIMIT))
      .map((n) => noteRow(n, []));
  }
  const q = fuzzyQuery(text);
  const ranked: Ranked[] = [];
  let hasNoteTitledText = false;
  for (const n of input.notes) {
    const r = fuzzyEvaluate(q, displayTitle(n.title));
    if (r) {
      if (!hasNoteTitledText && n.title.trim().toLowerCase() === text.toLowerCase()) hasNoteTitledText = true;
      ranked.push({ row: noteRow(n, r.match.matchedIndices), score: r.match.score, kindRank: 0, updatedAt: Date.parse(n.updatedAt), bodyScore: 0 });
    } else if (input.bodyMatches?.has(n.id)) {
      ranked.push({ row: noteRow(n, []), score: 0, kindRank: 0, updatedAt: Date.parse(n.updatedAt), bodyScore: 0 });
    }
  }
  const counts = new Map<string, number>();
  for (const n of input.notes) if (n.notebookID) counts.set(n.notebookID, (counts.get(n.notebookID) ?? 0) + 1);
  for (const nb of input.notebooks) {
    const m = fuzzyMatch(q, nb.name);
    if (!m) continue;
    const count = counts.get(nb.id) ?? 0;
    const notes = count === 1 ? '1 note' : `${count} notes`;
    const parentPath = nb.parent ? paths.get(nb.parent) : undefined;
    ranked.push({ row: { kind: 'notebook', id: nb.id, key: `notebook:${nb.id}`, title: nb.name, subtitle: parentPath ? `${parentPath} · ${notes}` : notes, matchedIndices: m.matchedIndices }, score: m.score, kindRank: 1, updatedAt: 0, bodyScore: 0 });
  }
  for (const f of input.smartFolders ?? []) {
    const m = fuzzyMatch(q, f.name);
    if (m) ranked.push({ row: { kind: 'smartFolder', id: f.id, key: `smartFolder:${f.id}`, title: f.name, subtitle: `Smart Folder · ${f.query}`, matchedIndices: m.matchedIndices }, score: m.score, kindRank: 1, updatedAt: 0, bodyScore: 0 });
  }
  for (const t of input.tags ?? []) {
    const title = `#${t.path}`;
    const m = fuzzyMatch(q, title);
    if (m) ranked.push({ row: { kind: 'tag', path: t.path, key: `tag:${t.path}`, title, subtitle: t.count === 1 ? '1 note' : `${t.count} notes`, matchedIndices: m.matchedIndices }, score: m.score, kindRank: 1, updatedAt: 0, bodyScore: 0 });
  }
  for (const c of input.commands) {
    const r = rankedCommand(c, q);
    if (r) ranked.push(r);
  }
  const result = ranked.sort(precedes).slice(0, cap).map((r) => r.row);
  if (!hasNoteTitledText) result.push({ kind: 'create', title: text, key: 'create', matchedIndices: [] });
  return result;
}
