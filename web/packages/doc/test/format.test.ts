// @vitest-environment happy-dom
import { Editor } from '@tiptap/core';
import { afterEach, describe, expect, it } from 'vitest';
import { adjustFontSize, clearFormatting, fromEditorJSON, noteItExtensions, setAlignment, steppedDelta } from '../src/tiptap/index.js';

const live: Editor[] = [];
afterEach(() => {
  for (const ed of live.splice(0)) ed.destroy();
});
const t = (text: string, marks?: unknown[]) => (marks ? { type: 'text', text, marks } : { type: 'text', text });
function editorWith(content: unknown[], from: number, to = from) {
  const ed = new Editor({ element: document.createElement('div'), extensions: noteItExtensions(), content: { type: 'doc', content } as never });
  live.push(ed);
  ed.commands.setTextSelection({ from, to });
  return ed;
}
const blocks = (ed: Editor) => fromEditorJSON(ed.getJSON()).content;

describe('Bigger and Smaller (native adjustFontSize)', () => {
  it('steps the fontSize delta a point at a time, from the block base, within 8–96 pt', () => {
    expect(steppedDelta(0, 14, 1)).toBe(1);
    expect(steppedDelta(1, 14, -1)).toBe(0);
    expect(steppedDelta(82, 14, 1)).toBe(82);
    expect(steppedDelta(-6, 14, -1)).toBe(-6);
    expect(steppedDelta(0, 26, 1)).toBe(1);
  });

  it('changes each run in the selection and removes a delta that reaches 0', () => {
    const ed = editorWith([{ type: 'paragraph', content: [t('ab'), t('cd', [{ type: 'fontSize', attrs: { delta: -1 } }])] }], 1, 5);
    adjustFontSize(ed, 1);
    expect(blocks(ed)[0]).toEqual({ type: 'paragraph', content: [t('ab', [{ type: 'fontSize', attrs: { delta: 1 } }]), t('cd')] });
  });

  it('with no selection, applies to what is typed next', () => {
    const ed = editorWith([{ type: 'paragraph', content: [t('a')] }], 2);
    adjustFontSize(ed, -1);
    adjustFontSize(ed, -1);
    ed.view.dispatch(ed.state.tr.insertText('b'));
    expect(blocks(ed)[0]).toEqual({ type: 'paragraph', content: [t('a'), t('b', [{ type: 'fontSize', attrs: { delta: -2 } }])] });
  });
});

describe('alignment and Clear Formatting', () => {
  it('sets align on every line in the selection', () => {
    const ed = editorWith([{ type: 'paragraph', content: [t('a')] }, { type: 'heading', attrs: { level: 2 }, content: [t('b')] }, { type: 'listItem', attrs: { kind: 'bullet', level: 0 }, content: [t('c')] }], 1, 8);
    setAlignment(ed, 'center');
    expect(blocks(ed).map((b) => (b as { attrs?: { align?: string } }).attrs?.align)).toEqual(['center', 'center', 'center']);
  });

  it('clears character formats but links, and makes the lines body text', () => {
    const link = { type: 'link', attrs: { href: 'https://example.com' } };
    const ed = editorWith(
      [
        { type: 'heading', attrs: { level: 1, align: 'right' }, content: [t('T', [{ type: 'bold' }, { type: 'fontSize', attrs: { delta: 3 } }])] },
        { type: 'listItem', attrs: { kind: 'task', level: 1, checked: true }, content: [t('x', [link, { type: 'highlight', attrs: { color: '#FFED8C' } }, { type: 'italic' }])] },
      ],
      1,
      6,
    );
    clearFormatting(ed);
    expect(blocks(ed)).toEqual([
      { type: 'paragraph', content: [t('T')] },
      { type: 'paragraph', content: [t('x', [link])] },
    ]);
  });

  it('takes quoted lines out of their quote', () => {
    const ed = editorWith([{ type: 'blockquote', content: [{ type: 'paragraph', content: [t('q', [{ type: 'underline' }])] }] }], 2);
    clearFormatting(ed);
    expect(blocks(ed)).toEqual([{ type: 'paragraph', content: [t('q')] }]);
  });
});
