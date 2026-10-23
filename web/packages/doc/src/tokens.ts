/**
 * The tokens NoteIt reads from note text: `#tag/sub`, `@due(…)` and `@remind(…)`, and the checklist lines they
 * sit on. A port of Swift `LocalDateTime`, `TokenGrammar` and `TaskParser` (NoteItCore). Callers pass masked
 * text (code and links blanked, see `maskedText`), as native does.
 */

/** A wall-clock date with an optional time; no time zone (09:00 is 09:00 wherever the device is). */
export interface LocalDateTime {
  year: number;
  month: number;
  day: number;
  hour?: number;
  minute?: number;
}

function daysIn(month: number, year: number): number {
  if (month === 2) return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0 ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

export function makeLocalDateTime(year: number, month: number, day: number, hour?: number, minute?: number): LocalDateTime | undefined {
  if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1 || day > daysIn(month, year)) return undefined;
  if (hour !== undefined || minute !== undefined) {
    if (hour === undefined || minute === undefined || hour < 0 || hour > 23 || minute < 0 || minute > 59) return undefined;
    return { year, month, day, hour, minute };
  }
  return { year, month, day };
}

/** "2026-10-21" or "2026-10-21 14:00"; invalid calendar dates are undefined (= Swift `LocalDateTime(token:)`). */
export function parseLocalDateTime(token: string): LocalDateTime | undefined {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?: (\d{2}):(\d{2}))?$/.exec(token);
  if (!m) return undefined;
  return makeLocalDateTime(Number(m[1]), Number(m[2]), Number(m[3]), m[4] === undefined ? undefined : Number(m[4]), m[5] === undefined ? undefined : Number(m[5]));
}

const pad = (n: number, w = 2) => String(n).padStart(w, '0');

export function localDateTimeToken(v: LocalDateTime): string {
  const date = `${pad(v.year, 4)}-${pad(v.month)}-${pad(v.day)}`;
  return v.hour === undefined ? date : `${date} ${pad(v.hour)}:${pad(v.minute ?? 0)}`;
}

export const dateOnly = (v: LocalDateTime): LocalDateTime => ({ year: v.year, month: v.month, day: v.day });

/** Compares like Swift: a date without a time sorts before the same day with one. */
export function compareLocal(a: LocalDateTime, b: LocalDateTime): number {
  return a.year - b.year || a.month - b.month || a.day - b.day || (a.hour ?? -1) - (b.hour ?? -1) || (a.minute ?? -1) - (b.minute ?? -1);
}

/** The moment this wall-clock time happens in the local time zone; midnight for a date without a time. */
export function localToDate(v: LocalDateTime): Date {
  return new Date(v.year, v.month - 1, v.day, v.hour ?? 0, v.minute ?? 0);
}

export function localFromDate(d: Date, includeTime: boolean): LocalDateTime {
  const v: LocalDateTime = { year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() };
  if (includeTime) {
    v.hour = d.getHours();
    v.minute = d.getMinutes();
  }
  return v;
}

export const UNCHECKED_MARKER = '☐';
export const CHECKED_MARKER = '☑';
export const MAX_TAG_DEPTH = 5;

const SEGMENT = String.raw`[\p{L}_][\p{L}\p{M}\p{N}_\-]*`;
const TAG_NAME_RE = new RegExp(String.raw`^${SEGMENT}(?:\/${SEGMENT}){0,${MAX_TAG_DEPTH - 1}}$`, 'u');
const DUE_RE = /@due\((\d{4}-\d{2}-\d{2})(?: (\d{2}):(\d{2}))?\)/g;
const REMIND_RE = /@remind\((\d{4}-\d{2}-\d{2}) (\d{2}):(\d{2})( done)?\)/g;

export function isValidTagName(name: string): boolean {
  return TAG_NAME_RE.test(name);
}

export function normalizedTag(tag: string): string {
  return tag.normalize('NFC').toLowerCase().normalize('NFC');
}

/** `selected` itself or any tag nested under it (= Swift `TagTree.matches`). */
export function tagMatches(tag: string, selected: string): boolean {
  return tag === selected || (tag.length > selected.length && tag.startsWith(selected) && tag[selected.length] === '/');
}

export type TokenKind = { type: 'due'; value: LocalDateTime } | { type: 'remind'; value: LocalDateTime; done: boolean };
export interface TextToken {
  kind: TokenKind;
  index: number;
  length: number;
}

/** `@due` and `@remind` tokens in position order (tags are read by `tagsIn`). */
export function dateTokens(masked: string): TextToken[] {
  const out: TextToken[] = [];
  for (const m of masked.matchAll(DUE_RE)) {
    const value = parseLocalDateTime(m[2] === undefined ? m[1]! : `${m[1]} ${m[2]}:${m[3]}`);
    if (value) out.push({ kind: { type: 'due', value }, index: m.index, length: m[0].length });
  }
  for (const m of masked.matchAll(REMIND_RE)) {
    const value = parseLocalDateTime(`${m[1]} ${m[2]}:${m[3]}`);
    if (value) out.push({ kind: { type: 'remind', value, done: m[4] !== undefined }, index: m.index, length: m[0].length });
  }
  return out.sort((a, b) => a.index - b.index);
}

export interface TaskLine {
  paragraph: number;
  text: string;
  checked: boolean;
  due?: LocalDateTime;
  remind?: LocalDateTime;
  remindDone: boolean;
}

export interface ReminderLine {
  paragraph: number;
  text: string;
  at: LocalDateTime;
  done: boolean;
  isTask: boolean;
  checked: boolean;
}

/** The line without its checkbox marker and its `@due`/`@remind` tokens, spaces collapsed. */
export function taskDisplayText(line: string): string {
  let body = line;
  if (body.startsWith(`${UNCHECKED_MARKER}\t`) || body.startsWith(`${CHECKED_MARKER}\t`)) body = body.slice(2);
  for (const t of dateTokens(body).reverse()) body = `${body.slice(0, t.index)} ${body.slice(t.index + t.length)}`;
  return body.split(/[ \t]+/).filter(Boolean).join(' ');
}

/** = Swift `TaskParser.parse(masked:)`: lines split on "\n"; the first `@due` and the first `@remind` on a line count. */
export function parseTasks(masked: string): { tasks: TaskLine[]; reminders: ReminderLine[] } {
  const tasks: TaskLine[] = [];
  const reminders: ReminderLine[] = [];
  if (!masked.includes(UNCHECKED_MARKER) && !masked.includes(CHECKED_MARKER) && !masked.includes('@remind(')) return { tasks, reminders };
  masked.split('\n').forEach((line, index) => {
    const checked = line.startsWith(`${UNCHECKED_MARKER}\t`) ? false : line.startsWith(`${CHECKED_MARKER}\t`) ? true : undefined;
    const hasRemind = line.includes('@remind(');
    if (checked === undefined && !hasRemind) return;
    const body = checked === undefined ? line : line.slice(2);
    let due: LocalDateTime | undefined;
    let remind: { value: LocalDateTime; done: boolean } | undefined;
    for (const t of dateTokens(body)) {
      if (t.kind.type === 'due' && !due) due = t.kind.value;
      if (t.kind.type === 'remind' && !remind) remind = { value: t.kind.value, done: t.kind.done };
    }
    if (checked !== undefined) {
      const task: TaskLine = { paragraph: index, text: body, checked, remindDone: remind?.done ?? false };
      if (due) task.due = due;
      if (remind) task.remind = remind.value;
      tasks.push(task);
    }
    if (remind) reminders.push({ paragraph: index, text: taskDisplayText(line), at: remind.value, done: remind.done, isTask: checked !== undefined, checked: checked ?? false });
  });
  return { tasks, reminders };
}
