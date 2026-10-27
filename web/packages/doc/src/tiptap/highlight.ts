/**
 * Code block syntax colouring (native CodeStyler + SyntaxHighlighter): consecutive code blocks in one language are
 * one block, coloured as decorations only (the doc is never changed). An explicit language is native's
 * `CodeLanguage(identifier:)`; "text" is plain; no language (or one NoteIt doesn't know) is guessed with native's
 * signals. Tokens come from highlight.js grammars for native's 20 languages, folded into native's seven token kinds.
 */
import { Extension } from '@tiptap/core';
import type { Node as PMNode } from '@tiptap/pm/model';
import { Plugin, PluginKey } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import bash from 'highlight.js/lib/languages/bash';
import c from 'highlight.js/lib/languages/c';
import cpp from 'highlight.js/lib/languages/cpp';
import csharp from 'highlight.js/lib/languages/csharp';
import css from 'highlight.js/lib/languages/css';
import go from 'highlight.js/lib/languages/go';
import java from 'highlight.js/lib/languages/java';
import javascript from 'highlight.js/lib/languages/javascript';
import json from 'highlight.js/lib/languages/json';
import kotlin from 'highlight.js/lib/languages/kotlin';
import markdown from 'highlight.js/lib/languages/markdown';
import php from 'highlight.js/lib/languages/php';
import python from 'highlight.js/lib/languages/python';
import ruby from 'highlight.js/lib/languages/ruby';
import rust from 'highlight.js/lib/languages/rust';
import sql from 'highlight.js/lib/languages/sql';
import swift from 'highlight.js/lib/languages/swift';
import typescript from 'highlight.js/lib/languages/typescript';
import xml from 'highlight.js/lib/languages/xml';
import yaml from 'highlight.js/lib/languages/yaml';
import { createLowlight } from 'lowlight';
import { codeLanguageId } from './languages.js';

/** Native `TokenKind`. */
export type TokenKind = 'keyword' | 'string' | 'comment' | 'number' | 'type' | 'property' | 'punctuation';

/** Native `CodeLanguage`, in its order: canonical id and menu name ("text" is Plain Text). */
export const CODE_LANGUAGES: readonly { id: string; name: string }[] = [
  { id: 'text', name: 'Plain Text' },
  { id: 'bash', name: 'Bash/Shell' },
  { id: 'c', name: 'C' },
  { id: 'cpp', name: 'C++' },
  { id: 'csharp', name: 'C#' },
  { id: 'css', name: 'CSS' },
  { id: 'go', name: 'Go' },
  { id: 'html', name: 'HTML/XML' },
  { id: 'java', name: 'Java' },
  { id: 'javascript', name: 'JavaScript' },
  { id: 'json', name: 'JSON' },
  { id: 'kotlin', name: 'Kotlin' },
  { id: 'markdown', name: 'Markdown' },
  { id: 'php', name: 'PHP' },
  { id: 'python', name: 'Python' },
  { id: 'ruby', name: 'Ruby' },
  { id: 'rust', name: 'Rust' },
  { id: 'sql', name: 'SQL' },
  { id: 'swift', name: 'Swift' },
  { id: 'typescript', name: 'TypeScript' },
  { id: 'yaml', name: 'YAML' },
];

const lowlight = createLowlight({ bash, c, cpp, csharp, css, go, java, javascript, json, kotlin, markdown, php, python, ruby, rust, sql, swift, typescript, xml, yaml });
const GRAMMAR: Record<string, string> = { html: 'xml' };

// MARK: Guessing (native SyntaxHighlighter.guessLanguage)

const SIGNALS: [string, [string, number][]][] = [
  ['swift', [['\\bfunc \\w+\\(', 2], ['\\b(let|var) \\w+(: [A-Z]\\w*)? = ', 1], ['\\bguard \\b', 3], ['^import (SwiftUI|Foundation|UIKit|AppKit|Combine)', 4], ['@(State|Published|MainActor|objc|Observable)\\b', 3], ['\\) -> \\w', 2], ['\\bif let \\b', 3], ['\\bstruct \\w+: \\w+', 2], ['\\bprint\\("', 1]]],
  ['python', [['^\\s*def \\w+\\(.*\\):\\s*$', 4], ['^\\s*(from \\w[\\w.]* )?import \\w', 1], ['\\bself\\.', 2], ['\\belif\\b', 3], ['^\\s*class \\w+(\\(.*\\))?:\\s*$', 3], ['\\b(True|False|None)\\b', 1], ['^if __name__', 4], ['\\bprint\\(f?["\']', 1]]],
  ['javascript', [['\\bfunction\\b', 2], ['\\b(const|let) \\w+ = ', 1], ['=> ', 2], ['console\\.log', 4], ['\\brequire\\(', 3], ['\\bdocument\\.', 3], ['module\\.exports', 4], ['===', 2], ['^import .* from [\'"]', 2], ['\\bexport (default|const|function)\\b', 2]]],
  ['typescript', [[': (string|number|boolean|void|any)\\b', 3], ['^\\s*(export )?interface \\w+', 3], ['^\\s*(export )?type \\w+ = ', 3], ['\\b(private|public|readonly) \\w+:', 2], ['\\bas const\\b', 3]]],
  ['go', [['^package \\w+', 5], ['\\bfunc (\\(\\w+ \\*?\\w+\\) )?\\w+\\(', 2], [' := ', 3], ['\\bfmt\\.', 4], ['\\berr != nil\\b', 4], ['^import \\(', 3]]],
  ['rust', [['\\bfn \\w+', 3], ['\\blet mut\\b', 4], ['\\bimpl\\b', 3], ['\\bpub (fn|struct|enum|mod)\\b', 3], ['\\w!\\(', 2], ['::', 1], ['&mut\\b', 3], ['\\buse \\w+::', 3]]],
  ['java', [['\\bpublic (static )?(class|void|final)\\b', 3], ['System\\.out\\.', 5], ['@Override', 4], ['\\bString\\[\\] args', 5], ['\\bprivate (final )?\\w+ \\w+;', 2], ['^import java\\.', 5]]],
  ['kotlin', [['\\bfun \\w+\\(', 4], ['\\bval \\w+', 2], ['\\bdata class\\b', 4], ['\\bprintln\\(', 1], ['\\bwhen \\(', 2]]],
  ['csharp', [['^using System', 5], ['\\bnamespace \\w+', 2], ['Console\\.Write', 5], ['\\{ get; (private )?set; \\}', 5], ['\\bpublic (async )?(void|Task|string|int)\\b', 2], ['\\bvar \\w+ = new\\b', 2]]],
  ['c', [['^#include <\\w+\\.h>', 4], ['\\bprintf\\(', 2], ['\\bint main\\(', 3], ['\\bmalloc\\(', 3], ['->', 1], ['^#define ', 2]]],
  ['cpp', [['^#include <\\w+>', 4], ['\\bstd::', 4], ['\\bcout <<', 4], ['\\btemplate ?<', 4], ['\\bnamespace \\w+', 1], ['::', 1], ['\\bnullptr\\b', 3]]],
  ['ruby', [['^\\s*def \\w+[!?]?(\\(.*\\))?\\s*$', 3], ['^\\s*end\\s*$', 2], ['\\bputs\\b', 3], ['\\.each do \\|', 4], ['^require [\'"]', 3], ['\\battr_(accessor|reader)\\b', 4], ['\\bdo \\|\\w+\\|', 3]]],
  ['php', [['<\\?php', 8], ['\\$this->', 5], ['\\becho \\$', 3], ['\\$\\w+ = ', 2], ['\\bfunction \\w+\\(\\$', 3]]],
  ['sql', [['\\bselect\\b[\\s\\S]*\\bfrom\\b', 4], ['\\binsert into\\b', 5], ['\\bcreate table\\b', 5], ['\\bwhere\\b', 1], ['\\b(inner|left) join\\b', 3], ['\\bupdate \\w+ set\\b', 4], ['\\bgroup by\\b|\\border by\\b', 2]]],
  // Native's possessive `*+` / `++`: the separators and words can't overlap, so plain quantifiers match the same.
  ['css', [['^\\s*[.#]?[\\w-]+(?:[ ,>+~.#:]+[\\w-]+)*\\s*\\{\\s*$', 2], ['^\\s*[a-z-]+:\\s*[^;{]+;\\s*$', 2], ['@media\\b', 4], ['\\b\\d+(px|rem|em|vh|vw)\\b', 2], ['#[0-9a-fA-F]{3,6};', 2]]],
  ['yaml', [['^\\s*[\\w-]+:( .+)?$', 1], ['^\\s*- [\\w"\']', 1], ['^---\\s*$', 2]]],
  ['markdown', [['^#{1,6} \\S', 3], ['\\[[^\\]]+\\]\\([^)]+\\)', 3], ['^\\s*[-*] \\[[ x]\\] ', 4], ['\\*\\*\\w[^*]*\\*\\*', 2], ['^> ', 2]]],
  ['bash', [['^#!/(usr/)?bin/(env )?(ba|z)?sh', 8], ['^\\s*\\$ \\w', 4], ['^\\s*(sudo|brew|apt(-get)?|npm|yarn|pip3?|git|cd|ls|mkdir|curl|chmod|export|echo|swift|xcodebuild|docker|make|cat|rm|cp|mv) ', 2], ['\\bfi\\s*$', 3], ['\\bdone\\s*$', 2], ['\\$\\{?\\w+\\}?', 1], [' \\| (grep|sed|awk|xargs|head|tail|sort)\\b', 3], [' --?\\w', 1]]],
];
const COMPILED = SIGNALS.map(([lang, patterns]) => [lang, patterns.map(([p, w]) => [new RegExp(p, lang === 'sql' ? 'gmi' : 'gm'), w] as const)] as const);
const GUESS_LIMIT = 4000;

const count = (re: RegExp, text: string) => {
  re.lastIndex = 0;
  let n = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    n += 1;
    if (m[0] === '') re.lastIndex += 1;
  }
  return n;
};

/** Best guess for a code block's language (a canonical id), or undefined if nothing stands out. */
export function guessCodeLanguage(text: string): string | undefined {
  let sample = text;
  if (text.length > GUESS_LIMIT) {
    sample = text.slice(0, GUESS_LIMIT);
    const lastLine = sample.lastIndexOf('\n');
    if (lastLine >= 0) sample = sample.slice(0, lastLine);
  }
  const trimmed = sample.trim();
  if (!trimmed) return undefined;
  if (trimmed.startsWith('<?php')) return 'php';
  if (trimmed.startsWith('#!')) {
    if (trimmed.startsWith('#!/usr/bin/env python') || trimmed.startsWith('#!/usr/bin/python')) return 'python';
    if (trimmed.includes('ruby')) return 'ruby';
    if (trimmed.includes('node')) return 'javascript';
    return 'bash';
  }
  if (trimmed[0] === '{' || trimmed[0] === '[') {
    try {
      JSON.parse(trimmed);
      return 'json';
    } catch {
      // not JSON
    }
  }
  if (trimmed.startsWith('<') && count(/<\/\w+>|\/>|<!DOCTYPE|<\?xml/gm, trimmed) > 0) return 'html';
  const scores = new Map<string, number>();
  for (const [lang, patterns] of COMPILED) scores.set(lang, patterns.reduce((s, [re, w]) => s + Math.min(count(re, trimmed), 3) * w, 0));
  const ts = scores.get('typescript')!;
  if (ts > 0) scores.set('typescript', ts + scores.get('javascript')!);
  const cp = scores.get('cpp')!;
  if (cp > 0) scores.set('cpp', cp + Math.trunc(scores.get('c')! / 2));
  let best: [string, number] | undefined;
  for (const [lang] of COMPILED) {
    const score = scores.get(lang)!;
    if (score >= 2 && score > (best?.[1] ?? 0)) best = [lang, score];
  }
  return best?.[0];
}

/** The language a block is coloured as: its own (when NoteIt knows it), else the guess; undefined is plain. */
export function effectiveCodeLanguage(language: string | null | undefined, text: string): { id?: string; guessed: boolean } {
  const explicit = language ? codeLanguageId(language) : undefined;
  if (explicit) return explicit === 'text' ? { guessed: false } : { id: explicit, guessed: false };
  const guess = guessCodeLanguage(text);
  return guess ? { id: guess, guessed: true } : { guessed: true };
}

// MARK: Tokens

/** highlight.js scopes → native token kinds (the first matching part wins; `title.class` is a type, and so on). */
function kindOf(scope: string): TokenKind | undefined {
  const s = scope.replace(/^hljs-/, '');
  if (/^(comment|quote|doctag)/.test(s)) return 'comment';
  if (/^(string|regexp|char|symbol|subst|template-tag|link|code)/.test(s)) return 'string';
  if (/^(number)/.test(s)) return 'number';
  if (/^(title\.class|type|built_in|class|selector-tag|tag|name|section)/.test(s)) return 'type';
  if (/^(keyword|literal|meta|selector-pseudo|bullet)/.test(s)) return 'keyword';
  if (/^(attr|attribute|property|variable|params|template-variable|selector-id|selector-class|selector-attr|title|emphasis|strong)/.test(s)) return 'property';
  if (/^(punctuation|operator)/.test(s)) return 'punctuation';
  return undefined;
}

type Hast = { type: string; value?: string; properties?: { className?: string[] }; children?: Hast[] };

/** Token ranges (UTF-16 offsets) in `text` for a canonical language id. */
export function codeTokens(text: string, language: string): { from: number; to: number; kind: TokenKind }[] {
  const grammar = GRAMMAR[language] ?? language;
  if (!lowlight.registered(grammar)) return [];
  const tree = lowlight.highlight(grammar, text) as unknown as Hast;
  const out: { from: number; to: number; kind: TokenKind }[] = [];
  let offset = 0;
  const walk = (node: Hast, kind: TokenKind | undefined) => {
    if (node.type === 'text') {
      const len = node.value?.length ?? 0;
      if (kind && len) out.push({ from: offset, to: offset + len, kind });
      offset += len;
      return;
    }
    let k = kind;
    for (const cls of node.properties?.className ?? []) k = kindOf(cls) ?? k;
    for (const child of node.children ?? []) walk(child, k);
  };
  walk(tree, undefined);
  return out;
}

// MARK: Decorations

/** Runs of consecutive top-level code blocks with the same `language`: native's code block. */
export function codeBlockGroups(doc: PMNode): { language: string | null; lines: { pos: number; node: PMNode }[] }[] {
  const groups: { language: string | null; lines: { pos: number; node: PMNode }[] }[] = [];
  let previous: (typeof groups)[number] | undefined;
  doc.forEach((node, pos) => {
    if (node.type.name !== 'codeBlock') {
      previous = undefined;
      return;
    }
    const language = (node.attrs.language as string | null) ?? null;
    if (previous && previous.language === language) previous.lines.push({ pos, node });
    else groups.push((previous = { language, lines: [{ pos, node }] }));
  });
  return groups;
}

/** A code line's text where every inline node is as long as its size (hard breaks are newlines, objects one char). */
const lineText = (node: PMNode) => node.textBetween(0, node.content.size, '\n', '￼');

function decorate(doc: PMNode): DecorationSet {
  const decorations: Decoration[] = [];
  for (const group of codeBlockGroups(doc)) {
    const texts = group.lines.map((l) => lineText(l.node));
    const text = texts.join('\n');
    const { id } = effectiveCodeLanguage(group.language, text);
    if (!id) continue;
    const starts: number[] = [];
    let at = 0;
    for (const t of texts) {
      starts.push(at);
      at += t.length + 1;
    }
    for (const token of codeTokens(text, id)) {
      for (let k = 0; k < group.lines.length; k++) {
        const lineFrom = starts[k]!;
        const lineTo = lineFrom + texts[k]!.length;
        const from = Math.max(token.from, lineFrom);
        const to = Math.min(token.to, lineTo);
        if (from >= to) continue;
        const base = group.lines[k]!.pos + 1 - lineFrom;
        decorations.push(Decoration.inline(base + from, base + to, { class: `tk-${token.kind}` }));
      }
    }
  }
  return DecorationSet.create(doc, decorations);
}

export const codeHighlightKey = new PluginKey<DecorationSet>('noteitCodeHighlight');

export const CodeHighlight = Extension.create({
  name: 'noteitCodeHighlight',
  addProseMirrorPlugins: () => [
    new Plugin<DecorationSet>({
      key: codeHighlightKey,
      state: {
        init: (_, state) => decorate(state.doc),
        apply: (tr, old) => (tr.docChanged ? decorate(tr.doc) : old),
      },
      props: { decorations: (state) => codeHighlightKey.getState(state) },
    }),
  ],
});
