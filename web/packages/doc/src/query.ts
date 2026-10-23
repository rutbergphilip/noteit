/**
 * The search language (organise spec 4.3): words, "phrases", `key:value` filters, `-`, `OR` and parentheses.
 * A port of Swift `SearchQuery` and `QueryEvaluator` (NoteItCore/Query); `fixtures/golden/search-query.json`
 * keeps the two in step.
 */
import { searchFold } from './search.js';
import { type LocalDateTime, compareLocal, dateOnly, isValidTagName, localToDate, normalizedTag, parseLocalDateTime, tagMatches } from './tokens.js';

export type IsFilter = 'pinned' | 'todo' | 'done' | 'untagged' | 'conflict';
export type HasFilter = 'due' | 'reminder' | 'attachment';
export type DateField = 'edited' | 'created' | 'due';
export type DateFilter =
  | { type: 'within' | 'olderThan'; seconds: number }
  | { type: 'on' | 'after' | 'before'; day: LocalDateTime }
  | { type: 'today' | 'yesterday' | 'thisWeek' | 'lastWeek' | 'thisMonth' | 'overdue' };

export type QueryNode =
  | { type: 'all' }
  | { type: 'word' | 'phrase' | 'title' | 'tag' | 'notebook'; value: string }
  | { type: 'is'; filter: IsFilter }
  | { type: 'has'; filter: HasFilter }
  | { type: 'date'; field: DateField; filter: DateFilter }
  | { type: 'not'; node: QueryNode }
  | { type: 'and' | 'or'; nodes: QueryNode[] };

export interface QueryIssue {
  start: number;
  end: number;
  message: string;
}

export interface SearchQuery {
  root: QueryNode;
  issues: QueryIssue[];
  highlightTerms: string[];
  hasTextTerms: boolean;
}

const IS_FILTERS: readonly IsFilter[] = ['pinned', 'todo', 'done', 'untagged', 'conflict'];
const HAS_FILTERS: readonly HasFilter[] = ['due', 'reminder', 'attachment'];
const KEYS = new Set(['tag', 'notebook', 'in', 'title', 'is', 'has', 'edited', 'created', 'due']);

interface Lexeme {
  kind: 'open' | 'close' | 'or' | 'minus' | 'term';
  start: number;
  end: number;
  key?: string;
  value: string;
  quoted: boolean;
}

const isSpace = (c: string) => /\s/u.test(c);

function quoted(text: string, open: number): { end: number; value: string } {
  const start = open + 1;
  const close = text.indexOf('"', start);
  return close >= 0 ? { end: close + 1, value: text.slice(start, close) } : { end: text.length, value: text.slice(start) };
}

function lex(text: string): Lexeme[] {
  const out: Lexeme[] = [];
  let depth = 0;
  let i = 0;
  while (i < text.length) {
    const c = text[i]!;
    if (isSpace(c)) {
      i += 1;
      continue;
    }
    if (c === '(') {
      depth += 1;
      out.push({ kind: 'open', start: i, end: i + 1, value: '', quoted: false });
      i += 1;
      continue;
    }
    if (c === ')') {
      depth = Math.max(0, depth - 1);
      out.push({ kind: 'close', start: i, end: i + 1, value: '', quoted: false });
      i += 1;
      continue;
    }
    if (c === '-' && i + 1 < text.length && !isSpace(text[i + 1]!) && text[i + 1] !== ')') {
      out.push({ kind: 'minus', start: i, end: i + 1, value: '', quoted: false });
      i += 1;
      continue;
    }
    if (c === '"') {
      const q = quoted(text, i);
      out.push({ kind: 'term', start: i, end: q.end, value: q.value, quoted: true });
      i = q.end;
      continue;
    }
    let j = i;
    let lexeme: Lexeme | undefined;
    while (j < text.length) {
      const d = text[j]!;
      if (isSpace(d) || (d === ')' && depth > 0)) break;
      if (d === ':' && text[j + 1] === '"') {
        const key = text.slice(i, j).toLowerCase();
        const q = quoted(text, j + 1);
        lexeme = KEYS.has(key)
          ? { kind: 'term', start: i, end: q.end, key, value: q.value, quoted: true }
          : { kind: 'term', start: i, end: q.end, value: text.slice(i, q.end), quoted: true };
        j = q.end;
        break;
      }
      j += 1;
    }
    if (lexeme) {
      out.push(lexeme);
      i = j;
      continue;
    }
    const raw = text.slice(i, j);
    const colon = raw.indexOf(':');
    if (raw === 'OR') out.push({ kind: 'or', start: i, end: j, value: '', quoted: false });
    else if (colon > 0 && KEYS.has(raw.slice(0, colon).toLowerCase()) && colon + 1 < raw.length) {
      out.push({ kind: 'term', start: i, end: j, key: raw.slice(0, colon).toLowerCase(), value: raw.slice(colon + 1), quoted: false });
    } else out.push({ kind: 'term', start: i, end: j, value: raw, quoted: false });
    i = j;
  }
  return out;
}

const UNITS: Record<string, number> = { h: 3600, d: 86400, w: 7 * 86400, m: 30 * 86400, y: 365 * 86400 };

export function parseDateFilter(value: string, field: DateField): DateFilter | undefined {
  const v = value.toLowerCase();
  const named: Record<string, DateFilter['type']> = { today: 'today', yesterday: 'yesterday', 'this-week': 'thisWeek', 'last-week': 'lastWeek', 'this-month': 'thisMonth' };
  if (named[v]) return { type: named[v] } as DateFilter;
  if (v === 'overdue') return field === 'due' ? { type: 'overdue' } : undefined;
  const first = v[0];
  if (first === '<' || first === '>') {
    const rest = v.slice(1);
    const unit = rest[rest.length - 1];
    if (unit && UNITS[unit] && rest.length > 1 && /^[0-9]+$/.test(rest.slice(0, -1))) {
      const seconds = Number(rest.slice(0, -1)) * UNITS[unit];
      return { type: first === '<' ? 'within' : 'olderThan', seconds };
    }
    const day = parseLocalDateTime(rest);
    return day ? { type: first === '<' ? 'before' : 'after', day: dateOnly(day) } : undefined;
  }
  const day = parseLocalDateTime(v);
  return day ? { type: 'on', day: dateOnly(day) } : undefined;
}

class Parser {
  pos = 0;
  issues: QueryIssue[] = [];
  constructor(
    private readonly lexemes: Lexeme[],
    private readonly text: string,
  ) {}

  private get current(): Lexeme | undefined {
    return this.lexemes[this.pos];
  }

  parseQuery(): QueryNode {
    return combine(this.sequence(undefined));
  }

  private sequence(opening: Lexeme | undefined): QueryNode[] {
    const nodes: QueryNode[] = [];
    while (this.current) {
      const l = this.current;
      if (l.kind === 'close') {
        this.pos += 1;
        if (opening) return nodes;
        this.issues.push({ start: l.start, end: l.end, message: 'This “)” has no matching “(”.' });
        continue;
      }
      const node = this.or();
      if (node) nodes.push(node);
    }
    if (opening) this.issues.push({ start: opening.start, end: opening.end, message: 'This “(” is never closed.' });
    return nodes;
  }

  private or(): QueryNode | undefined {
    const first = this.unary();
    if (!first) return undefined;
    const options = [first];
    while (this.current?.kind === 'or') {
      this.pos += 1;
      const next = this.current;
      if (!next || next.kind === 'close' || next.kind === 'or') break;
      const node = this.unary();
      if (node) options.push(node);
    }
    return options.length === 1 ? first : { type: 'or', nodes: options };
  }

  private unary(): QueryNode | undefined {
    const l = this.current;
    if (!l) return undefined;
    if (l.kind === 'minus') {
      this.pos += 1;
      const next = this.current;
      if (!next || next.kind === 'close') return undefined;
      const atom = this.atom();
      return atom ? { type: 'not', node: atom } : undefined;
    }
    return this.atom();
  }

  private atom(): QueryNode | undefined {
    const l = this.current;
    if (!l) return undefined;
    this.pos += 1;
    switch (l.kind) {
      case 'open': {
        const inner = this.sequence(l);
        return inner.length ? combine(inner) : undefined;
      }
      case 'or':
        return { type: 'word', value: 'or' };
      case 'term':
        return this.term(l);
      default:
        return undefined;
    }
  }

  private term(l: Lexeme): QueryNode {
    const raw = this.text.slice(l.start, l.end);
    if (!l.key) return { type: l.quoted ? 'phrase' : 'word', value: searchFold(l.value) };
    const value = l.value.trim();
    const fallback = (message: string): QueryNode => {
      this.issues.push({ start: l.start, end: l.end, message });
      return { type: 'word', value: searchFold(raw) };
    };
    if (!value) return { type: 'word', value: searchFold(raw) };
    switch (l.key) {
      case 'tag': {
        let name = value.startsWith('#') ? value.slice(1) : value;
        while (name.endsWith('/')) name = name.slice(0, -1);
        if (!isValidTagName(name)) return fallback(`“${raw}” isn't a tag name. Try tag:work.`);
        return { type: 'tag', value: normalizedTag(name) };
      }
      case 'notebook':
      case 'in':
        return { type: 'notebook', value };
      case 'title':
        return { type: 'title', value: searchFold(value) };
      case 'is': {
        const f = value.toLowerCase() as IsFilter;
        if (!IS_FILTERS.includes(f)) return fallback(`“${raw}” isn't a filter. Try is:todo, is:done, is:pinned, is:untagged or is:conflict.`);
        return { type: 'is', filter: f };
      }
      case 'has': {
        const f = value.toLowerCase() as HasFilter;
        if (!HAS_FILTERS.includes(f)) return fallback(`“${raw}” isn't a filter. Try has:due, has:reminder or has:attachment.`);
        return { type: 'has', filter: f };
      }
      default: {
        const field = l.key as DateField;
        const filter = parseDateFilter(value, field);
        if (!filter) return fallback(`“${raw}” isn't a date. Try ${l.key}:<7d.`);
        return { type: 'date', field, filter };
      }
    }
  }
}

function combine(nodes: QueryNode[]): QueryNode {
  if (nodes.length === 0) return { type: 'all' };
  if (nodes.length === 1) return nodes[0]!;
  return { type: 'and', nodes };
}

function collect(node: QueryNode, positive: boolean, terms: string[], state: { hasText: boolean }): void {
  switch (node.type) {
    case 'word':
    case 'phrase':
      if (!positive || !node.value) return;
      state.hasText = true;
      if (!terms.includes(node.value)) terms.push(node.value);
      return;
    case 'title':
      if (positive && node.value && !terms.includes(node.value)) terms.push(node.value);
      return;
    case 'not':
      collect(node.node, !positive, terms, state);
      return;
    case 'and':
    case 'or':
      for (const n of node.nodes) collect(n, positive, terms, state);
      return;
    default:
      return;
  }
}

export function parseQuery(text: string): SearchQuery {
  const parser = new Parser(lex(text), text);
  const root = parser.parseQuery();
  const terms: string[] = [];
  const state = { hasText: false };
  collect(root, true, terms, state);
  return { root, issues: parser.issues, highlightTerms: terms, hasTextTerms: state.hasText };
}

export const isEmptyQuery = (q: SearchQuery) => q.root.type === 'all';

// MARK: evaluation

/** What the evaluator reads about one note (= Swift `SearchDocument`). */
export interface SearchDocument {
  /** Folded body, title included; empty for locked notes. */
  foldedText: string;
  foldedTitle: string;
  tags: string[];
  notebookID?: string;
  isPinned: boolean;
  isConflict: boolean;
  createdAt: Date;
  updatedAt: Date;
  openTaskCount: number;
  doneTaskCount: number;
  openDueDates: LocalDateTime[];
  hasLiveReminder: boolean;
  hasAttachment: boolean;
}

export interface QueryNotebook {
  id: string;
  name: string;
  parent?: string;
  sortIndex: number;
}

export interface QueryContext {
  now: Date;
  notebooks: QueryNotebook[];
  /** 0 = Sunday … 6 = Saturday. */
  firstWeekday?: number;
}

const sameName = (a: string, b: string) => searchFold(a) === searchFold(b);

/** = Swift `NotebookTree.id(forPath:)`: a name, or a `Parent/Child` path, matched case- and accent-insensitively. */
export function notebookIdForPath(notebooks: QueryNotebook[], path: string): string | undefined {
  const wanted = path.trim();
  if (!wanted) return undefined;
  const ids = new Set(notebooks.map((n) => n.id));
  const children = (parent: string | undefined) =>
    notebooks
      .filter((n) => (parent === undefined ? !n.parent || !ids.has(n.parent) : n.parent === parent))
      .sort((a, b) => a.sortIndex - b.sortIndex || a.name.localeCompare(b.name));
  const ordered: QueryNotebook[] = [];
  const visit = (n: QueryNotebook) => {
    ordered.push(n);
    children(n.id).forEach(visit);
  };
  children(undefined).forEach(visit);
  const byName = ordered.find((n) => sameName(n.name, wanted))?.id;
  if (!wanted.includes('/')) return byName;
  let level = children(undefined);
  let found: string | undefined;
  for (const segment of wanted.split('/').filter(Boolean)) {
    const match = level.find((n) => sameName(n.name, segment.trim()));
    if (!match) return byName;
    found = match.id;
    level = children(match.id);
  }
  return found ?? byName;
}

export function notebookDescendants(notebooks: QueryNotebook[], id: string): string[] {
  const out: string[] = [];
  for (const n of notebooks) if (n.parent === id && n.id !== id) out.push(n.id, ...notebookDescendants(notebooks, n.id));
  return out;
}

const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

function period(type: DateFilter['type'], ctx: QueryContext): [Date, Date] | undefined {
  const today = startOfDay(ctx.now);
  const weekStart = addDays(today, -((today.getDay() - (ctx.firstWeekday ?? 1) + 7) % 7));
  switch (type) {
    case 'today':
      return [today, addDays(today, 1)];
    case 'yesterday':
      return [addDays(today, -1), today];
    case 'thisWeek':
      return [weekStart, addDays(weekStart, 7)];
    case 'lastWeek':
      return [addDays(weekStart, -7), weekStart];
    case 'thisMonth':
      return [new Date(today.getFullYear(), today.getMonth(), 1), new Date(today.getFullYear(), today.getMonth() + 1, 1)];
    default:
      return undefined;
  }
}

function dayRange(day: LocalDateTime): [Date, Date] {
  const start = localToDate(dateOnly(day));
  return [start, addDays(start, 1)];
}

function matchesDate(date: Date, f: DateFilter, ctx: QueryContext): boolean {
  const t = date.getTime();
  switch (f.type) {
    case 'within':
      return t >= ctx.now.getTime() - f.seconds * 1000;
    case 'olderThan':
      return t < ctx.now.getTime() - f.seconds * 1000;
    case 'on': {
      const [s, e] = dayRange(f.day);
      return t >= s.getTime() && t < e.getTime();
    }
    case 'after':
      return t >= dayRange(f.day)[1].getTime();
    case 'before':
      return t < dayRange(f.day)[0].getTime();
    case 'overdue':
      return false;
    default: {
      const p = period(f.type, ctx);
      return !!p && t >= p[0].getTime() && t < p[1].getTime();
    }
  }
}

function matchesDue(due: LocalDateTime, f: DateFilter, ctx: QueryContext): boolean {
  const t = localToDate(due).getTime();
  const sod = startOfDay(ctx.now).getTime();
  switch (f.type) {
    case 'within':
      return t >= sod && t <= ctx.now.getTime() + f.seconds * 1000;
    case 'olderThan':
      return t > ctx.now.getTime() + f.seconds * 1000;
    case 'on':
      return compareLocal(dateOnly(due), f.day) === 0;
    case 'after':
      return compareLocal(dateOnly(due), f.day) > 0;
    case 'before':
      return compareLocal(dateOnly(due), f.day) < 0;
    case 'overdue':
      return due.hour !== undefined ? t < ctx.now.getTime() : t < sod;
    default: {
      const p = period(f.type, ctx);
      return !!p && t >= p[0].getTime() && t < p[1].getTime();
    }
  }
}

export function evaluateQuery(node: QueryNode, doc: SearchDocument, ctx: QueryContext): boolean {
  switch (node.type) {
    case 'all':
      return true;
    case 'word':
    case 'phrase':
      return !node.value || doc.foldedText.includes(node.value) || doc.foldedTitle.includes(node.value);
    case 'title':
      return !node.value || doc.foldedTitle.includes(node.value);
    case 'tag':
      return doc.tags.some((t) => tagMatches(t, node.value));
    case 'notebook': {
      const id = notebookIdForPath(ctx.notebooks, node.value);
      if (!id || !doc.notebookID) return false;
      return doc.notebookID === id || notebookDescendants(ctx.notebooks, id).includes(doc.notebookID);
    }
    case 'is':
      switch (node.filter) {
        case 'pinned':
          return doc.isPinned;
        case 'todo':
          return doc.openTaskCount > 0;
        case 'done':
          return doc.doneTaskCount > 0 && doc.openTaskCount === 0;
        case 'untagged':
          return doc.tags.length === 0;
        case 'conflict':
          return doc.isConflict;
      }
      return false;
    case 'has':
      if (node.filter === 'due') return doc.openDueDates.length > 0;
      if (node.filter === 'reminder') return doc.hasLiveReminder;
      return doc.hasAttachment;
    case 'date':
      if (node.field === 'edited') return matchesDate(doc.updatedAt, node.filter, ctx);
      if (node.field === 'created') return matchesDate(doc.createdAt, node.filter, ctx);
      return doc.openDueDates.some((d) => matchesDue(d, node.filter, ctx));
    case 'not':
      return !evaluateQuery(node.node, doc, ctx);
    case 'and':
      return node.nodes.every((n) => evaluateQuery(n, doc, ctx));
    case 'or':
      return node.nodes.some((n) => evaluateQuery(n, doc, ctx));
  }
}

export function matchesQuery(query: SearchQuery, doc: SearchDocument, ctx: QueryContext): boolean {
  return evaluateQuery(query.root, doc, ctx);
}
