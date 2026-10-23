/**
 * Templates: ordinary notes in the "Templates" notebook whose `{{title}}`, `{{date[:format]}}`, `{{time[:format]}}`,
 * `{{clipboard}}` and `{{cursor}}` placeholders are filled in (= Swift `TemplateExpander`). Formats use Unicode
 * date patterns (`yyyy-MM-dd`, `EEEE d MMMM`, `HH:mm` …) as native `DateFormatter` does.
 */
import type { Block, Inline, NoteItDoc } from './schema.js';

export const TEMPLATES_NOTEBOOK_NAME = 'Templates';
export const CLIPBOARD_LIMIT = 10_000;
const PATTERN = /\{\{(title|date|time|clipboard|cursor)(?::([^}\n]{1,64}))?\}\}/gi;

export interface TemplateContext {
  title: string;
  date: Date;
  locale?: string;
  clipboard?: string;
}

/** A Unicode date pattern with the common fields; quoted 'text' is literal. */
export function formatDatePattern(date: Date, pattern: string, locale?: string): string {
  const part = (opts: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat(locale, opts).format(date);
  const pad = (n: number, w = 2) => String(n).padStart(w, '0');
  const h12 = date.getHours() % 12 || 12;
  const fields: Record<string, () => string> = {
    yyyy: () => String(date.getFullYear()),
    yy: () => pad(date.getFullYear() % 100),
    y: () => String(date.getFullYear()),
    MMMM: () => part({ month: 'long' }),
    MMM: () => part({ month: 'short' }),
    MM: () => pad(date.getMonth() + 1),
    M: () => String(date.getMonth() + 1),
    dd: () => pad(date.getDate()),
    d: () => String(date.getDate()),
    EEEE: () => part({ weekday: 'long' }),
    EEE: () => part({ weekday: 'short' }),
    E: () => part({ weekday: 'short' }),
    HH: () => pad(date.getHours()),
    H: () => String(date.getHours()),
    hh: () => pad(h12),
    h: () => String(h12),
    mm: () => pad(date.getMinutes()),
    m: () => String(date.getMinutes()),
    ss: () => pad(date.getSeconds()),
    s: () => String(date.getSeconds()),
    a: () => (date.getHours() < 12 ? 'AM' : 'PM'),
  };
  return pattern.replace(/'([^']*)'|yyyy|yy|y|MMMM|MMM|MM|M|dd|d|EEEE|EEE|E|HH|H|hh|h|mm|m|ss|s|a/g, (m, quoted: string | undefined) =>
    quoted !== undefined ? quoted || "'" : fields[m]!(),
  );
}

/** The template's name in pickers: its title without placeholders and edge punctuation. */
export function templateDisplayName(title: string): string {
  const name = title.replace(PATTERN, '').replace(/^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$/gu, '');
  return name || 'Untitled Template';
}

export interface Expansion {
  doc: NoteItDoc;
  /** Where `{{cursor}}` was: block index and character offset in that block's text. */
  cursor?: { block: number; offset: number };
}

/** Fills in the placeholders in every text run (a placeholder split across formatting is left as written). */
export function expandTemplate(doc: NoteItDoc, ctx: TemplateContext): Expansion {
  const copy = JSON.parse(JSON.stringify(doc)) as NoteItDoc;
  let cursor: Expansion['cursor'];
  let clip = (ctx.clipboard ?? '').replace(/[\r\n]+$/, '');
  if (clip.length > CLIPBOARD_LIMIT) clip = clip.slice(0, CLIPBOARD_LIMIT);
  const value = (name: string, format: string | undefined) => {
    switch (name.toLowerCase()) {
      case 'title':
        return ctx.title;
      case 'date':
        return formatDatePattern(ctx.date, format ?? 'yyyy-MM-dd', ctx.locale);
      case 'time':
        return format ? formatDatePattern(ctx.date, format, ctx.locale) : new Intl.DateTimeFormat(ctx.locale, { timeStyle: 'short' }).format(ctx.date);
      case 'clipboard':
        return clip;
      default:
        return '';
    }
  };
  const visit = (content: Inline[] | undefined, block: number) => {
    let offset = 0;
    for (const node of content ?? []) {
      if (node.type !== 'text') {
        offset += 1;
        continue;
      }
      node.text = node.text.replace(PATTERN, (m, name: string, format: string | undefined, at: number) => {
        if (name.toLowerCase() === 'cursor' && !cursor) cursor = { block, offset: offset + at };
        return value(name, format);
      });
      offset += node.text.length;
    }
  };
  copy.content.forEach((b: Block, i) => {
    if (b.type === 'blockquote') b.content.forEach((p) => visit(p.content, i));
    else if (b.type === 'table') b.content.forEach((r) => r.content.forEach((c) => c.content.forEach((p) => visit(p.content, i))));
    else if ('content' in b) visit(b.content as Inline[] | undefined, i);
  });
  // Runs emptied by the expansion are dropped (an empty text node isn't valid in the doc).
  const prune = (content: Inline[] | undefined) => content?.filter((n) => n.type !== 'text' || n.text.length > 0);
  copy.content.forEach((b: Block) => {
    if ('content' in b && b.type !== 'blockquote' && b.type !== 'table') (b as { content?: Inline[] }).content = prune((b as { content?: Inline[] }).content);
  });
  return cursor ? { doc: copy, cursor } : { doc: copy };
}
