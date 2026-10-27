// @vitest-environment happy-dom
import { Editor } from '@tiptap/core';
import { afterEach, describe, expect, it } from 'vitest';
import { CODE_LANGUAGES, codeHighlightKey, codeLanguageId, codeTokens, effectiveCodeLanguage, fromEditorJSON, guessCodeLanguage, noteItExtensions } from '../src/tiptap/index.js';

const live: Editor[] = [];
afterEach(() => {
  for (const ed of live.splice(0)) ed.destroy();
});
const code = (text: string, language?: string) => ({ type: 'codeBlock', ...(language ? { attrs: { language } } : {}), content: text ? [{ type: 'text', text }] : [] });
const editorWith = (content: unknown[]) => {
  const ed = new Editor({ element: document.createElement('div'), extensions: noteItExtensions(), content: { type: 'doc', content } as never });
  live.push(ed);
  return ed;
};

describe('code language guessing (native CodeStylingTests.testGuessLanguage)', () => {
  it('guesses as the Mac does', () => {
    expect(guessCodeLanguage('import SwiftUI\n\nstruct ContentView: View {\n    var body: some View { Text("Hi") }\n}')).toBe('swift');
    expect(guessCodeLanguage('def main():\n    print("hi")\n\nif __name__ == "__main__":\n    main()')).toBe('python');
    expect(guessCodeLanguage('{"a": 1, "b": [true, null]}')).toBe('json');
    expect(guessCodeLanguage('#!/bin/bash\necho hi')).toBe('bash');
    expect(guessCodeLanguage('SELECT name FROM users WHERE id = 1;')).toBe('sql');
    expect(guessCodeLanguage('<div class="x"><p>Hi</p></div>')).toBe('html');
    expect(guessCodeLanguage("const x = require('fs');\nfunction f() { console.log(x); }")).toBe('javascript');
    expect(guessCodeLanguage('just some words here')).toBeUndefined();
  });

  it('stays fast on awkward input', () => {
    const start = performance.now();
    for (const text of ['a-b c,d>e '.repeat(400) + 'x', 'select a, b, c '.repeat(500), 'x = y.z(w) # q\n'.repeat(2000)]) guessCodeLanguage(text);
    expect(performance.now() - start).toBeLessThan(1000);
  });

  it('uses the block’s own language when NoteIt knows it, "text" as plain, and guesses otherwise', () => {
    expect(effectiveCodeLanguage('py', 'x')).toEqual({ id: 'python', guessed: false });
    expect(effectiveCodeLanguage('text', 'func f() {}')).toEqual({ guessed: false });
    expect(effectiveCodeLanguage('not-a-known-language', '#!/bin/sh\nls')).toEqual({ id: 'bash', guessed: true });
    expect(CODE_LANGUAGES.map((l) => codeLanguageId(l.id))).toEqual(CODE_LANGUAGES.map((l) => l.id));
  });
});

describe('code tokens', () => {
  it('folds highlight.js scopes into native token kinds, in order and inside the text', () => {
    const text = 'let x = "hi" // note\nfunc f() -> Int { return 42 }';
    const tokens = codeTokens(text, 'swift');
    const kinds = Object.fromEntries(tokens.map((t) => [text.slice(t.from, t.to), t.kind]));
    expect(kinds).toMatchObject({ let: 'keyword', '"hi"': 'string', '// note': 'comment', '42': 'number', return: 'keyword' });
    let last = 0;
    for (const t of tokens) {
      expect(t.from).toBeGreaterThanOrEqual(last);
      expect(t.to).toBeLessThanOrEqual(text.length);
      last = t.to;
    }
    for (const { id } of CODE_LANGUAGES) for (const t of codeTokens('"unterminated /* x\n\'q 12 <a b="c\n# z', id)) expect(t.to).toBeLessThanOrEqual(37);
  });
});

describe('code block colouring in the editor', () => {
  it('colours a block of code lines as one, across lines, without changing the doc', () => {
    const doc = [code('let s = """', 'swift'), code('inside', 'swift'), code('"""', 'swift'), { type: 'paragraph', content: [{ type: 'text', text: 'let x' }] }];
    const ed = editorWith(doc);
    const decos = codeHighlightKey.getState(ed.state)!.find();
    const covered = decos.map((d) => ed.state.doc.textBetween(d.from, d.to));
    expect(covered).toContain('inside');
    expect(decos.every((d) => d.to <= ed.state.doc.child(0).nodeSize + ed.state.doc.child(1).nodeSize + ed.state.doc.child(2).nodeSize)).toBe(true);
    expect(fromEditorJSON(ed.getJSON()).content).toEqual(doc);
  });

  it('keeps every language attribute exactly as stored, known or not', () => {
    const doc = [...CODE_LANGUAGES.map((l, i) => code(`x${i}`, l.id)), code('y', 'not-a-known-language'), code('z', 'Py'), code('w')];
    const ed = editorWith(doc);
    ed.view.dispatch(ed.state.tr.insertText('q', 2));
    const out = fromEditorJSON(ed.getJSON()).content as { attrs?: { language?: string } }[];
    expect(out.map((b) => b.attrs?.language)).toEqual([...CODE_LANGUAGES.map((l) => l.id), 'not-a-known-language', 'Py', undefined]);
  });
});
