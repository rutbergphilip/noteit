// @vitest-environment happy-dom
import { Editor } from '@tiptap/core';
import { afterEach, describe, expect, it } from 'vitest';
import { addTableRow, deleteTableRow, fromEditorJSON, noteItExtensions } from '../src/tiptap/index.js';

const live: Editor[] = [];
afterEach(() => {
  for (const ed of live.splice(0)) ed.destroy();
});
const cell = (type: string, text: string) => ({ type, content: [{ type: 'paragraph', content: [{ type: 'text', text }] }] });
const row = (type: string, ...texts: string[]) => ({ type: 'tableRow', content: texts.map((t) => cell(type, t)) });
const table = (...rows: unknown[]) => ({ type: 'table', content: rows });
function editorWith(content: unknown[], at: number) {
  const ed = new Editor({ element: document.createElement('div'), extensions: noteItExtensions(), content: { type: 'doc', content } as never });
  live.push(ed);
  ed.commands.setTextSelection(at);
  return ed;
}
const rows = (ed: Editor) => ((fromEditorJSON(ed.getJSON()).content[0] as { content?: { content: { type: string; content: { content?: { text: string }[] }[] }[] }[] }).content ?? []).map((r) => r.content.map((c) => `${c.type === 'tableHeader' ? 'H' : ''}${c.content[0]?.content?.[0]?.text ?? ''}`).join('|'));

describe('table rows (native addTableRow / deleteTableRow)', () => {
  // Positions: table 0, header row 1, cell 2, paragraph 3, text 4…
  it('adds an empty body row below or above, never above the header', () => {
    const ed = editorWith([table(row('tableHeader', 'a', 'b'), row('tableCell', 'c', 'd'))], 4);
    expect(addTableRow(ed, false)).toBe(false);
    addTableRow(ed, true);
    expect(rows(ed)).toEqual(['Ha|Hb', '|', 'c|d']);
  });

  it('deletes a row; the next row becomes the header; the last row deletes the table', () => {
    const ed = editorWith([table(row('tableHeader', 'a'), row('tableCell', 'b')), { type: 'paragraph' }], 4);
    deleteTableRow(ed);
    expect(rows(ed)).toEqual(['Hb']);
    deleteTableRow(ed);
    expect(fromEditorJSON(ed.getJSON()).content).toEqual([{ type: 'paragraph' }]);
  });
});
