/**
 * Quick Capture's reminder offer (native NoteStore.captureReminder / addingCaptureReminder, ReminderSetPopover):
 * a future date written in the note's first line becomes an `@remind(…)` at the end of that line when the note is
 * saved with the offer turned on.
 */
import { parseNaturalDate, partsIn } from './natural.js';
import { compareLocal, type LocalDateTime, localDateTimeToken, taskDisplayText } from './tokens.js';

export interface ReminderOfferOptions {
  /** Native `reminderDefaultTime`: minutes after midnight for a date without a time (09:00). */
  defaultMinutes?: number;
  timeZone?: string;
  firstWeekday?: number;
}

/** The future reminder a line's own words give (native reminderDate(inLine:)), else undefined. */
export function reminderDateInLine(line: string, now: Date = new Date(), opts: ReminderOfferOptions = {}): LocalDateTime | undefined {
  const minutes = Math.min(Math.max(opts.defaultMinutes ?? 540, 0), 24 * 60 - 1);
  const found = parseNaturalDate(taskDisplayText(line), now, { ...(opts.timeZone ? { timeZone: opts.timeZone } : {}), ...(opts.firstWeekday ? { firstWeekday: opts.firstWeekday } : {}) });
  if (!found) return undefined;
  const value: LocalDateTime = found.value.hour === undefined ? { ...found.value, hour: Math.trunc(minutes / 60), minute: minutes % 60 } : found.value;
  const { second: _s, ...current } = partsIn(now, opts.timeZone);
  return compareLocal(value, current) > 0 ? value : undefined;
}

function firstLine(title: string, body: string): string {
  const t = title.trim();
  return ((t || body.trim()).split('\n')[0] ?? '');
}

/** The reminder Quick Capture offers: the future date in the first line, unless the line already has a reminder. */
export function captureReminder(title: string, body: string, now: Date = new Date(), opts: ReminderOfferOptions = {}): LocalDateTime | undefined {
  const line = firstLine(title, body);
  if (line.includes('@remind(')) return undefined;
  return reminderDateInLine(line, now, opts);
}

/** Title and body with `@remind(…)` added to the end of the first line. */
export function addingCaptureReminder(at: LocalDateTime, title: string, body: string): { title: string; body: string } {
  const token = `@remind(${localDateTimeToken(at)})`;
  const t = title.trim();
  if (t) return { title: `${t} ${token}`, body };
  const lines = body.trim().split('\n');
  lines[0] += ` ${token}`;
  return { title, body: lines.join('\n') };
}

const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "tomorrow at 09:00", "today at 18:30", "Fri 30 Oct at 08:00" (native ReminderSetPopover.dayAndTime). */
export function reminderDayAndTime(value: LocalDateTime, now: Date = new Date(), timeZone?: string): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  const time = `${pad(value.hour ?? 0)}:${pad(value.minute ?? 0)}`;
  const today = partsIn(now, timeZone);
  const tomorrow = partsIn(new Date(Date.UTC(today.year, today.month - 1, today.day + 1, 12)), 'UTC');
  const same = (a: { year: number; month: number; day: number }) => a.year === value.year && a.month === value.month && a.day === value.day;
  let day: string;
  if (same(today)) day = 'today';
  else if (same(tomorrow)) day = 'tomorrow';
  else day = `${WEEKDAYS[new Date(Date.UTC(value.year, value.month - 1, value.day)).getUTCDay()]} ${value.day} ${MONTHS[value.month - 1]}`;
  return `${day} at ${time}`;
}
