import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getSchema } from '@tiptap/core';
import { Node as PMNode } from '@tiptap/pm/model';
import { describe, expect, it } from 'vitest';
import {
  BODY_FORMAT_DOC_V1,
  decodeBody,
  deriveTags,
  deriveTitleAndPreview,
  maskedText,
  type NoteItDoc,
  searchableText,
} from '../src/index.js';
import { fromEditorJSON, noteItExtensions, toEditorJSON } from '../src/tiptap/index.js';

interface DeriveCase {
  name: string;
  doc: NoteItDoc;
  title: string;
  preview: string;
  tags: string[];
  plainText: string;
  maskedText: string;
}

/** `fixtures/golden/derive.json`, written by Swift `DocDerivationTests` and checked there against the Mac's own
 *  derivation from the attributed string. */
const file = JSON.parse(
  readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../../../../fixtures/golden/derive.json'), 'utf8'),
) as { generator: string; cases: DeriveCase[] };

describe('derive.json (title, preview, tags and plain text as on the Mac)', () => {
  it('is written by Swift and has every case', () => {
    expect(file.generator).toBe('swift');
    expect(file.cases.length).toBeGreaterThanOrEqual(40);
  });

  for (const c of file.cases) {
    it(c.name, () => {
      expect(deriveTitleAndPreview(c.doc)).toEqual({ title: c.title, preview: c.preview });
      expect(deriveTags(c.doc)).toEqual(c.tags);
      expect(searchableText(c.doc)).toBe(c.plainText);
      expect(maskedText(c.doc)).toBe(c.maskedText);
    });
  }
});

interface ConvertCase {
  name: string;
  doc: NoteItDoc;
  bodyBytes: string;
  derived: { title: string; preview: string; tags: string[]; plainText: string };
}

/** `fixtures/golden/doc-convert.json`: documents as the Mac's converter writes them, written by Swift
 *  `DerivationVectorTests`. */
const convert = JSON.parse(
  readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../../../../fixtures/golden/doc-convert.json'), 'utf8'),
) as { generator: string; cases: ConvertCase[] };

describe('doc-convert.json (the Mac converter’s documents)', () => {
  const schema = getSchema(noteItExtensions());
  it('is written by Swift and has a code block with a language and a container with front matter', () => {
    expect(convert.generator).toBe('swift');
    expect(convert.cases.map((c) => c.name)).toEqual(expect.arrayContaining(['code-block-language', 'front-matter']));
  });

  for (const c of convert.cases) {
    it(c.name, () => {
      const decoded = decodeBody(Uint8Array.from(Buffer.from(c.bodyBytes, 'base64')), BODY_FORMAT_DOC_V1);
      if (decoded.kind !== 'doc') throw new Error(`${c.name}: ${decoded.kind}`);
      expect(decoded.validation).toBe('valid');
      expect(decoded.container.doc).toEqual(c.doc);
      const node = PMNode.fromJSON(schema, toEditorJSON(c.doc));
      node.check();
      expect(fromEditorJSON(node.toJSON())).toEqual(c.doc);
      expect(deriveTitleAndPreview(c.doc)).toEqual({ title: c.derived.title, preview: c.derived.preview });
      expect(deriveTags(c.doc)).toEqual(c.derived.tags);
      expect(searchableText(c.doc)).toBe(c.derived.plainText);
    });
  }

  it('keeps the front matter and the code block language', () => {
    const front = convert.cases.find((c) => c.name === 'front-matter')!;
    const decoded = decodeBody(Uint8Array.from(Buffer.from(front.bodyBytes, 'base64')), BODY_FORMAT_DOC_V1);
    expect(decoded.kind === 'doc' && decoded.container.frontMatter).toBe('aliases: [kept]\nsource: obsidian');
    const code = convert.cases.find((c) => c.name === 'code-block-language')!;
    expect(code.doc.content.filter((b) => b.type === 'codeBlock').map((b) => (b.attrs as { language?: string }).language)).toEqual(['swift', 'swift']);
  });
});
