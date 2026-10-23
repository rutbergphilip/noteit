process.env.TZ = 'Europe/Stockholm';

import { readdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  type BodyContainer,
  dailyNotebook,
  dailyTitle,
  dateTokens,
  findDailyNote,
  parseDailyTitle,
  docToHtml,
  docToMarkdown,
  expandTemplate,
  formatDatePattern,
  localDateTimeToken,
  matchesQuery,
  noteLinks,
  noteStatistics,
  outline,
  parseLocalDateTime,
  parseQuery,
  parseTasks,
  type QueryNode,
  readingTimeText,
  searchFold,
  tagsIn,
  templateDisplayName,
} from '../src/index.js';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
/** The organise vectors the Swift NoteItCore tests read too. */
const vectors = JSON.parse(readFileSync(resolve(repo, 'Tests/NoteItCoreTests/Vectors/organise-vectors.json'), 'utf8')) as Record<string, any>;

/** The vectors file's tree notation (= Swift `describe` in SearchQueryTests). */
function describeNode(n: QueryNode): string {
  switch (n.type) {
    case 'all':
      return 'all';
    case 'word':
    case 'phrase':
    case 'title':
    case 'tag':
    case 'notebook':
      return `${n.type}(${n.value})`;
    case 'is':
    case 'has':
      return `${n.type}(${n.filter})`;
    case 'date': {
      const f = n.filter;
      const v = 'seconds' in f ? `${f.type}(${f.seconds})` : 'day' in f ? `${f.type}(${localDateTimeToken(f.day)})` : f.type;
      return `date(${n.field},${v})`;
    }
    case 'not':
      return `not(${describeNode(n.node)})`;
    case 'and':
    case 'or':
      return `${n.type}(${n.nodes.map(describeNode).join(',')})`;
  }
}

describe('organise vectors (shared with Swift)', () => {
  it('tags', () => {
    for (const v of vectors.tags) expect(tagsIn(v.input), v.input).toEqual(v.tags);
  });

  it('date tokens', () => {
    for (const v of vectors.tokens) {
      const want = (v.tokens as { kind: string }[]).filter((t) => t.kind !== 'tag');
      const got = dateTokens(v.input).map((t) => ({
        kind: t.kind.type,
        value: localDateTimeToken(t.kind.value),
        ...(t.kind.type === 'remind' ? { done: t.kind.done } : {}),
        start: t.index,
        length: t.length,
      }));
      expect(got, v.input).toEqual(want);
    }
  });

  it('query trees, highlights and issues', () => {
    for (const v of vectors.queries) {
      const q = parseQuery(v.input);
      expect(describeNode(q.root), v.input).toBe(v.tree);
      if (v.highlight) expect(q.highlightTerms, v.input).toEqual(v.highlight);
      if (v.text !== undefined) expect(q.hasTextTerms, v.input).toBe(v.text);
      if (v.issues !== undefined) expect(q.issues.length, v.input).toBe(v.issues);
      if (v.message) expect(q.issues[0]?.message).toBe(v.message);
    }
  });

  it('statistics', () => {
    for (const v of vectors.statistics) {
      const s = noteStatistics(v.text);
      expect(s, v.text).toEqual({ words: v.words, characters: v.characters });
      expect(readingTimeText(s)).toBe(v.reading);
    }
  });

  it('evaluate', () => {
    const e = vectors.evaluate;
    const at = (t?: string) => (t ? new Date(t.replace(' ', 'T')) : new Date(0));
    const ctx = { now: at(e.now), notebooks: e.notebooks, firstWeekday: 1 };
    for (const c of e.cases) {
      const d = c.doc;
      const doc = {
        foldedText: searchFold(d.text ?? ''),
        foldedTitle: searchFold(d.title ?? ''),
        tags: d.tags ?? [],
        ...(d.notebook ? { notebookID: d.notebook } : {}),
        isPinned: !!d.isPinned,
        isConflict: !!d.isConflict,
        createdAt: at(d.createdAt),
        updatedAt: at(d.updatedAt),
        openTaskCount: d.open ?? 0,
        doneTaskCount: d.done ?? 0,
        openDueDates: (d.due ?? []).map((t: string) => parseLocalDateTime(t)!),
        hasLiveReminder: !!d.reminder,
        hasAttachment: !!d.attachment,
      };
      expect(matchesQuery(parseQuery(c.query), doc, ctx), c.query).toBe(c.match);
    }
  });
});

describe('tasks', () => {
  it('reads checkboxes, due dates and reminders from masked text', () => {
    const { tasks, reminders } = parseTasks('☐\tpay @due(2026-10-21)\n☑\tdone\nCall @remind(2026-10-20 09:00)');
    expect(tasks.map((t) => [t.checked, t.due && localDateTimeToken(t.due)])).toEqual([
      [false, '2026-10-21'],
      [true, undefined],
    ]);
    expect(reminders).toEqual([{ paragraph: 2, text: 'Call', at: parseLocalDateTime('2026-10-20 09:00'), done: false, isTask: false, checked: false }]);
  });
});

/** The Swift Markdown codec's fixtures without library-only syntax (NoteIt comments, font sizes, attachment folders). */
describe('Markdown export matches the Swift codec fixtures', () => {
  const dir = resolve(repo, 'Tests/NoteItMarkdownTests/Fixtures');
  const names = readdirSync(dir)
    .filter((n) => n.endsWith('.md') && !n.startsWith('read-'))
    .map((n) => n.slice(0, -3))
    .filter((n) => !/noteit:|data-size/.test(readFileSync(resolve(dir, `${n}.md`), 'utf8')));
  const names_ = new Map([
    ['8F14E45F-CEEA-467A-9575-5E4F0C6B7A21', 'Plan'],
    ['1C2B3A49-5D6E-4F70-8192-A3B4C5D6E7F8', 'Work/Plan'],
  ]);
  it('has fixtures', () => expect(names.length).toBeGreaterThan(15));
  for (const name of names) {
    it(name, () => {
      const body = JSON.parse(readFileSync(resolve(dir, `${name}.json`), 'utf8')) as BodyContainer;
      const md = docToMarkdown(body.doc, { attachmentPath: (sha) => sha, noteName: (id) => names_.get(id) });
      expect(md).toBe(readFileSync(resolve(dir, `${name}.md`), 'utf8'));
    });
  }
});

describe('note info, links and outline', () => {
  const doc = {
    type: 'doc' as const,
    content: [
      { type: 'heading' as const, attrs: { level: 1 as const }, content: [{ type: 'text' as const, text: 'Plan' }] },
      {
        type: 'paragraph' as const,
        content: [
          { type: 'text' as const, text: 'See ' },
          { type: 'text' as const, text: 'Bud', marks: [{ type: 'link' as const, attrs: { href: 'noteit://note/8F14E45F-CEEA-467A-9575-5E4F0C6B7A21' } }] },
          { type: 'text' as const, text: 'get', marks: [{ type: 'bold' as const }, { type: 'link' as const, attrs: { href: 'noteit://note/8F14E45F-CEEA-467A-9575-5E4F0C6B7A21' } }] },
          { type: 'text' as const, text: ' and ' },
          { type: 'text' as const, text: 'web', marks: [{ type: 'link' as const, attrs: { href: 'https://example.com' } }] },
        ],
      },
      { type: 'heading' as const, attrs: { level: 2 as const }, content: [{ type: 'text' as const, text: 'Steps' }] },
    ],
  };
  it('lists headings and note links', () => {
    expect(outline(doc).map((o) => [o.level, o.text])).toEqual([
      [1, 'Plan'],
      [2, 'Steps'],
    ]);
    expect(noteLinks(doc)).toEqual([{ id: '8F14E45F-CEEA-467A-9575-5E4F0C6B7A21', text: 'Budget', context: 'See Budget and web' }]);
  });
  it('writes HTML without note-link anchors', () => {
    const html = docToHtml(doc, { title: 'Plan <1>' });
    expect(html).toContain('<title>Plan &lt;1&gt;</title>');
    expect(html).toContain('<a href="https://example.com">web</a>');
    expect(html).not.toContain('noteit://');
  });
});

describe('daily notes (as Swift DailyNoteTitleTests)', () => {
  const day = { year: 2026, month: 10, day: 19 };
  it('titles and parses every format', () => {
    expect(dailyTitle(day, 'iso', 'en')).toBe('2026-10-19');
    expect(dailyTitle(day, 'long', 'en')).toBe('19 October 2026');
    expect(dailyTitle(day, 'weekdayLong', 'en')).toBe('Monday, 19 October 2026');
    expect(dailyTitle(day, 'weekdayLong', 'sv')).toBe('måndag, 19 oktober 2026');
    for (const f of ['iso', 'long', 'weekdayLong'] as const) {
      expect(parseDailyTitle(dailyTitle(day, f, 'en'), 'en')).toEqual(day);
      expect(parseDailyTitle(dailyTitle(day, f, 'sv'), 'sv')).toEqual(day);
    }
    expect(parseDailyTitle('Monday, 19 October 2026', 'sv')).toEqual(day);
    expect(parseDailyTitle('2026-02-30')).toBeUndefined();
  });
  it('picks one Daily Notes notebook everywhere', () => {
    const notebooks = [
      { id: 'B', name: 'Daily Notes' },
      { id: 'A', name: 'daily notes ' },
    ];
    const notes = [{ id: 'n', title: '2026-10-19', notebookID: 'B', createdAt: '2026-10-19T08:00:00Z' }];
    expect(dailyNotebook(notebooks, notes)).toBe('B');
    expect(findDailyNote(notes, 'B', day)).toBe('n');
  });
});

describe('templates', () => {
  const date = new Date(2026, 9, 24, 9, 5);
  it('fills placeholders and finds the cursor', () => {
    const doc = { type: 'doc' as const, content: [{ type: 'paragraph' as const, content: [{ type: 'text' as const, text: '{{title}} on {{date}} at {{time:HH:mm}}: {{cursor}}' }] }] };
    const out = expandTemplate(doc, { title: 'Standup', date, locale: 'en-US' });
    expect(out.doc.content[0]).toEqual({ type: 'paragraph', content: [{ type: 'text', text: 'Standup on 2026-10-24 at 09:05: ' }] });
    expect(out.cursor?.block).toBe(0);
  });
  it('formats Unicode date patterns', () => {
    expect(formatDatePattern(date, "EEEE d MMMM yyyy 'week'", 'en-US')).toBe('Saturday 24 October 2026 week');
  });
  it('names templates without placeholders', () => {
    expect(templateDisplayName('Meeting – {{date}}')).toBe('Meeting');
    expect(templateDisplayName('{{date}}')).toBe('Untitled Template');
  });
});
