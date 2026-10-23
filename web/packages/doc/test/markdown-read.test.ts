/** The Markdown reader against the Swift codec's fixtures and the Swift reader and paste tests. */
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  type Block,
  InvalidFrontMatterError,
  docToMarkdown,
  frontMatterLineCount,
  looksLikeMarkdown,
  markdownForPaste,
  markdownToDoc,
  parseMarkdown,
  readFrontMatter,
  resolveMarkdownAttachments,
  sha256HexSync,
} from '../src/index.js';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
const fixtures = resolve(repo, 'Tests/NoteItMarkdownTests/Fixtures');

const PLAN = '8F14E45F-CEEA-467A-9575-5E4F0C6B7A21';
const WORK_PLAN = '1C2B3A49-5D6E-4F70-8192-A3B4C5D6E7F8';
/** `MarkdownFixture.resolveNoteLink`: the wiki-link table the fixtures are written against. */
const resolveNoteLink = (target: string) => ({ Plan: PLAN, 'Work/Plan': WORK_PLAN })[target];

const t = (text: string, marks?: unknown[]) => (marks ? { type: 'text', text, marks } : { type: 'text', text });
const p = (...content: unknown[]) => (content.length ? { type: 'paragraph', content } : { type: 'paragraph' });
const HARD = { type: 'hardBreak' };
const SOFT = { type: 'hardBreak', attrs: { soft: true } };
const linkTo = (href: string) => ({ type: 'link', attrs: { href } });
const blocks = (md: string, resolve?: (t: string) => string | undefined) => markdownToDoc(md, { resolveNoteLink: resolve }).content;
const inlines = (md: string) => (blocks(md)[0] as { content?: unknown[] }).content;

function fixturePairs(folder: string): string[] {
  return readdirSync(folder)
    .filter((n) => n.endsWith('.md'))
    .map((n) => n.slice(0, -3))
    .sort();
}

/** As CodecGoldenTests.testParse and ForeignMarkdownTests.testForeignFilesParse: the parsed body equals the JSON. */
describe('Markdown reader matches the Swift codec fixtures', () => {
  for (const [label, folder] of [
    ['', fixtures],
    ['foreign/', resolve(fixtures, 'foreign')],
  ] as const) {
    const names = fixturePairs(folder);
    it(`has ${label || 'top-level '}fixtures`, () => expect(names.length).toBeGreaterThan(label ? 4 : 30));
    for (const name of names) {
      it(label + name, () => {
        const parsed = parseMarkdown(readFileSync(resolve(folder, `${name}.md`), 'utf8'), { resolveNoteLink });
        expect(parsed.body).toEqual(JSON.parse(readFileSync(resolve(folder, `${name}.json`), 'utf8')));
      });
    }
  }
});

describe('foreign Markdown (ForeignMarkdownTests)', () => {
  it('keeps Obsidian front matter keys and reads tags', () => {
    const parsed = parseMarkdown(readFileSync(resolve(fixtures, 'foreign/obsidian.md'), 'utf8'));
    expect(parsed.frontMatter.tags).toEqual(['work']);
    expect(parsed.frontMatter.id).toBeUndefined();
    expect(parsed.attachmentRefs).toEqual([{ path: 'diagram.png', displayName: 'diagram.png' }]);
  });
  it('ignores a byte order mark', () => {
    expect(blocks('\uFEFF# Title\n')).toEqual([{ type: 'heading', attrs: { level: 1 }, content: [t('Title')] }]);
  });
  it('keeps other HTML and unsafe links as text', () => {
    expect(blocks('<div>x</div> [run](javascript:alert(1))\n')).toEqual([p(t('<div>x</div> run'))]);
  });
});

describe('codec (CodecGoldenTests)', () => {
  it('lists attachment refs in document order without duplicates', () => {
    const parsed = parseMarkdown('![b.png|300](_attachments/b.png) [a.pdf](_attachments/a%20b.pdf)\n\n![b.png|300](_attachments/b.png)\n');
    expect(parsed.attachmentRefs).toEqual([
      { path: '_attachments/b.png', displayName: 'b.png', width: 300 },
      { path: '_attachments/a b.pdf', displayName: 'a.pdf' },
    ]);
  });
  it('reads fenced code blocks', () => {
    expect(blocks('```swift\na\n\nb\n```\n')).toEqual([
      { type: 'codeBlock', attrs: { language: 'swift' }, content: [t('a')] },
      { type: 'codeBlock', attrs: { language: 'swift' } },
      { type: 'codeBlock', attrs: { language: 'swift' }, content: [t('b')] },
    ]);
    expect(blocks('```\n```\n')).toEqual([{ type: 'codeBlock' }]);
  });
});

describe('line breaks (LineBreakTests)', () => {
  it('reads a hard-wrapped paragraph with soft breaks', () => {
    expect(blocks('Intro.\n\nOne two three\nfour five six\nseven eight\n')[1]).toEqual(p(t('One two three'), SOFT, t('four five six'), SOFT, t('seven eight')));
  });
  it('keeps a backslash and two spaces hard', () => {
    expect(inlines('a  \nb\\\nc\nd\n')).toEqual([t('a'), HARD, t('b'), HARD, t('c'), SOFT, t('d')]);
    expect(inlines('- a  \n  b\n  c\n')).toEqual([t('a'), HARD, t('b'), SOFT, t('c')]);
  });
  it('makes setext heading breaks hard', () => {
    expect(inlines('a\nb\n===\n')).toEqual([t('a'), HARD, t('b')]);
  });
});

describe('wiki links (WikiLinkSyntaxTests)', () => {
  const planHref = `noteit://note/${PLAN}`;
  it('reads raw wiki links with shown text', () => {
    expect(blocks('See [[Plan|the *best* plan_now]]\n', resolveNoteLink)).toEqual([p(t('See '), t('the *best* plan_now', [linkTo(planHref)]))]);
    expect(blocks('See [[Plan#Intro|Intro]]\n', resolveNoteLink)).toEqual([p(t('See '), t('Intro', [linkTo(`${planHref}?heading=Intro`)]))]);
  });
  it('leaves an unresolved target as a title link', () => {
    expect(blocks('See [[Other note#Part 2]]\n')).toEqual([p(t('See '), t('Other note', [linkTo('noteit://note?title=Other%20note&heading=Part%202')]))]);
  });
  it('reads the escaped pipe in a table cell', () => {
    const cell = (content: unknown[]) => ({ type: 'tableCell', content: [p(...content)] });
    expect(blocks('|  |  |\n| --- | --- |\n| [[Plan\\|shown]] | b |\n', resolveNoteLink)).toEqual([
      { type: 'table', content: [{ type: 'tableRow', content: [cell([t('shown', [linkTo(planHref)])]), cell([t('b')])] }] },
    ]);
  });
  it('resolves a missing name by title', () => {
    const id = '0F4A6B1C-2D3E-4F50-8192-A3B4C5D6E7F8';
    expect(blocks('See [[Some Note]]\n', (target) => (target === 'Some Note' ? id : undefined))).toEqual([p(t('See '), t('Some Note', [linkTo(`noteit://note/${id}`)]))]);
  });
  it('reads Markdown links to notes and to .md files', () => {
    const other = 'AB000000-0000-4000-8000-000000000001';
    expect(blocks(`See [[Plan]] and [Plan](noteit://note/${other})\n`, resolveNoteLink)).toEqual([
      p(t('See '), t('Plan', [linkTo(planHref)]), t(' and '), t('Plan', [linkTo(`noteit://note/${other}`)])),
    ]);
    expect(blocks('[x](./Work/Plan.md#Intro) [y](Some%20Note.markdown)\n', resolveNoteLink)).toEqual([
      p(t('x', [linkTo(`noteit://note/${WORK_PLAN}?heading=Intro`)]), t(' '), t('y', [linkTo('noteit://note?title=Some%20Note')])),
    ]);
  });
  it('keeps long targets in full', () => {
    const long = 'x'.repeat(130);
    expect(blocks(`[[${long}]]\n`)).toEqual([p(t(long, [linkTo(`noteit://note?title=${long}`)]))]);
  });
});

describe('escaping (EscapingTests)', () => {
  // The EscapingTests texts the web writer escapes as the Swift writer does. It doesn't yet escape `_`, `~~`,
  // entities, `[…](…)`, `![…](…)`, bare URLs, `---` or `___`, so those are read from hand-escaped Markdown below.
  const texts = [
    '*not italic*', 'snake_case_name', '**not bold**', '==not highlighted==', 'a = b == c', '`not code`', '<u>not underlined</u>',
    '<mark>x</mark> <br>', 'back\\slash\\', '\\*', '[[not a link]]', 'a]b[c', '<https://example.com>', 'end!', '1 * 2 * 3', '50% off (today)',
    '# not a heading', '#hashtag', '- not a list', '+ not a list', '1. not a list', '12) not a list', '> not a quote', '***', '===',
    '```', '~~~',
  ];
  it('reads escaped syntax as text', () => {
    expect(inlines('\\_not italic\\_ \\~\\~not struck\\~\\~ &amp;amp; &#38;#10; \\[text\\](x) \\![alt\\](x.png) https\\://example.com\n')).toEqual([
      t('_not italic_ ~~not struck~~ &amp; &#10; [text](x) ![alt](x.png) https://example.com'),
    ]);
    expect(blocks('\\---\n\n\\___\n')).toEqual([p(t('---')), p(t('___'))]);
  });
  it('reads written text back as the same text', () => {
    for (const text of texts) {
      const doc = { type: 'doc' as const, content: [{ type: 'paragraph' as const, content: [{ type: 'text' as const, text }] }] };
      expect(markdownToDoc(docToMarkdown(doc)), text).toEqual(doc);
    }
  });
  it('reads marks back', () => {
    expect(inlines('**bold** and ***both***\n')).toEqual([t('bold', [{ type: 'bold' }]), t(' and '), t('both', [{ type: 'bold' }, { type: 'italic' }])]);
    expect(inlines('<u>u</u> ==h== <mark style="background-color: #abc">m</mark> <span style="color: #2899E0" data-size="+2">s</span>\n')).toEqual([
      t('u', [{ type: 'underline' }]), t(' '), t('h', [{ type: 'highlight', attrs: { color: '#FFED8C' } }]), t(' '),
      t('m', [{ type: 'highlight', attrs: { color: '#AABBCC' } }]), t(' '),
      t('s', [{ type: 'textColor', attrs: { color: '#2899E0' } }, { type: 'fontSize', attrs: { delta: 2 } }]),
    ]);
  });
});

describe('unknown blocks (UnknownBlockTests)', () => {
  const unknown = { attrs: { src: 'graph TD' }, type: 'mermaid' };
  const encode = (node: unknown) => btoa(JSON.stringify(node)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  it('keeps an unknown block from its comment', () => {
    expect(blocks(`after\n\n<!-- noteit: doc=${encode(unknown)} -->\n\nafter\n`)).toEqual([p(t('after')), unknown, p(t('after'))]);
  });
  it('keeps a known block holding an unknown inline verbatim', () => {
    const node = { type: 'paragraph', content: [{ type: 'sticker', attrs: { id: 1 } }] };
    expect(blocks(`<!-- noteit: doc=${encode(node)} -->\n`)).toEqual([node]);
  });
});

describe('hostile input (HostileInputTests)', () => {
  const quick = (text: string, label: string) => {
    const start = Date.now();
    expect(() => parseMarkdown(text), label).not.toThrow();
    expect(Date.now() - start, label).toBeLessThan(process.env.CI ? 10_000 : 3_000);
  };
  const repeated = (unit: string, length = 300_000) => unit.repeat(Math.floor(length / unit.length));

  it('parses deep quote nesting', () => {
    quick(`${'>'.repeat(100_000)} x\n`, 'one line of >');
    quick(`${'>'.repeat(1000)}\n`.repeat(100), 'many lines of >');
    expect(blocks(`${'> '.repeat(40)}x\n`)[0]!.type).toBe('blockquote');
  });
  it('parses deep list nesting', () => {
    quick(Array.from({ length: 500 }, (_, k) => `${'  '.repeat(k)}- item\n`).join(''), 'nested bullets');
    quick(Array.from({ length: 500 }, (_, k) => `${' '.repeat(k * 3)}${k % 2 === 0 ? '1. ' : '> - '}x\n`).join(''), 'nested lists and quotes');
  });
  it('scans unmatched emphasis in linear time', () => {
    quick(repeated('*a ', 150_000) + repeated('a_ ', 150_000), '*a then a_');
    quick(repeated('_a ', 150_000) + repeated('a* ', 150_000), '_a then a*');
    quick(repeated('~a ', 150_000) + repeated('a~~ ', 150_000), '~ of other lengths');
    quick(repeated('*a _', 150_000) + repeated('b_ c*', 150_000), 'nested pairs');
  });
  it('scans unclosed links in linear time', () => {
    quick(repeated('[a]('), '[a](');
    quick(repeated('[a](((('), 'open parens');
    quick(repeated('[a](b (t'), 'paren titles');
    quick(repeated('[a](x) ['), 'links after open brackets');
    quick(repeated('![', 100_000) + repeated('](x)', 200_000), 'nested images');
    quick(repeated('[!', 100_000) + repeated('](x)', 200_000), 'nested attachment links');
  });
  it('scans unclosed wiki links, tags and other runs in linear time', () => {
    quick(repeated('[['), '[[');
    quick(repeated('[[a'), '[[a');
    quick(repeated('![[a'), '![[a');
    quick(repeated('<u>', 150_000) + repeated('</b>', 150_000), 'unmatched closers');
    quick(repeated('<u><b>', 150_000) + repeated('</u>', 150_000), 'nested matches');
    quick(Array.from({ length: 700 }, (_, k) => `${'`'.repeat(k + 1)} `).join(''), 'backtick runs');
    quick(repeated('(http://a|'), 'bare URLs that fail');
    quick(`http://a${repeated(')')}`, 'bare URL with closing parens');
    quick(repeated('a*'), 'one long text run');
  });
});

describe('front matter (FrontMatterTests)', () => {
  it('reads the spec example', () => {
    const text = '---\nid: 6f1c2e9a-6b0d-4e43-9b5c-1e0f5d7b9a11\ncreated: 2026-10-19T09:12:44Z\nupdated: 2026-10-19T10:03:02Z\npinned: true\n---\n# Plan\n';
    const { frontMatter, bodyStart } = readFrontMatter(text);
    expect(frontMatter.id).toBe('6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11');
    expect(frontMatter.created?.toISOString()).toBe('2026-10-19T09:12:44.000Z');
    expect(frontMatter.updated?.toISOString()).toBe('2026-10-19T10:03:02.000Z');
    expect(frontMatter.pinned).toBe(true);
    expect(text.slice(bodyStart)).toBe('# Plan\n');
  });
  it('keeps unknown keys verbatim and in order', () => {
    const text = '---\ncssclasses: wide\nid: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\naliases:\n  - Plan for Q4\n  - "Q4: plan"\npublish: false   # keep spacing\n---\nBody\n';
    expect(readFrontMatter(text).frontMatter.extra).toBe('cssclasses: wide\naliases:\n  - Plan for Q4\n  - "Q4: plan"\npublish: false   # keep spacing');
    expect(parseMarkdown(text).body.frontMatter).toBe('cssclasses: wide\naliases:\n  - Plan for Q4\n  - "Q4: plan"\npublish: false   # keep spacing');
  });
  it('reads tags from flow and block lists', () => {
    expect(readFrontMatter('---\ntags: [a, b]\n---\n').frontMatter.tags).toEqual(['a', 'b']);
    const block = readFrontMatter('---\ntags:\n  - work\n  - "#home"\n---\n').frontMatter;
    expect(block.tags).toEqual(['work', 'home']);
    expect(block.extra).toBe('tags:\n  - work\n  - "#home"');
  });
  it('treats dashes not on line one as body', () => {
    expect(readFrontMatter('Intro\n---\nid: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\n---\n').bodyStart).toBe(0);
    expect(readFrontMatter('').bodyStart).toBe(0);
  });
  it('throws for an invalid block, with its line', () => {
    const line = (text: string) => {
      try {
        readFrontMatter(text);
      } catch (e) {
        return (e as InvalidFrontMatterError).line;
      }
      return undefined;
    };
    expect(line('---\nid: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\n')).toBe(1);
    expect(line('---\nid: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\nBody text\n')).toBe(3);
    expect(line('---\nid: not-a-uuid\n---\n')).toBe(2);
    expect(() => parseMarkdown('---\npinned: maybe\n---\n')).toThrow(InvalidFrontMatterError);
  });
  it('reads CRLF', () => {
    const text = '---\r\nid: 6F1C2E9A-6B0D-4E43-9B5C-1E0F5D7B9A11\r\naliases: x\r\npinned: true\r\n---\r\nBody\r\n';
    const { frontMatter, bodyStart } = readFrontMatter(text);
    expect([frontMatter.pinned, frontMatter.extra, text.slice(bodyStart)]).toEqual([true, 'aliases: x', 'Body\r\n']);
  });
  it('reads dates without a zone as UTC, and locked', () => {
    const fm = readFrontMatter('---\ncreated: 2026-10-19T09:12:44\nupdated: 2026-10-19\nlocked: true\n---\n').frontMatter;
    expect(fm.created?.toISOString()).toBe('2026-10-19T09:12:44.000Z');
    expect(fm.updated?.toISOString()).toBe('2026-10-19T00:00:00.000Z');
    expect([fm.locked, fm.extra]).toEqual([true, '']);
  });
});

describe('attachments (ImportOptionsTests)', () => {
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  it('resolves images into attachments keyed by SHA-256 and drops the rest', () => {
    const parsed = parseMarkdown('![Dot](img/dot%20one.png) and ![Again](img/dot%20one.png)\n\n![Gone](missing.png)\n\nBefore ![None](none.png|300) after\n');
    const imported = resolveMarkdownAttachments(parsed, (path) => (path === 'img/dot one.png' ? png : undefined));
    const sha = sha256HexSync(png);
    expect(Object.keys(imported.body.attachments)).toEqual([sha]);
    expect(imported.body.attachments[sha]!.name).toBe('Dot');
    expect(imported.body.doc.content).toEqual([
      p({ type: 'image', attrs: { sha, name: 'Dot', mime: 'image/png' } }, t(' and '), { type: 'image', attrs: { sha, name: 'Again', mime: 'image/png' } }),
      p(),
      p(t('Before  after')),
    ]);
    expect(imported.unresolvedImages.map((r) => r.path)).toEqual(['missing.png', 'none.png|300']);
  });
  it('reads wiki links with the resolver and keeps front matter', () => {
    const parsed = parseMarkdown('---\naliases: [x]\n---\nSee [[Plan]] and [[Other]]\n', { resolveNoteLink: (t) => (t === 'Plan' ? PLAN.toLowerCase() : undefined) });
    expect(parsed.frontMatter.extra).toBe('aliases: [x]');
    expect(parsed.body.doc.content).toEqual([p(t('See '), t('Plan', [linkTo(`noteit://note/${PLAN}`)]), t(' and '), t('Other', [linkTo('noteit://note?title=Other')]))]);
  });
});

/** MarkdownPasteTests (the detector), and the blocks native paste makes. */
describe('Markdown paste', () => {
  it('detects Markdown source', () => {
    for (const text of [
      '- one\n- two', '* a\n* b', '+ a\n+ b', '1. first\n2. second', '> quoted', '- [ ] task', '- [x] done', '```\ncode\n```',
      '```swift\nlet x = 1;\n```', '| a | b |\n|---|---|\n| 1 | 2 |', 'some **bold** text', '(**bold**)', 'see [the docs](https://example.com)',
      '# Groceries\n- milk\n- eggs\n', '# Title\n> quoted',
    ]) {
      expect(looksLikeMarkdown(text), text).toBe(true);
    }
  });
  it('ignores ordinary text', () => {
    for (const text of [
      'https://example.com/some_path/__init__?q=*', 'important*', '*', '2*3*4', 'Plain prose, with punctuation - and a dash.', '#hashtag and #another',
      'a**2 + b**2', 'Price: 5 * 3', 'x | y', 'Dear team,\n\nThanks for the update.\nBest', '- item', '* item', 'some *emphasis* here',
      'snake_case and _this_', '-  wide\n-  dash', '# Title', '## Notes\nSome text',
    ]) {
      expect(looksLikeMarkdown(text), text).toBe(false);
    }
  });
  it('keeps code, diffs, shell and config plain', () => {
    const python = 'class Greeter:\n    def __init__(self, name):\n        self.name = name\n\n    def greet(self):\n        return f"Hello {self.name}"';
    const diff = 'diff --git a/main.swift b/main.swift\n--- a/main.swift\n+++ b/main.swift\n@@ -1,3 +1,3 @@\n func f() {\n-    let x = 1\n+    let x = 2\n }';
    const docComment = '/**\n * Adds two numbers.\n * @param a first\n * @param b second\n */\nfunction add(a, b) {\n  return a + b;\n}';
    for (const text of [
      python, diff, '-    let x = 1\n+    let x = 2\n+    let y = **x**', docComment, '/**\n * @param x the value\n * @returns the result\n */',
      'if __name__ == "__main__":', 'call **opts**(x)', '# Notes\nimport os\nfrom x import y\nx = 1',
      '# Build output\nbuild/\n*.log\n\n# macOS\n.DS_Store\n', '# install deps\nbrew install node\nnpm ci\n',
      '# Services\nservices:\n  web:\n    image: nginx\n    ports:\n      - "80:80"\n      - "443:443"\n',
      '# Settings\n- staging\n- production\nAPI_URL=https://example.com\nDEBUG=1\nLOG_LEVEL=info\n',
      'steps:\n  - uses: actions/checkout@v4\n  - name: Build\n    run: make\n', '- name: Install\n  apt: name=nginx\n- name: Start\n  service: name=nginx state=started\n',
      'containers:\n  - name: x\n    image: y\n', 'env:\n  - name: A\n    value: b\n',
    ]) {
      expect(looksLikeMarkdown(text), text).toBe(false);
    }
    expect(markdownForPaste(python)).toBeUndefined();
  });
  it('converts everyday Markdown and YAML-looking lists', () => {
    for (const text of [
      'Attendees: Ann, Bo\n- Agenda item one\n- Agenda item two\n', '- Milk: 2 litres\n- Bread: one loaf\n- Eggs\n', '- milk: 2 litres\n- bread: one loaf\n- eggs\n',
      '- fix: login bug\n  - repro: open app\n  - cause: token expiry\n- feat: dark mode\n  - note: needs design\n', '- todo: groceries\n  - milk: 2 litres\n  - bread: one loaf\n',
      '## Install\n\nRun this in the project folder:\n\n```sh\nnpm ci\n```\n', '**Short answer:** yes, it works.\n\n1. Open the settings.\n2. Turn it on.\n\n### Why\nIt saves time.\n',
      '- [ ] milk\n- [x] eggs\n', '1. **Option A**\n   Pros: fast\n   Cons: costly\n2. **Option B**\n   Pros: cheap\n   Cons: slow\nPick A if speed matters.\n',
    ]) {
      expect(looksLikeMarkdown(text), text).toBe(true);
    }
  });
  it('finds front matter', () => {
    const body = '\n## Notes\n- a\n- b\n';
    const yes = [
      'title: x', 'tags: [a, b]', 'aliases:\n  - y', 'tags:\n- a\n- b', 'Date created: 2024-01-01', 'ämne: möte', 'Time: 10:30', 'title: Meeting\ndue date:',
      'title: x\n# comment\ndraft: true', 'params:\n  # comment\n  a: b', 'title: x\nnotes: |\n  #1 priority', 'layout: post\ndate: 2024-01-01 10:00:00 +0100\ncategories: [a]',
      'description: >\n  folded text\n  more', '"quoted key": v', '_build: x',
    ];
    const no = [
      '## Action items\nNext steps:\n- Email Ann\n- Book room', 'We agreed on three things: budget, hiring, travel.', 'See https://example.com for details', '**Note:** x',
      '1. Install: run brew\n2. Configure: edit file', '# Hugo archetype\ntitle: x', 'See https://example.com: y', 'Wait, really?: yes', 'Mr. Smith: hi', 'a) b: c',
    ];
    const rows: [string, string | undefined][] = [
      ...yes.map((y): [string, string] => [`---\n${y}\n---${body}`, `---\n${y}\n---`]),
      [`--- \ntitle: x\n...${body}`, '--- \ntitle: x\n...'],
      ['---\r\ntitle: x\r\n---\r\n## Notes\r\n- a\r\n- b\r\n', '---\ntitle: x\n---'],
      ...no.map((n): [string, undefined] => [`---\n${n}\n---${body}`, undefined]),
      [`---\ntitle: x${body}`, undefined],
      [`\n---\ntitle: x\n---${body}`, undefined],
      [` ---\ntitle: x\n---${body}`, undefined],
    ];
    const lines = (s: string) => s.replace(/\r\n/g, '\n').split('\n');
    for (const [text, frontMatter] of rows) {
      expect(frontMatterLineCount(lines(text)), text).toBe(frontMatter ? lines(frontMatter).length : 0);
      expect(looksLikeMarkdown(text), text).toBe(true);
      const pasted = markdownForPaste(text)!;
      expect(pasted.blocks.some((b) => b.type === 'heading' && JSON.stringify(b).includes('"Notes"')), text).toBe(true);
      if (frontMatter) expect(pasted.blocks.slice(0, lines(frontMatter).length).every((b) => b.type === 'paragraph'), text).toBe(true);
    }
    expect(looksLikeMarkdown('---\ntitle: Trip\n---\nJust a sentence.\n')).toBe(false);
  });
  it('keeps pathological inputs fast', () => {
    const n = 100_000;
    for (const input of [
      `${'a'.repeat(n)} `, `${'ab-'.repeat(n / 3)}(x`, '*_[(`|#'.repeat(n / 7), '**a '.repeat(n / 4), `${'['.repeat(n)}](x`, `${'|'.repeat(n)}\n|-|-x`,
      `${' '.repeat(n)}-`, `${'a:'.repeat(n / 2)}//`, '**x\n'.repeat(n / 4), '  k: v\n'.repeat(n / 7), `${' '.repeat(n)}|\n${' '.repeat(n)}-|-`,
    ]) {
      const start = Date.now();
      looksLikeMarkdown(input);
      expect(Date.now() - start, input.slice(0, 12)).toBeLessThan(500);
    }
    expect(looksLikeMarkdown('- item\n'.repeat(30_000))).toBe(false);
  });
  it('leaves a paste with a very long line as plain text', () => {
    expect(markdownForPaste(`- one\n- two\n${'*_[(`|#'.repeat(100_000 / 7)}`)).toBeUndefined();
    expect(markdownForPaste(`## Notes\n- one\n- two\n\n${'word '.repeat(800)}\n`)?.blocks[0]?.type).toBe('heading');
  });
  it('pastes blocks, with no empty paragraphs between them', () => {
    const pasted = markdownForPaste('Intro\n\n## Plan\n\n> quote\n\n- [ ] task\n- [x] done\n1. first\n2. second\n\n**bold** [a link](https://example.com)')!;
    expect(pasted.inline).toBe(false);
    expect(pasted.endsWithNewline).toBe(false);
    expect(pasted.blocks.map((b: Block) => b.type)).toEqual(['paragraph', 'heading', 'blockquote', 'listItem', 'listItem', 'listItem', 'listItem', 'paragraph']);
  });
  it('joins inline-only Markdown on one line to the current paragraph', () => {
    const pasted = markdownForPaste('some **bold** and `code`')!;
    expect(pasted.inline).toBe(true);
    expect(pasted.blocks).toEqual([p(t('some '), t('bold', [{ type: 'bold' }]), t(' and '), t('code', [{ type: 'code' }]))]);
    expect(markdownForPaste('# Big\n- item\n- more')!.inline).toBe(false);
  });
  it('keeps the text of images without loading them', () => {
    const pasted = markdownForPaste('![Diagram](images/diagram.png)\n![Logo](https://example.com/logo.png)\n\n- x\n- y\n')!;
    expect(pasted.blocks[0]).toEqual(p(t('Diagram'), SOFT, t('Logo', [linkTo('https://example.com/logo.png')])));
    expect(pasted.endsWithNewline).toBe(true);
  });
});
