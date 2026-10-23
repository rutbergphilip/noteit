/** Note Info, outline and note links, as the native Links and Outline panel shows them. */
import { maskedText } from './derive.js';
import { type Block, type Inline, type NoteItDoc, parseNoteLink } from './schema.js';
import { type LocalDateTime, parseTasks, type ReminderLine, taskDisplayText } from './tokens.js';

const OBJECT = '￼';

/** = Swift `NoteStatistics`: U+FFFC (images, files) is neither a word nor a character. */
export interface NoteStatistics {
  words: number;
  characters: number;
}

export const WORDS_PER_MINUTE = 200;

const wordSegmenter = new Intl.Segmenter(undefined, { granularity: 'word' });
const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

export function noteStatistics(text: string): NoteStatistics {
  let words = 0;
  for (const s of wordSegmenter.segment(text.replaceAll(OBJECT, ' '))) if (s.isWordLike) words += 1;
  let characters = 0;
  for (const _ of graphemes.segment(text.replaceAll(OBJECT, ''))) characters += 1;
  return { words, characters };
}

export function readingMinutes(s: NoteStatistics): number {
  return s.words === 0 ? 0 : Math.ceil(s.words / WORDS_PER_MINUTE);
}

/** "Less than a minute", "1 min" or "12 min"; "—" for an empty note. */
export function readingTimeText(s: NoteStatistics): string {
  const m = readingMinutes(s);
  if (m === 0) return '—';
  if (m === 1) return s.words < WORDS_PER_MINUTE / 2 ? 'Less than a minute' : '1 min';
  return `${m} min`;
}

export interface OutlineEntry {
  level: 1 | 2 | 3;
  text: string;
  /** Index of the block in `doc.content`. */
  block: number;
}

function inlineText(content: Inline[] | undefined): string {
  return (content ?? []).map((n) => (n.type === 'text' ? n.text : n.type === 'hardBreak' ? ' ' : OBJECT)).join('');
}

export function outline(doc: NoteItDoc): OutlineEntry[] {
  const out: OutlineEntry[] = [];
  doc.content.forEach((b, i) => {
    if (b.type !== 'heading') return;
    const text = inlineText(b.content).replaceAll(OBJECT, '').trim();
    if (text) out.push({ level: b.attrs.level, text, block: i });
  });
  return out;
}

export interface NoteLinkRef {
  /** The linked note's id, upper case; absent for a link by title that doesn't resolve. */
  id?: string;
  title?: string;
  heading?: string;
  /** The text of the link. */
  text: string;
  /** The whole line the link is on, for context. */
  context: string;
}

function blockInlines(b: Block): Inline[][] {
  switch (b.type) {
    case 'paragraph':
    case 'heading':
    case 'listItem':
      return [b.content ?? []];
    case 'blockquote':
      return b.content.map((p) => p.content ?? []);
    case 'table':
      return b.content.flatMap((r) => r.content.flatMap((c) => c.content.map((p) => p.content ?? [])));
    default:
      return [];
  }
}

/** Every `noteit://note/…` link in the doc, merged across adjacent text runs with the same href. */
export function noteLinks(doc: NoteItDoc): NoteLinkRef[] {
  const out: NoteLinkRef[] = [];
  for (const block of doc.content) {
    for (const line of blockInlines(block)) {
      const context = inlineText(line).replaceAll(OBJECT, '').trim();
      let open: { href: string; text: string } | undefined;
      const flush = () => {
        if (!open) return;
        const parsed = parseNoteLink(open.href);
        if (parsed) {
          const ref: NoteLinkRef = { text: open.text, context };
          if ('id' in parsed) {
            ref.id = parsed.id;
            if (parsed.heading) ref.heading = parsed.heading;
          } else ref.title = parsed.title;
          out.push(ref);
        }
        open = undefined;
      };
      for (const node of line) {
        const href = node.type === 'text' ? node.marks?.find((m) => m.type === 'link')?.attrs.href : undefined;
        if (href && open?.href === href && node.type === 'text') {
          open.text += node.text;
          continue;
        }
        flush();
        if (href && node.type === 'text') open = { href, text: node.text };
      }
      flush();
    }
  }
  return out;
}

export interface DocTask {
  /** Index of the checklist item in `doc.content`. */
  block: number;
  /** The line without its marker and `@due`/`@remind` tokens. */
  text: string;
  checked: boolean;
  due?: LocalDateTime;
  remind?: LocalDateTime;
  remindDone: boolean;
}

/** The note's checklist items with their `@due`/`@remind` dates, read from masked text as native does. */
export function docTasks(doc: NoteItDoc): DocTask[] {
  const out: DocTask[] = [];
  doc.content.forEach((b, i) => {
    if (b.type !== 'listItem' || b.attrs.kind !== 'task') return;
    const masked = maskedText({ type: 'doc', content: [b] });
    const parsed = parseTasks(masked).tasks[0];
    if (!parsed) return;
    const task: DocTask = { block: i, text: taskDisplayText(inlineText(b.content)), checked: parsed.checked, remindDone: parsed.remindDone };
    if (parsed.due) task.due = parsed.due;
    if (parsed.remind) task.remind = parsed.remind;
    out.push(task);
  });
  return out;
}

/** Every `@remind(…)` line of the note (checklist items and plain lines). */
export function docReminders(doc: NoteItDoc): ReminderLine[] {
  return parseTasks(maskedText(doc)).reminders;
}

export function hasAttachments(doc: NoteItDoc): boolean {
  const visit = (inl: Inline[]) => inl.some((n) => n.type === 'image' || n.type === 'attachment');
  return doc.content.some((b) => blockInlines(b).some(visit));
}
