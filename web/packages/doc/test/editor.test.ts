// @vitest-environment happy-dom
import { Editor } from '@tiptap/core';
import { undo } from '@tiptap/pm/history';
import { afterEach, describe, expect, it } from 'vitest';
import { fromEditorJSON, insertTable, noteItExtensions } from '../src/tiptap/index.js';

const p2 = (text: string) => ({ type: 'paragraph', content: [{ type: 'text', text }] });
const para = (text = '') => (text ? { type: 'paragraph', content: [{ type: 'text', text }] } : { type: 'paragraph' });

// Every editor is destroyed after its test, so ProseMirror's DOM timers never outlive the environment.
const live: Editor[] = [];
afterEach(() => {
  for (const ed of live.splice(0)) ed.destroy();
});

function editorWith(content: unknown[] = [para()], at = 1) {
  const ed = track(new Editor({ element: document.createElement('div'), extensions: noteItExtensions(), content: { type: 'doc', content } as never }));
  ed.commands.setTextSelection(at);
  return ed;
}
const track = (ed: Editor) => (live.push(ed), ed);
const KEY_CODES: Record<string, number> = { Tab: 9, Enter: 13, e: 69, E: 69 };
function press(ed: Editor, key: string, mods: { shift?: boolean; meta?: boolean } = {}) {
  // ProseMirror's Mod is ⌘ on a Mac and Ctrl elsewhere.
  const mac = /Mac|iPhone|iPad/.test(navigator.platform);
  const event = new KeyboardEvent('keydown', { key, shiftKey: !!mods.shift, metaKey: !!mods.meta && mac, ctrlKey: !!mods.meta && !mac, bubbles: true, cancelable: true });
  Object.defineProperty(event, 'keyCode', { value: KEY_CODES[key] ?? 0 });
  let handled = false;
  ed.view.someProp('handleKeyDown', (f) => (handled ||= !!f(ed.view, event)));
  return handled;
}
/** Types like a keyboard: each character goes through handleTextInput first, as in the browser. */
function type(ed: Editor, text: string) {
  for (const ch of text) {
    const { from, to } = ed.state.selection;
    let handled = false;
    ed.view.someProp('handleTextInput', (f) => (handled ||= !!f(ed.view, from, to, ch, () => ed.state.tr.insertText(ch, from, to))));
    if (!handled) ed.view.dispatch(ed.state.tr.insertText(ch, from, to));
  }
}
const blocks = (ed: Editor) => fromEditorJSON(ed.getJSON()).content;

describe('Tab and ⇧Tab', () => {
  it('indent and outdent a list item', () => {
    const ed = editorWith([{ type: 'listItem', attrs: { kind: 'task', level: 0, checked: false }, content: [{ type: 'text', text: 'a' }] }], 2);
    expect(press(ed, 'Tab')).toBe(true);
    expect(ed.state.doc.firstChild!.attrs.level).toBe(1);
    expect(press(ed, 'Tab', { shift: true })).toBe(true);
    expect(ed.state.doc.firstChild!.attrs.level).toBe(0);
    // Nothing to outdent: the key is still taken, so focus stays in the note.
    expect(press(ed, 'Tab', { shift: true })).toBe(true);
  });

  it('move between table cells and add a row after the last; a new table starts in its first cell', () => {
    const ed = editorWith([para()]);
    insertTable(ed);
    expect(ed.state.selection.$from.node(ed.state.selection.$from.depth - 1).type.name).toBe('tableHeader');
    type(ed, 'A');
    for (let i = 0; i < 3; i++) expect(press(ed, 'Tab')).toBe(true);
    type(ed, 'D');
    expect(press(ed, 'Tab')).toBe(true);
    const table = blocks(ed).find((b) => b.type === 'table') as { content: unknown[] };
    expect(table.content).toHaveLength(3);
    expect(JSON.stringify(table)).toMatch(/"A".*"D"/);
    expect(press(ed, 'Tab', { shift: true })).toBe(true);
    expect(ed.state.selection.empty).toBe(false);
  });

  it('types a tab character in body text', () => {
    const ed = editorWith([para('ab')], 2);
    expect(press(ed, 'Tab')).toBe(true);
    expect(ed.state.doc.textContent).toBe('a\tb');
  });
});

describe('Markdown as you type', () => {
  const cases: [string, Record<string, unknown>][] = [
    ['# ', { type: 'heading', attrs: { level: 1 } }],
    ['> ', { type: 'blockquote' }],
    ['- ', { type: 'listItem', attrs: { kind: 'bullet', level: 0 } }],
    ['+ ', { type: 'listItem', attrs: { kind: 'bullet', level: 0 } }],
    ['3) ', { type: 'listItem', attrs: { kind: 'ordered', level: 0, number: 3 } }],
    ['1. ', { type: 'listItem', attrs: { kind: 'ordered', level: 0, number: 1 } }],
    ['[x] ', { type: 'listItem', attrs: { kind: 'task', level: 0, checked: true } }],
    ['``` ', { type: 'codeBlock' }],
    ['```py ', { type: 'codeBlock', attrs: { language: 'python' } }],
  ];
  for (const [typed, block] of cases) {
    it(`"${typed}" at the start of a line`, () => {
      const ed = editorWith();
      type(ed, typed);
      expect(blocks(ed)[0]).toMatchObject(block);
      expect(ed.state.doc.textContent).toBe('');
    });
  }

  it('``` then Return makes a code block that keeps what you type next', () => {
    const ed = editorWith();
    type(ed, '```js');
    expect(press(ed, 'Enter')).toBe(true);
    type(ed, 'let a');
    expect(blocks(ed)[0]).toMatchObject({ type: 'codeBlock', attrs: { language: 'javascript' }, content: [{ type: 'text', text: 'let a' }] });
  });

  it('--- then Return makes a divider', () => {
    const ed = editorWith();
    type(ed, '---');
    expect(press(ed, 'Enter')).toBe(true);
    expect(blocks(ed).map((b) => b.type)).toEqual(['horizontalRule', 'paragraph']);
  });

  const inline: [string, string, string][] = [
    ['**b**', 'bold', 'b'],
    ['*i*', 'italic', 'i'],
    ['`c`', 'code', 'c'],
    ['~~s~~', 'strike', 's'],
  ];
  for (const [typed, mark, text] of inline) {
    it(`${typed} becomes ${mark}, and ⌘Z gives back the Markdown`, () => {
      const ed = editorWith();
      type(ed, `x ${typed}`);
      expect(blocks(ed)[0]).toMatchObject({ content: [{ text: 'x ' }, { text, marks: [{ type: mark }] }] });
      type(ed, 'y');
      expect((blocks(ed)[0] as { content: { text: string; marks?: unknown }[] }).content.at(-1)).toEqual({ type: 'text', text: 'y' });
      undo(ed.state, ed.view.dispatch);
      undo(ed.state, ed.view.dispatch);
      expect(ed.state.doc.textContent).toBe(`x ${typed}`);
    });
  }

  it('leaves text alone in a code block', () => {
    const ed = editorWith([{ type: 'codeBlock' }]);
    type(ed, '**a** - ');
    expect(ed.state.doc.textContent).toBe('**a** - ');
  });

  it('⇧⌘E toggles inline code like ⌘E', () => {
    const ed = editorWith([para('word')]);
    ed.commands.setTextSelection({ from: 1, to: 5 });
    expect(press(ed, 'E', { shift: true, meta: true })).toBe(true);
    expect(ed.isActive('code')).toBe(true);
  });
});

describe('[[ links as you type', () => {
  it('[[Title]] becomes a link to that note, resolved by the host', () => {
    const ed = track(new Editor({
      element: document.createElement('div'),
      extensions: noteItExtensions({ wikiLink: (inner) => ({ href: `noteit://note?title=${encodeURIComponent(inner)}`, text: inner }) }),
      content: { type: 'doc', content: [{ type: 'paragraph' }] } as never,
    }));
    ed.commands.setTextSelection(1);
    type(ed, 'see [[Plans]] ok');
    expect(blocks(ed)[0]).toMatchObject({ content: [{ text: 'see ' }, { text: 'Plans', marks: [{ type: 'link', attrs: { href: 'noteit://note?title=Plans' } }] }, { text: ' ok' }] });
  });
});

describe('find and replace (native FindReplaceEngine)', () => {
  it('finds with case, whole word and regex, and replaces keeping formatting in one undo step', async () => {
    const { findMatches, findPattern, replaceMatches } = await import('../src/tiptap/index.js');
    const ed = editorWith([p2('Cat cat '), { type: 'paragraph', content: [{ type: 'text', text: 'concat', marks: [{ type: 'bold' }] }] }]);
    const count = (q: string, o = {}) => findMatches(ed.state.doc, findPattern(q, o) as RegExp).length;
    expect(count('cat')).toBe(3);
    expect(count('cat', { matchCase: true })).toBe(2);
    expect(count('cat', { wholeWord: true })).toBe(2);
    expect(findPattern('(', { regex: true })).toBeTypeOf('string');
    const pattern = findPattern('c(a)t', { regex: true }) as RegExp;
    ed.view.dispatch(replaceMatches(ed.state.tr, findMatches(ed.state.doc, pattern), 'd$1g', true));
    expect(ed.state.doc.textContent).toBe('dag dag condag');
    expect(blocks(ed)[1]).toEqual({ type: 'paragraph', content: [{ type: 'text', text: 'condag', marks: [{ type: 'bold' }] }] });
    undo(ed.state, ed.view.dispatch);
    expect(ed.state.doc.textContent).toBe('Cat cat concat');
  });
});

describe('natural dates as you type', () => {
  it('@due(tomorrow) becomes a full date when ) is typed', () => {
    const ed = editorWith();
    type(ed, 'Call @due(tomorrow)');
    expect(ed.state.doc.textContent).toMatch(/^Call @due\(\d{4}-\d{2}-\d{2}\)$/);
    undo(ed.state, ed.view.dispatch);
    expect(ed.state.doc.textContent).toBe('Call @due(tomorrow)');
  });
});
