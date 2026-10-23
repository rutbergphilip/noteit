/**
 * Daily notes: one note per day in the "Daily Notes" notebook, found by its title (= Swift `DailyNoteTitle` and
 * `NoteStore.dailyNote(for:)`). The title format, notebook and template choices are native preferences kept on
 * each Mac, so the web uses native's defaults: the notebook named "Daily Notes" and `yyyy-MM-dd` titles.
 */
import { formatDatePattern } from './template.js';

export const DAILY_NOTEBOOK_NAME = 'Daily Notes';
export type DailyTitleFormat = 'iso' | 'long' | 'weekdayLong';
const PATTERNS: Record<DailyTitleFormat, string> = { iso: 'yyyy-MM-dd', long: 'd MMMM yyyy', weekdayLong: 'EEEE, d MMMM yyyy' };

export interface DayKey {
  year: number;
  month: number;
  day: number;
}

export const dayKey = (d: Date): DayKey => ({ year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() });
export const sameDay = (a: DayKey | undefined, b: DayKey) => !!a && a.year === b.year && a.month === b.month && a.day === b.day;

export function dailyTitle(day: DayKey, format: DailyTitleFormat = 'iso', locale?: string): string {
  return formatDatePattern(new Date(day.year, day.month - 1, day.day, 12), PATTERNS[format], locale);
}

function monthNames(locale: string | undefined): string[] {
  const f = new Intl.DateTimeFormat(locale, { month: 'long' });
  return Array.from({ length: 12 }, (_, m) => f.format(new Date(2026, m, 1)).toLowerCase());
}

/** The day a title names in any of the three formats (month names in `locale` or English); else undefined. */
export function parseDailyTitle(title: string, locale?: string): DayKey | undefined {
  const t = title.trim().toLowerCase();
  const iso = /^(\d{4})-(\d{2})-(\d{2})$/.exec(t);
  const valid = (year: number, month: number, day: number) => {
    const d = new Date(year, month - 1, day);
    return d.getFullYear() === year && d.getMonth() === month - 1 && d.getDate() === day ? { year, month, day } : undefined;
  };
  if (iso) return valid(Number(iso[1]), Number(iso[2]), Number(iso[3]));
  const long = /^(?:[\p{L}.]+,?\s+)?(\d{1,2})\.?\s+([\p{L}.]+)\s+(\d{4})$/u.exec(t);
  if (!long) return undefined;
  for (const names of [monthNames(locale), monthNames('en')]) {
    const m = names.indexOf(long[2]!.replace(/\.$/, ''));
    if (m >= 0) return valid(Number(long[3]), m + 1, Number(long[1]));
  }
  return undefined;
}

interface NotebookLike {
  id: string;
  name: string;
}
interface NoteLike {
  id: string;
  title: string;
  notebookID?: string;
  createdAt: string;
  deletedAt?: string;
}

/** The "Daily Notes" notebook; with several, the one with the most live notes, then the oldest note, then the id. */
export function dailyNotebook(notebooks: NotebookLike[], notes: NoteLike[]): string | undefined {
  const named = notebooks.filter((n) => n.name.trim().toLowerCase() === DAILY_NOTEBOOK_NAME.toLowerCase()).map((n) => n.id);
  if (named.length < 2) return named[0];
  const score = (id: string) => {
    const mine = notes.filter((n) => !n.deletedAt && n.notebookID === id);
    return { count: mine.length, oldest: Math.min(...mine.map((n) => Date.parse(n.createdAt)), Infinity) };
  };
  return [...named].sort((a, b) => {
    const sa = score(a);
    const sb = score(b);
    return sb.count - sa.count || sa.oldest - sb.oldest || a.toUpperCase().localeCompare(b.toUpperCase());
  })[0];
}

/** The oldest live note in `notebookID` titled as `day`. */
export function findDailyNote(notes: NoteLike[], notebookID: string, day: DayKey, locale?: string): string | undefined {
  return notes
    .filter((n) => !n.deletedAt && n.notebookID === notebookID && sameDay(parseDailyTitle(n.title, locale), day))
    .sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt) || a.id.localeCompare(b.id))[0]?.id;
}
