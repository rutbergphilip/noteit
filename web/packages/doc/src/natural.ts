/**
 * Dates written in words: a port of Swift `NaturalDateParser` (exact forms, then English short forms). Native's
 * last resort, NSDataDetector ("October 21 at 1:30 PM"), has no browser equivalent, so those forms aren't read
 * here. The shared `dates` vectors in organise-vectors.json run on both sides.
 */
import { type LocalDateTime, localDateTimeToken, parseLocalDateTime } from './tokens.js';

export interface NaturalDateOptions {
  /** A date without a time gets this hour (reminders); unset leaves it date-only. */
  defaultHour?: number;
  /** "midnight" ends the named day (00:00 the next day), as a reminder needs. Default true. */
  midnightEndsDay?: boolean;
  /** IANA zone the words are read in; the device's by default. */
  timeZone?: string;
  /** First day of the week, 1 = Sunday … 7 = Saturday (Swift Calendar.firstWeekday). Default 1. */
  firstWeekday?: number;
}

export interface NaturalDateResult {
  value: LocalDateTime;
  /** UTF-16 offsets of the words read. */
  start: number;
  end: number;
}

const WEEKDAYS: [string[], number][] = [
  [['sunday', 'sun'], 1], [['monday', 'mon'], 2], [['tuesday', 'tue', 'tues'], 3], [['wednesday', 'wed'], 4],
  [['thursday', 'thu', 'thur', 'thurs'], 5], [['friday', 'fri'], 6], [['saturday', 'sat'], 7],
];
const TIME = String.raw`(?:\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)|\s+(?:at\s+)?(\d{1,2}):(\d{2})|\s+(?:at\s+)?(noon|midnight))?`;
const WEEKDAY_ALT = WEEKDAYS.flatMap(([n]) => n).sort((a, b) => b.length - a.length).join('|');
const SHORT_SRC = String.raw`(?<![\w+])(today|tonight|tomorrow|tmrw|(?:next\s+)?(?:${WEEKDAY_ALT})|\+(\d{1,3})([dw])|in\s+(\d{1,3})\s+(minutes?|mins?|hours?|hrs?|days?|weeks?))(?!\w)${TIME}(?!\w)`;
const SHORT = new RegExp(SHORT_SRC, 'i');
const SHORT_AT = new RegExp(SHORT_SRC, 'iy');
const ISO = /(?<![\d-])(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}):(\d{2}))?(?![\d:])/;
const CLOCK = /(?<![\w:.])(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?!\w)|(?<![\w:.])(?:at\s+)?(\d{1,2}):(\d{2})(?![\w:])/i;
const LEADING = /(?<![\w:.])(?:at\s+)?(?:(\d{1,2})(?::(\d{2}))?\s*(am|pm)|(\d{1,2}):(\d{2})|(noon|midnight))\s+(?:on\s+)?/gi;

type Clock = [number, number];

function clock(m: RegExpExecArray, hour: number, minute: number, meridiem?: number): Clock | undefined {
  if (m[hour] === undefined) return undefined;
  let h = Number(m[hour]);
  const min = m[minute] === undefined ? 0 : Number(m[minute]);
  if (meridiem !== undefined && m[meridiem] !== undefined) {
    if (h < 1 || h > 12) return undefined;
    h = (h % 12) + (m[meridiem]!.toLowerCase() === 'pm' ? 12 : 0);
  }
  return h >= 0 && h <= 23 && min >= 0 && min <= 59 ? [h, min] : undefined;
}
const named = (m: RegExpExecArray, g: number): Clock | undefined => (m[g] === undefined ? undefined : m[g]!.toLowerCase() === 'noon' ? [12, 0] : [0, 0]);
const isMidnight = (m: RegExpExecArray, g: number) => m[g]?.toLowerCase() === 'midnight';

/** Wall-clock parts of `d` in `timeZone`. */
export function partsIn(d: Date, timeZone?: string): LocalDateTime & { second: number } {
  const f = new Intl.DateTimeFormat('en-US', { timeZone, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric' });
  const p = Object.fromEntries(f.formatToParts(d).map((x) => [x.type, x.value]));
  return { year: Number(p.year), month: Number(p.month), day: Number(p.day), hour: Number(p.hour) % 24, minute: Number(p.minute), second: Number(p.second) };
}
const dayNumber = (v: LocalDateTime) => Date.UTC(v.year, v.month - 1, v.day) / 86_400_000;
function addDays(v: LocalDateTime, days: number): LocalDateTime {
  const d = new Date((dayNumber(v) + days) * 86_400_000);
  const out: LocalDateTime = { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
  if (v.hour !== undefined) {
    out.hour = v.hour;
    out.minute = v.minute ?? 0;
  }
  return out;
}
const withTime = (v: LocalDateTime, [hour, minute]: Clock): LocalDateTime => ({ year: v.year, month: v.month, day: v.day, hour, minute });
/** 1 = Sunday, as Swift. */
const weekday = (v: LocalDateTime) => new Date(dayNumber(v) * 86_400_000).getUTCDay() + 1;

function shortForm(m: RegExpExecArray, now: Date, today: LocalDateTime, o: Required<Omit<NaturalDateOptions, 'defaultHour' | 'timeZone'>> & NaturalDateOptions, leadingTime?: Clock, leadingMidnight = false): LocalDateTime | undefined {
  const word = m[1]!.toLowerCase();
  const trailing = clock(m, 6, 7, 8) ?? clock(m, 9, 10) ?? named(m, 11);
  let time = trailing ?? leadingTime;
  const saysMidnight = trailing === undefined ? leadingMidnight : isMidnight(m, 11);
  if (saysMidnight && !o.midnightEndsDay) time = undefined;
  const at = (day: LocalDateTime): LocalDateTime => {
    if (!time) return day;
    if (saysMidnight) return withTime(addDays(day, 1), [0, 0]);
    return withTime(day, time);
  };
  if ((word === 'today' || word === 'tonight') && time && time[0] === 0 && time[1] === 0) return withTime(addDays(today, 1), [0, 0]);
  if (word === 'today') return at(today);
  if (word === 'tonight') {
    if (saysMidnight && !o.midnightEndsDay) return today;
    return withTime(today, time ?? [20, 0]);
  }
  if (word === 'tomorrow' || word === 'tmrw') return at(addDays(today, 1));
  if (m[2] !== undefined) return at(addDays(today, m[3]!.toLowerCase() === 'w' ? Number(m[2]) * 7 : Number(m[2])));
  if (m[4] !== undefined) {
    const n = Number(m[4]);
    const unit = m[5]!.toLowerCase();
    if (unit.startsWith('m') || unit.startsWith('h')) {
      const p = partsIn(new Date(now.getTime() + n * (unit.startsWith('h') ? 3_600_000 : 60_000)), o.timeZone);
      return { year: p.year, month: p.month, day: p.day, hour: p.hour!, minute: p.minute! };
    }
    return at(addDays(today, unit.startsWith('w') ? n * 7 : n));
  }
  const next = word.startsWith('next');
  const name = next ? word.slice(4).trim() : word;
  const target = WEEKDAYS.find(([names]) => names.includes(name))?.[1];
  if (!target) return undefined;
  let ahead = (target - weekday(today) + 7) % 7;
  if (ahead === 0) ahead = 7;
  if (next) {
    const weekStart = (v: LocalDateTime) => dayNumber(v) - ((weekday(v) - o.firstWeekday + 7) % 7);
    if (weekStart(addDays(today, ahead)) === weekStart(today)) ahead += 7;
  }
  return at(addDays(today, ahead));
}

/** The first date found in `text`; weekday names never mean today. */
export function parseNaturalDate(text: string, now: Date = new Date(), opts: NaturalDateOptions = {}): NaturalDateResult | undefined {
  const o = { midnightEndsDay: true, firstWeekday: 1, ...opts };
  const nowParts = partsIn(now, o.timeZone);
  const today: LocalDateTime = { year: nowParts.year, month: nowParts.month, day: nowParts.day };
  const result = (value: LocalDateTime, start: number, end: number): NaturalDateResult => ({
    value: value.hour === undefined && o.defaultHour !== undefined ? withTime(value, [o.defaultHour, 0]) : value,
    start,
    end,
  });

  const iso = ISO.exec(text);
  if (iso) {
    const v = parseLocalDateTime(iso[1]! + (iso[2] !== undefined ? ` ${iso[2]}:${iso[3]}` : ''));
    if (v) return result(v, iso.index, iso.index + iso[0].length);
  }

  const short = SHORT.exec(text);
  LEADING.lastIndex = 0;
  for (let lead = LEADING.exec(text); lead; lead = LEADING.exec(text)) {
    if (short && short.index < lead.index) break;
    const end = lead.index + lead[0].length;
    SHORT_AT.lastIndex = end;
    const day = SHORT_AT.exec(text);
    if (!day || (day[4] !== undefined && /^[mh]/i.test(day[5]!))) continue;
    const leadTime = clock(lead, 1, 2, 3) ?? clock(lead, 4, 5) ?? named(lead, 6);
    if (!leadTime) continue;
    const value = shortForm(day, now, today, o, leadTime, isMidnight(lead, 6));
    if (value) return result(value, lead.index, day.index + day[0].length);
  }
  if (short) {
    const value = shortForm(short, now, today, o);
    if (value) return result(value, short.index, short.index + short[0].length);
  }

  const c = CLOCK.exec(text);
  const t = c && (clock(c, 1, 2, 3) ?? clock(c, 4, 5));
  if (c && t) {
    let value = withTime(today, t);
    const minutes = (v: LocalDateTime) => dayNumber(v) * 1440 + (v.hour ?? 0) * 60 + (v.minute ?? 0);
    if (minutes(value) <= minutes(nowParts)) value = addDays(value, 1);
    return result(value, c.index, c.index + c[0].length);
  }
  return undefined;
}

/** The first day of the week where the browser runs, as Swift's 1 = Sunday … 7 = Saturday. */
export function localFirstWeekday(): number {
  try {
    const info = (new Intl.Locale(typeof navigator === 'undefined' ? 'en-US' : navigator.language) as Intl.Locale & { weekInfo?: { firstDay: number }; getWeekInfo?: () => { firstDay: number } });
    const first = info.getWeekInfo?.().firstDay ?? info.weekInfo?.firstDay ?? 7;
    return (first % 7) + 1;
  } catch {
    return 1;
  }
}

const TOKEN = /@(due|remind)\(([^()\n]*)\)$/;

/**
 * `@due(fri)` or `@remind(tomorrow 9am)` → a full date once its `)` is typed (native DateTokenAutoFormat). `text`
 * ends with that `)`. Undefined when the token is a full date already or not a date at all.
 */
export function dateTokenRewrite(text: string, now: Date = new Date(), opts: { reminderMinutes?: number; timeZone?: string; firstWeekday?: number } = {}): { start: number; end: number; replacement: string } | undefined {
  const m = TOKEN.exec(text);
  if (!m) return undefined;
  const kind = m[1] as 'due' | 'remind';
  let inner = m[2]!.trim();
  let done = false;
  if (kind === 'remind' && inner.toLowerCase().endsWith(' done')) {
    done = true;
    inner = inner.slice(0, -5).trim();
  }
  if (!inner || parseLocalDateTime(inner)) return undefined;
  const parsed = parseNaturalDate(inner, now, { midnightEndsDay: kind === 'remind', ...(opts.timeZone ? { timeZone: opts.timeZone } : {}), ...(opts.firstWeekday ? { firstWeekday: opts.firstWeekday } : {}) });
  if (!parsed) return undefined;
  const rest = inner.slice(0, parsed.start) + inner.slice(parsed.end);
  if (rest.replace(/[\s\p{P}]/gu, '')) return undefined;
  let value = parsed.value;
  if (kind === 'remind' && value.hour === undefined) {
    const minutes = opts.reminderMinutes ?? 9 * 60;
    value = withTime(value, [Math.floor(minutes / 60) % 24, minutes % 60]);
  }
  return { start: m.index, end: m.index + m[0].length, replacement: `@${kind}(${localDateTimeToken(value)}${done ? ' done' : ''})` };
}
