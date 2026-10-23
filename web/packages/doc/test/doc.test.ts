import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getSchema } from '@tiptap/core';
import { Node as PMNode } from '@tiptap/pm/model';
import { describe, expect, it } from 'vitest';
import {
  addAttachment,
  decodeBody,
  deriveTags,
  deriveTitleAndPreview,
  emptyContainer,
  encodeBody,
  matchesSearch,
  type NoteItDoc,
  noteLink,
  parseNoteLink,
  plainLines,
  pruneAttachments,
  searchFold,
  sha256HexSync,
  validateContainer,
  withConflictSuffix,
  conflictTitleSuffix,
} from '../src/index.js';
import { fromEditorJSON, noteItExtensions, toEditorJSON } from '../src/tiptap/index.js';

const golden = (name: string) =>
  JSON.parse(readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../../../../fixtures/golden', name), 'utf8')) as { cases: Record<string, unknown>[] };

describe('doc-validate vectors', () => {
  for (const c of golden('doc-validate.json').cases) {
    it(String(c.name), () => {
      const got = validateContainer(c.container);
      if (c.expect === 'valid') expect(got).toBe('valid');
      else expect(got).toEqual(c.expect);
    });
  }
});

const t = (text: string, marks?: { type: string; attrs?: Record<string, unknown> }[]) => ({ type: 'text', text, ...(marks ? { marks } : {}) });
const p = (...content: unknown[]) => ({ type: 'paragraph', content });

const sample: NoteItDoc = {
  type: 'doc',
  content: [
    { type: 'paragraph' },
    { type: 'heading', attrs: { level: 1 }, content: [t('  Trip\tplan '), { type: 'image', attrs: { sha: 'a', name: 'x.png', mime: 'image/png' } }] },
    { type: 'listItem', attrs: { kind: 'bullet', level: 0 }, content: [t('Pack #Gear and #gear/boots')] },
    { type: 'listItem', attrs: { kind: 'bullet', level: 1 }, content: [t('Socks')] },
    { type: 'listItem', attrs: { kind: 'ordered', level: 0, number: 3 }, content: [t('Third')] },
    { type: 'listItem', attrs: { kind: 'task', level: 0, checked: true }, content: [t('Done')] },
    { type: 'codeBlock', content: [t('#notatag x = 1')] },
    p(t('see '), t('#linked', [{ type: 'link', attrs: { href: 'https://e.com' } }]), t(' and '), t('#code', [{ type: 'code' }]), t(' (#Café)')),
    { type: 'horizontalRule' },
    {
      type: 'table',
      content: [
        { type: 'tableRow', content: [{ type: 'tableHeader', content: [p(t('Name'))] }, { type: 'tableHeader', content: [p(t('Qty'))] }] },
        { type: 'tableRow', content: [{ type: 'tableCell', content: [p(t('Tea'))] }, { type: 'tableCell', content: [p(t('2'))] }] },
        { type: 'tableRow', content: [{ type: 'tableCell', content: [p(t('Milk'))] }, { type: 'tableCell', content: [{ type: 'paragraph' }] }] },
      ],
    },
    { type: 'blockquote', content: [p(t('Quoted'))] },
  ],
} as unknown as NoteItDoc;

describe('derivations (spec §2.8)', () => {
  it('produces native lines: markers, cleaning, tables collapsed without the header', () => {
    expect(plainLines(sample)).toEqual([
      '',
      'Trip plan',
      '• Pack #Gear and #gear/boots',
      '◦ Socks',
      '3. Third',
      '☑ Done',
      '#notatag x = 1',
      'see #linked and #code (#Café)',
      '',
      'Tea · 2  Milk',
      'Quoted',
    ]);
  });

  it('derives title and preview', () => {
    const { title, preview } = deriveTitleAndPreview(sample);
    expect(title).toBe('Trip plan');
    expect(preview.startsWith('• Pack #Gear and #gear/boots ◦ Socks 3. Third')).toBe(true);
    expect([...new Intl.Segmenter().segment(preview)].length).toBeLessThanOrEqual(140);
  });

  it('truncates by grapheme', () => {
    const doc = { type: 'doc', content: [p(t('👍🏽'.repeat(130)))] } as unknown as NoteItDoc;
    expect(deriveTitleAndPreview(doc).title).toBe('👍🏽'.repeat(120));
  });

  it('derives tags, masking code and links, lowercased and de-duplicated', () => {
    expect(deriveTags(sample)).toEqual(['gear', 'gear/boots', 'café']);
  });

  it('ignores # inside words and URLs', () => {
    expect(deriveTags({ type: 'doc', content: [p(t('a#b site.com/#x ?q=#y "#ok" ,#two'))] } as unknown as NoteItDoc)).toEqual(['ok', 'two']);
  });

  it('suffixes the first line for conflict copies', () => {
    const suffix = conflictTitleSuffix('Mac', new Date('2026-01-02T03:04:00Z'), 'en-US');
    expect(suffix).toMatch(/^ \(conflict — Mac, .+\)$/);
    expect(deriveTitleAndPreview(withConflictSuffix(sample, ' (conflict — X)')).title).toBe('Trip plan  (conflict — X)'); // native inserts after the line's trailing space
    const blank = withConflictSuffix({ type: 'doc', content: [{ type: 'paragraph' }] } as NoteItDoc, ' (c)');
    expect(deriveTitleAndPreview(blank).title).toBe('Untitled (c)');
  });
});

describe('search fold', () => {
  it('is case, diacritic and width insensitive and needs every term', () => {
    expect(searchFold('Café ＡＢＣ')).toBe('cafe abc');
    expect(matchesSearch('Trip to Malmö', 'malmo trip')).toBe(true);
    expect(matchesSearch('Trip to Malmö', 'malmo plane')).toBe(false);
  });
});

describe('body container', () => {
  it('round-trips, keeps unknown keys and dispatches by bodyFormat', () => {
    const c = { ...emptyContainer(), futureKey: { a: 1 }, frontMatter: 'title: x' };
    const sha = addAttachment(c, new TextEncoder().encode('hi'), 'hi.txt', 'text/plain');
    expect(sha).toBe(sha256HexSync(new TextEncoder().encode('hi')));
    const decoded = decodeBody(encodeBody(c), 'noteit-doc/1');
    expect(decoded.kind).toBe('doc');
    if (decoded.kind === 'doc') {
      expect(decoded.container.futureKey).toEqual({ a: 1 });
      expect(decoded.validation).toBe('valid');
      pruneAttachments(decoded.container);
      expect(decoded.container.attachments).toEqual({});
    }
    expect(decodeBody(new TextEncoder().encode('rtfd\0\0\0\0xx'), 'noteit-doc/1').kind).toBe('legacyRtfd');
    expect(decodeBody(new Uint8Array([1]), undefined).kind).toBe('legacyRtfd');
    expect(decodeBody(new Uint8Array([1]), 'noteit-locked/1').kind).toBe('locked');
    expect(decodeBody(new TextEncoder().encode('{'), 'noteit-doc/1').kind).toBe('invalid');
  });

  it('sha256 matches known vectors', () => {
    expect(sha256HexSync(new Uint8Array())).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(sha256HexSync(new TextEncoder().encode('abc'))).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(sha256HexSync(new Uint8Array(1000).fill(97))).toBe('41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3');
  });
});

describe('note links', () => {
  it('parses and builds', () => {
    const id = '8F14E45F-CEEA-467A-9575-5E4F0C6B7A21';
    expect(parseNoteLink(noteLink(id.toLowerCase()))).toEqual({ id });
    expect(parseNoteLink(`noteit://note/${id}?heading=Intro`)).toEqual({ id, heading: 'Intro' });
    expect(parseNoteLink('noteit://note?title=Plan')).toEqual({ title: 'Plan' });
    expect(parseNoteLink('https://x')).toBeUndefined();
  });
});

describe('TipTap schema covers every node and mark', () => {
  const schema = getSchema(noteItExtensions());
  it('parses every node type and round-trips through editor JSON', () => {
    const everything = {
      type: 'doc',
      content: [
        ...sample.content,
        { type: 'paragraph', attrs: { align: 'center', indent: 2 }, content: [t('x', [{ type: 'bold' }, { type: 'italic' }, { type: 'underline' }, { type: 'strike' }, { type: 'textColor', attrs: { color: '#FF0000' } }, { type: 'highlight', attrs: { color: '#FFFF00' } }, { type: 'fontSize', attrs: { delta: 4 } }]), { type: 'hardBreak' }, { type: 'attachment', attrs: { sha: 'b', name: 'f.pdf', mime: 'application/pdf' } }] },
        { type: 'codeBlock', attrs: { language: 'swift', align: 'right' }, content: [t('let x', [{ type: 'bold' }])] },
        { type: 'table', attrs: { columnWidths: [40, 60] }, content: [{ type: 'tableRow', content: [{ type: 'tableCell', content: [p(t('a'))] }, { type: 'tableCell', content: [p(t('b'))] }] }] },
      ],
    };
    const node = PMNode.fromJSON(schema, toEditorJSON(everything as unknown as NoteItDoc));
    node.check();
    expect(fromEditorJSON(node.toJSON())).toEqual(everything);
    expect(validateContainer({ ...emptyContainer(), doc: fromEditorJSON(node.toJSON()) })).toBe('valid');
  });

  it('refuses the inline code mark inside code blocks', () => {
    const doc = { type: 'doc', content: [{ type: 'codeBlock', content: [t('x', [{ type: 'code' }])] }] };
    expect(() => PMNode.fromJSON(schema, doc).check()).toThrow();
  });
});
