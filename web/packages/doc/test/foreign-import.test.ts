// @vitest-environment happy-dom
// The cases of the Mac's EvernoteImporterTests, NotionImporterTests and MarkdownImporterTests (TextBundle), with the
// same inputs and expectations.
import { zipSync, strToU8 } from 'fflate';
import { describe, expect, it } from 'vitest';
import {
  enexDate,
  evernoteBody,
  evernoteFileName,
  evernoteReminderToken,
  ImportTags,
  isEvernoteNoteLink,
  md5Hex,
  notionPageBody,
  notionPages,
  notionPrepared,
  notionRemoteImagesAsLinks,
  notionOutsideCode,
  notionStripID,
  notionTableBody,
  notionTitleOfFile,
  notionTitleOfStem,
  parseEnexNote,
  readEnex,
  readNotionCSV,
  sanitizedImportTag,
  standardZipLimits,
  textBundleDates,
  textBundleTextPath,
  textPackBundle,
  unzipArchive,
  validateContainer,
  ZipTooLargeError,
  type Block,
  type BodyContainer,
  type Inline,
} from '../src/index.js';

const PNG = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='), (c) => c.charCodeAt(0));
const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

function note(title: string, content: string, opts: { created?: string; updated?: string; tags?: string[]; extra?: string } = {}): string {
  return `<note><title>${title}</title><created>${opts.created ?? '20240102T030405Z'}</created><updated>${opts.updated ?? '20240203T040506Z'}</updated>
${(opts.tags ?? []).map((t) => `<tag>${t}</tag>`).join('')}
<content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>${content}</en-note>]]></content>
${opts.extra ?? ''}</note>`;
}

function resource(data: Uint8Array, mime: string, fileName?: string): string {
  return `<resource><data encoding="base64">\n${b64(data)}\n</data><mime>${mime}</mime>${fileName ? `<resource-attributes><file-name>${fileName}</file-name></resource-attributes>` : ''}</resource>`;
}

function enex(notes: string[]): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd">
<en-export export-date="20240301T000000Z" application="Evernote" version="10">
${notes.join('\n')}
</en-export>`;
}

const textOf = (content: Inline[] | undefined) => (content ?? []).map((n) => (n.type === 'text' ? n.text : '￼')).join('');
function lines(body: BodyContainer): string[] {
  return body.doc.content.map((b: Block) => (b.type === 'table' ? '[table]' : b.type === 'horizontalRule' ? '---' : b.type === 'blockquote' ? b.content.map((p) => textOf(p.content)).join('\n') : textOf(b.content)));
}
function walkInlines(body: BodyContainer): Inline[] {
  const out: Inline[] = [];
  const walk = (n: unknown) => {
    if (!n || typeof n !== 'object') return;
    const x = n as { type?: string; content?: unknown[] };
    if (x.type === 'text' || x.type === 'image' || x.type === 'attachment') out.push(x as Inline);
    x.content?.forEach(walk);
  };
  walk(body.doc);
  return out;
}
const linksIn = (body: BodyContainer) =>
  walkInlines(body).flatMap((n) => (n.type === 'text' ? (n.marks ?? []).flatMap((m) => (m.type === 'link' ? [m.attrs.href] : [])) : [])).filter((h, i, a) => a.indexOf(h) === i);

describe('Evernote import (native EvernoteImporter)', () => {
  it('reads a note with dates, tags and a checklist', () => {
    const { notes, isExport } = readEnex(enex([note('Groceries', '<div>Weekly list</div><div><en-todo checked="false"/>Milk</div><div><en-todo checked="true"/>Bread</div>', { tags: ['Home', 'shopping list', '2024'] })]));
    expect(isExport).toBe(true);
    const n = notes[0]!;
    expect(n.created?.toISOString()).toBe('2024-01-02T03:04:05.000Z');
    expect(n.updated?.toISOString()).toBe('2024-02-03T04:05:06.000Z');
    const { body } = evernoteBody(n, n.title, new ImportTags());
    expect(lines(body)).toEqual(['Groceries', 'Weekly list', 'Milk', 'Bread', '#home #shopping-list #_2024']);
    expect(body.doc.content[0]).toMatchObject({ type: 'heading', attrs: { level: 1 } });
    expect(body.doc.content[2]).toMatchObject({ type: 'listItem', attrs: { kind: 'task', level: 0, checked: false } });
    expect(body.doc.content[3]).toMatchObject({ type: 'listItem', attrs: { kind: 'task', level: 0, checked: true } });
    expect(JSON.stringify(body)).not.toMatch(/[\uE010-\uE013]/);
    expect(validateContainer(body)).toBe('valid');
  });

  it('keeps a checklist in a table cell in the table, as ☑ and ☐', () => {
    const n = parseEnexNote(note('Shop', '<table><tr><td><en-todo checked="true"/>Buy milk</td><td><en-todo checked="false"/>Eggs</td></tr></table>'))!;
    const { body } = evernoteBody(n, 'Shop', new ImportTags());
    const table = body.doc.content.find((b) => b.type === 'table') as Extract<Block, { type: 'table' }>;
    const [a, b] = table.content[0]!.content.map((c) => c.content[0]!.content!);
    expect(textOf(a)).toBe('☑ Buy milk');
    expect(textOf(b)).toBe('☐ Eggs');
    expect(a!.find((x) => x.type === 'text' && x.text === 'Buy milk')).toMatchObject({ marks: [{ type: 'strike' }] });
    expect(b!.every((x) => x.type !== 'text' || !x.marks)).toBe(true);
  });

  it('makes tags valid', () => {
    expect(sanitizedImportTag('Work Stuff')).toBe('work-stuff');
    expect(sanitizedImportTag('2024')).toBe('_2024');
    expect(sanitizedImportTag('a/b/c/d/e/f/g')).toBe('a/b/c/d/e-f-g');
    expect(sanitizedImportTag('   ')).toBeUndefined();
    expect(sanitizedImportTag('!!!')).toBeUndefined();
    expect(sanitizedImportTag('C++')).toBe('c-plus-plus');
    expect(sanitizedImportTag('C#')).toBe('c-sharp');
    expect(sanitizedImportTag('+++')).toBe('plus-plus-plus');
    expect(sanitizedImportTag('R&D')).toBe('r-and-d');
    expect(sanitizedImportTag('#todo')).toBe('todo');
  });

  it('keeps distinct tags distinct and counts dropped ones', () => {
    const tags = new ImportTags();
    const { notes } = readEnex(enex([note('One', '<div>x</div>', { tags: ['C++', 'C#', '!!!', 'Work'] }), note('Two', '<div>y</div>', { tags: ['c-sharp', '🎉', 'work', 'C#'] })]));
    const one = evernoteBody(notes[0]!, 'One', tags).body;
    const two = evernoteBody(notes[1]!, 'Two', tags).body;
    expect(lines(one).at(-1)).toBe('#c-plus-plus #c-sharp #work');
    expect(lines(two).at(-1)).toBe('#c-sharp-2 #work #c-sharp');
    expect(tags.dropped.size).toBe(2);
  });

  it('turns resources into attachments, named as on the Mac', () => {
    const pdf = new TextEncoder().encode('%PDF-1.4 tiny');
    const loose = new TextEncoder().encode('loose');
    const n = parseEnexNote(
      note(
        'Receipt',
        `<div>Photo:</div><div><en-media type="image/png" hash="${md5Hex(PNG)}"/></div><div><en-media type="application/pdf" hash="${md5Hex(pdf)}"></en-media></div><div><en-media type="image/png" hash="00000000000000000000000000000000"/>gone</div>`,
        { extra: resource(PNG, 'image/png') + resource(pdf, 'application/pdf', 'Receipt March.pdf') + resource(loose, 'text/plain', 'notes') },
      ),
    )!;
    const { body, attachmentsSkipped } = evernoteBody(n, 'Receipt', new ImportTags());
    expect(attachmentsSkipped).toBe(0);
    const files = walkInlines(body).filter((x) => x.type !== 'text');
    expect(files.map((x) => (x as { attrs: { name: string } }).attrs.name)).toEqual(['image-1.png', 'Receipt March.pdf', 'notes.txt']);
    expect(files.map((x) => x.type)).toEqual(['image', 'attachment', 'attachment']);
    expect(Object.keys(body.attachments)).toHaveLength(3);
    expect(validateContainer(body)).toBe('valid');
    const text = lines(body).join('\n');
    expect(text.indexOf('Photo:')).toBeLessThan(text.indexOf('￼'));
    expect(text).toContain('gone');
  });

  it('drops encrypted sections and oversized resources, and says so', () => {
    const n = parseEnexNote(note('Secret', '<div>Visible</div><en-crypt hint="pet" cipher="AES" length="128">U2FsdGVkX19=</en-crypt><div>After</div>'))!;
    const r = evernoteBody(n, 'Secret', new ImportTags());
    expect(r.encrypted).toBe(true);
    const text = lines(r.body).join('\n');
    expect(text).toContain('Visible');
    expect(text).toContain('After');
    expect(text).not.toContain('U2FsdGVkX19');
    const big = parseEnexNote(note('Big', 'x', { extra: `<resource><data encoding="base64">${'QUFB'.repeat(9_000_000)}</data><mime>image/png</mime></resource>` }))!;
    expect(big.resourcesTooLarge).toBe(1);
    expect(big.resources).toEqual([]);
    expect(evernoteBody(big, 'Big', new ImportTags()).attachmentsSkipped).toBe(1);
  });

  it('skips a note that is not well-formed and imports the others', () => {
    const broken = '<note><title>Broken &bad; <b></title><content>oops</note>';
    const sloppy = note('Sloppy', '<div>Unclosed <b>bold<p>para</div></en-note><div>tail');
    const { notes } = readEnex(enex([note('First', '<div>one</div>'), broken, sloppy, note('Last', '<div>two</div>')]));
    expect(notes.map((n) => n?.title)).toEqual(['First', undefined, 'Sloppy', 'Last']);
    expect(lines(evernoteBody(notes[2]!, 'Sloppy', new ImportTags()).body).join('\n')).toContain('tail');
    expect(readEnex('just text')).toEqual({ notes: [], isExport: false });
  });

  it('turns Evernote note links into title links, which resolve to imported notes', () => {
    const n = parseEnexNote(
      note('Index', '<div><a href="evernote:///view/123/s1/abc-def/abc-def/">Trip plan</a> and <a href="https://www.evernote.com/shard/s1/nl/123/abc/">Elsewhere</a> and <a href="https://example.com/">site</a></div>'),
    )!;
    const id = '11111111-2222-3333-4444-555555555555';
    const { body } = evernoteBody(n, 'Index', new ImportTags(), { resolveTitle: (t) => (t === 'Trip plan' ? id : undefined) });
    expect(linksIn(body)).toEqual([`noteit://note/${id}`, 'noteit://note?title=Elsewhere', 'https://example.com/']);
    expect(isEvernoteNoteLink('https://evernote.com/shard/s1/nl/1/x')).toBe(true);
    expect(isEvernoteNoteLink('https://www.evernote.com/client/web')).toBe(false);
  });

  it('writes a reminder as a token', () => {
    const n = parseEnexNote(note('Call', '<div>Dentist</div>', { extra: '<note-attributes><reminder-time>20240105T090000Z</reminder-time><reminder-done-time>20240105T100000Z</reminder-done-time></note-attributes>' }))!;
    expect(n.reminder).toBeDefined();
    expect(n.reminderDone).toBe(true);
    const last = lines(evernoteBody(n, 'Call', new ImportTags()).body).at(-1)!;
    expect(last).toBe(evernoteReminderToken(n.reminder!, true));
    expect(last).toMatch(/^@remind\(\d{4}-\d{2}-\d{2} \d{2}:\d{2} done\)$/);
  });

  it('reads Evernote dates and names files', () => {
    expect(enexDate('20240102T030405Z')?.toISOString()).toBe('2024-01-02T03:04:05.000Z');
    expect(enexDate('2024-01-02')).toBeUndefined();
    expect(evernoteFileName({ mime: 'image/jpeg' }, 3)).toBe('image-3.jpeg');
    expect(evernoteFileName({ mime: 'application/x-unknown' }, 2)).toBe('attachment-2');
    expect(evernoteFileName({ mime: 'text/plain', fileName: 'a/b:c' }, 1)).toBe('a-b-c.txt');
    expect(evernoteFileName({ mime: 'image/png', fileName: '.hidden' }, 1)).toBe('image-1.png');
    expect(md5Hex(new TextEncoder().encode(''))).toBe('d41d8cd98f00b204e9800998ecf8427e');
    expect(md5Hex(new TextEncoder().encode('The quick brown fox jumps over the lazy dog'))).toBe('9e107d9d372bb6826bd81d3542a419d6');
  });

  it('converts HTML structure: headings, lists with numbers, code and inline marks', () => {
    const n = parseEnexNote(note('Doc', '<h2>Part</h2><ol><li>one</li><li>two<ul><li>sub</li></ul></li><li>three</li></ol><pre>let a = 1\nlet b = 2</pre><div>Some <b>bold</b>, <i>it</i>, <u>u</u>, <s>s</s> and <code>x()</code></div>'))!;
    const { body } = evernoteBody(n, 'Doc', new ImportTags());
    expect(body.doc.content.map((b) => b.type)).toEqual(['heading', 'heading', 'listItem', 'listItem', 'listItem', 'listItem', 'codeBlock', 'codeBlock', 'paragraph']);
    expect(body.doc.content[1]).toMatchObject({ attrs: { level: 2 } });
    expect(body.doc.content.slice(2, 6).map((b) => (b as { attrs: unknown }).attrs)).toEqual([
      { kind: 'ordered', level: 0, number: 1 },
      { kind: 'ordered', level: 0, number: 2 },
      { kind: 'bullet', level: 1 },
      { kind: 'ordered', level: 0, number: 3 },
    ]);
    expect(lines(body).slice(6, 8)).toEqual(['let a = 1', 'let b = 2']);
    const last = body.doc.content[8] as { content: Inline[] };
    expect(last.content.filter((x) => x.type === 'text' && x.marks).map((x) => [(x as { text: string }).text, (x as { marks: { type: string }[] }).marks.map((m) => m.type)])).toEqual([
      ['bold', ['bold']],
      ['it', ['italic']],
      ['u', ['underline']],
      ['s', ['strike']],
      ['x()', ['code']],
    ]);
  });
});

describe('Notion import (native NotionImporter)', () => {
  const projectsID = '0123456789abcdef0123456789abcdef';
  const roadmapID = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const tasksID = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const looseID = 'dddddddddddddddddddddddddddddddd';
  const projects = `Projects ${projectsID}`;
  const enc = `Projects%20${projectsID}`;
  const files: Record<string, string | Uint8Array> = {
    [`Export-1234/${projects}.md`]: `# Projects\n\nSee [Roadmap](${enc}/Roadmap%20${roadmapID}.md) and [Tasks](${enc}/Tasks%20${tasksID}.csv).\n\n<aside>\n💡 Keep it short.\n</aside>\n\n![Diagram](${enc}/Diagram%201.png)\n\n![Gone](${enc}/missing.png)`,
    [`Export-1234/${projects}/Roadmap ${roadmapID}.md`]: `Next steps live here. Back to [Projects](../Projects%20${projectsID}.md), and [Elsewhere](../../Elsewhere%20cccccccccccccccccccccccccccccccc.md).`,
    [`Export-1234/${projects}/Tasks ${tasksID}.csv`]: 'Name,Status\nWrite,Done\n',
    [`Export-1234/${projects}/Tasks ${tasksID}_all.csv`]: 'Name,Status,Notes\nWrite,Done,"Short, sweet"\nShip,Open,"Line one\nLine two"\n',
    [`Export-1234/${projects}/Diagram 1.png`]: PNG,
    [`Export-1234/Loose ${looseID}.md`]: '# Loose\nOn its own.',
  };

  function importAll() {
    const { pages } = notionPages(Object.keys(files).map((path) => ({ path, root: 0 })));
    const ids = new Map(pages.map((p, i) => [p.key, `00000000-0000-0000-0000-00000000000${i}`]));
    const bodies = new Map<string, { body: BodyContainer; missing: number }>();
    for (const p of pages) {
      const raw = files[p.path] as string;
      if (p.isTable) bodies.set(p.title, { body: notionTableBody(raw, p.title)!.body, missing: 0 });
      else {
        const dir = p.path.split('/').slice(0, -1);
        const r = notionPageBody(raw, p, { ids, read: (rel) => files[[...dir, ...rel.split('/')].join('/')] as Uint8Array | undefined });
        bodies.set(p.title, { body: r.body, missing: r.missingAttachments });
      }
    }
    return { pages, ids, bodies };
  }

  it('makes notebooks, notes and links from an export', () => {
    const { pages, ids, bodies } = importAll();
    expect(pages.map((p) => [p.title, p.notebook])).toEqual([
      ['Loose', 'Notion'],
      ['Projects', 'Projects'],
      ['Roadmap', 'Projects'],
      ['Tasks', 'Projects'],
    ]);
    const id = (t: string) => ids.get(pages.find((p) => p.title === t)!.key)!;
    const p = bodies.get('Projects')!;
    expect(linksIn(p.body)).toEqual([`noteit://note/${id('Roadmap')}`, `noteit://note/${id('Tasks')}`]);
    expect(lines(p.body).join('\n')).toContain('💡 Keep it short.');
    expect(lines(p.body).join('\n')).not.toContain('aside');
    expect(p.body.doc.content.some((b) => b.type === 'blockquote')).toBe(true);
    expect(walkInlines(p.body).filter((x) => x.type === 'image')).toHaveLength(1);
    expect(p.missing).toBe(1);
    const roadmap = bodies.get('Roadmap')!.body;
    expect(lines(roadmap).slice(0, 2).join('\n')).toMatch(/^Roadmap\nNext steps/);
    expect(linksIn(roadmap)).toEqual([`noteit://note/${id('Projects')}`, 'noteit://note?title=Elsewhere']);
    const table = bodies.get('Tasks')!.body;
    expect(lines(table)[0]).toBe('Tasks');
    const t = table.doc.content[1] as Extract<Block, { type: 'table' }>;
    expect(t.content.flatMap((r) => r.content.map((c) => textOf(c.content[0]!.content)))).toEqual(['Name', 'Status', 'Notes', 'Write', 'Done', 'Short, sweet', 'Ship', 'Open', 'Line one Line two']);
    expect(pages.some((x) => x.title.includes(projectsID) || x.title.includes(tasksID))).toBe(false);
    for (const b of bodies.values()) expect(validateContainer(b.body)).toBe('valid');
  });

  it('refuses an HTML export', () => {
    expect(notionPages([{ path: 'Export/Page abc.html', root: 0 }])).toEqual({ pages: [], sawHTML: true });
  });

  it('keeps remote images as links', () => {
    const r = notionPageBody(`# Web\n![Chart](https://example.com/chart.png)\n\n![](<https://example.com/a b.png> "Caption")`, { key: 'Web', title: 'Web' }, { ids: new Map(), read: () => undefined });
    expect(r.missingAttachments).toBe(0);
    const found = Object.fromEntries(walkInlines(r.body).flatMap((n) => (n.type === 'text' ? (n.marks ?? []).flatMap((m) => (m.type === 'link' ? [[m.attrs.href, n.text]] : [])) : [])));
    expect(found['https://example.com/chart.png']).toBe('Chart');
    expect(found['https://example.com/a%20b.png']).toBe('https://example.com/a b.png');
  });

  it('leaves images in code alone', () => {
    const text = [
      '![Out](https://example.com/a.png) and `![Span](https://example.com/b.png)` and ``![Two](https://x.io/c.png)``',
      '```',
      '![Fenced](https://example.com/d.png)',
      '```',
      '~~~swift',
      'let s = "![Tilde](https://example.com/e.png)"',
      '~~~',
      '  ```',
      '  ![Indented fence](https://example.com/f.png)',
      '  ```',
      '![After](https://example.com/g.png)',
    ].join('\n');
    const out = notionRemoteImagesAsLinks(text);
    expect(out.startsWith('[Out](https://example.com/a.png) and `![Span]')).toBe(true);
    expect(out).toContain('``![Two](https://x.io/c.png)``');
    expect(out).toContain('\n![Fenced](https://example.com/d.png)\n');
    expect(out).toContain('"![Tilde](https://example.com/e.png)"');
    expect(out).toContain('  ![Indented fence](https://example.com/f.png)');
    expect(out.endsWith('\n[After](https://example.com/g.png)')).toBe(true);
  });

  it('never rewrites code', () => {
    const fenced = '```\n[T](Tasks%20abc.csv) ![I](https://example.com/i.png)\n<aside>\nnot a callout\n</aside>\n```';
    expect(notionPrepared(fenced)).toBe(fenced);
    expect(notionPrepared('~~~\n[T](a_all.csv)\n~~~')).toBe('~~~\n[T](a_all.csv)\n~~~');
    expect(notionPrepared('See `[T](Tasks.csv)` or [T](Tasks.csv)')).toBe('See `[T](Tasks.csv)` or [T](Tasks.md)');
    expect(notionPrepared('<aside>\n```\n[T](Tasks.csv)\n```\n</aside>\n[T](Tasks.csv)')).toBe('> ```\n> [T](Tasks.csv)\n> ```\n[T](Tasks.md)');
  });

  it('closes a code block only with a matching fence', () => {
    expect(notionPrepared('```\n> ```\n[a](x.csv)\n    ```\n[b](y.csv)\n```\n[c](z.csv)')).toBe('```\n> ```\n[a](x.csv)\n    ```\n[b](y.csv)\n```\n[c](z.md)');
    expect(notionPrepared('> ```\n> > ```\n> [a](x.csv)\n>     ```\n> [b](y.csv)\n> ```\n[c](z.csv)')).toBe('> ```\n> > ```\n> [a](x.csv)\n>     ```\n> [b](y.csv)\n> ```\n[c](z.md)');
    expect(notionOutsideCode('````\n```\n[a](x.csv)\n````\n[b](y.csv)', (s) => s.replaceAll('.csv', '.md'))).toBe('````\n```\n[a](x.csv)\n````\n[b](y.md)');
  });

  it('reads names', () => {
    expect(notionStripID(`Plan ${projectsID}`).title).toBe('Plan');
    expect(notionStripID(`Plan ${projectsID.toUpperCase()}`).id).toBe(projectsID);
    expect(notionStripID('Plan 1234').title).toBe('Plan 1234');
    expect(notionTitleOfFile(`Tasks ${tasksID}_all.csv`)).toBe('Tasks');
    expect(notionTitleOfFile(` ${tasksID}.md`)).toBe('Untitled');
    expect(notionTitleOfStem(`v1.2 notes ${tasksID}`)).toBe('v1.2 notes');
  });

  it('reads CSV', () => {
    const table = readNotionCSV('﻿A,B\n"x ""q""","1,2"\n\nlast,\n', 10);
    expect(table.header).toEqual(['A', 'B']);
    expect(table.rows).toEqual([['x "q"', '1,2'], ['last', '']]);
    expect(table.truncated).toBe(false);
    const cut = readNotionCSV('A\n1\n2\n3', 2);
    expect(cut.rows).toEqual([['1'], ['2']]);
    expect(cut.truncated).toBe(true);
  });

  it('gives same-titled top pages their own notebook keys', () => {
    const { pages } = notionPages([
      { path: `Plan ${projectsID}.md`, root: 0 },
      { path: `Plan ${projectsID}/Child ${roadmapID}.md`, root: 0 },
      { path: `Plan ${tasksID}.md`, root: 1 },
      { path: `Plan ${tasksID}/Other ${looseID}.md`, root: 1 },
    ]);
    expect(new Set(pages.map((p) => p.notebookKey)).size).toBe(2);
    expect(pages.every((p) => p.notebook === 'Plan')).toBe(true);
  });
});

describe('ZIP archives and TextBundle', () => {
  it('unzips, leaving out unsafe names and charging the limits', () => {
    const zip = zipSync({ 'a/text.md': strToU8('# Hi'), 'a/assets/x.png': PNG, '__MACOSX/a/._x': strToU8('junk') });
    const limits = standardZipLimits();
    const files = unzipArchive(zip, 'a.zip', limits);
    expect([...files.keys()].sort()).toEqual(['a/assets/x.png', 'a/text.md']);
    expect(limits.maxEntries).toBe(200_000 - 3);
    expect(() => unzipArchive(zip, 'a.zip', { maxEntries: 1, maxBytes: 1e9 })).toThrow(ZipTooLargeError);
    expect(() => unzipArchive(zip, 'a.zip', { maxEntries: 100, maxBytes: 10 })).toThrow(ZipTooLargeError);
  });

  it('finds the bundle and its text', () => {
    expect(textPackBundle(['text.md', 'assets/a.png'])).toBe('');
    expect(textPackBundle(['Note.textbundle/text.md', 'Note.textbundle/info.json'])).toBe('Note.textbundle/');
    expect(textPackBundle(['wrap/Note.textbundle/text.markdown'])).toBe('wrap/Note.textbundle/');
    expect(textPackBundle(['a/x.md', 'b/y.md'])).toBeUndefined();
    expect(textBundleTextPath(['info.json', 'text.markdown', 'assets/a.png'])).toBe('text.markdown');
    expect(textBundleTextPath(['info.json', 'other.md'])).toBe('other.md');
  });

  it("reads Bear's dates from info.json", () => {
    const d = textBundleDates(JSON.stringify({ 'net.shinyfrog.bear': { creationDate: '2023-04-05T06:07:08Z', modificationDate: '2023-05-06T07:08:09Z' } }));
    expect(d.created?.toISOString()).toBe('2023-04-05T06:07:08.000Z');
    expect(d.modified?.toISOString()).toBe('2023-05-06T07:08:09.000Z');
    expect(textBundleDates('not json')).toEqual({});
  });
});
