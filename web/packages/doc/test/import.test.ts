import { describe, expect, it } from 'vitest';
import { importMarkdown } from '../src/index.js';

describe('Markdown import (native MarkdownReader.note)', () => {
  it('takes the title from front matter, the first Title line, or the file name', () => {
    const fm = importMarkdown('---\ntitle: "Trip"\ntags: [travel]\ncreated: 2026-01-02T03:04:05Z\n---\nSome **text**\n', { fallbackTitle: 'file' });
    expect(fm.title).toBe('Trip');
    expect(fm.body.doc.content?.[0]).toEqual({ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: 'Trip' }] });
    expect(fm.body.doc.content?.at(-1)).toEqual({ type: 'paragraph', content: [{ type: 'text', text: '#travel' }] });
    expect(fm.created?.toISOString()).toBe('2026-01-02T03:04:05.000Z');
    expect(importMarkdown('# Own title\n\nbody', { fallbackTitle: 'file' }).title).toBe('Own title');
    const named = importMarkdown('just text', { fallbackTitle: 'Groceries' });
    expect(named.title).toBe('Groceries');
    expect(named.body.doc.content?.[0]).toMatchObject({ type: 'heading', content: [{ text: 'Groceries' }] });
  });

  it('brings in images from the chosen files and counts the missing ones', () => {
    const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1]);
    const r = importMarkdown('# P\n\n![a](img/a.png) ![b](img/missing.png)\n', { fallbackTitle: 'P', read: (p) => (p === 'img/a.png' ? png : undefined) });
    expect(Object.keys(r.body.attachments)).toHaveLength(1);
    expect(r.missingAttachments).toBe(1);
  });

  it('reads .txt as plain lines', () => {
    expect(importMarkdown('Title here\n**not bold**', { fallbackTitle: 'x', txt: true }).body.doc.content).toEqual([
      { type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: 'Title here' }] },
      { type: 'paragraph', content: [{ type: 'text', text: '**not bold**' }] },
    ]);
  });
});
