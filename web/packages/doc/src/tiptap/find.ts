/**
 * Find and replace in a note (native FindReplaceEngine): matches within each paragraph, with Match Case, Whole Word
 * and Regular Expression; `$1`… in a regex replacement; replaced text keeps the formatting of the text it replaces.
 */
import { Extension } from '@tiptap/core';
import type { Node as PMNode } from '@tiptap/pm/model';
import { Plugin, PluginKey, type Transaction } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';

export interface FindOptions {
  matchCase?: boolean;
  wholeWord?: boolean;
  regex?: boolean;
}
export interface FindMatch {
  from: number;
  to: number;
  /** Capture groups, for `$1` in a regex replacement. */
  groups: string[];
}

/** The search as a RegExp, or an error message for a pattern that doesn't compile. */
export function findPattern(query: string, opts: FindOptions = {}): RegExp | string | undefined {
  if (!query) return undefined;
  let source = opts.regex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  if (opts.wholeWord) source = `(?<![\\p{L}\\p{N}_])(?:${source})(?![\\p{L}\\p{N}_])`;
  try {
    return new RegExp(source, `gu${opts.matchCase ? '' : 'i'}`);
  } catch (e) {
    return e instanceof Error ? e.message : 'Invalid pattern';
  }
}

/** Every match, in document order; text in each textblock is searched on its own. */
export function findMatches(doc: PMNode, pattern: RegExp): FindMatch[] {
  const out: FindMatch[] = [];
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true;
    const text = node.textBetween(0, node.content.size, undefined, '￼');
    pattern.lastIndex = 0;
    for (const m of text.matchAll(pattern)) {
      if (!m[0].length) continue;
      out.push({ from: pos + 1 + m.index!, to: pos + 1 + m.index! + m[0].length, groups: m.slice(1).map((g) => g ?? '') });
    }
    return false;
  });
  return out;
}

/** A replacement with `$1`… and `$$` expanded (regex mode only). */
export function expandReplacement(replacement: string, match: FindMatch, regex: boolean): string {
  if (!regex) return replacement;
  return replacement.replace(/\$(\$|\d{1,2})/g, (all, g: string) => (g === '$' ? '$' : (match.groups[Number(g) - 1] ?? all)));
}

/** Replaces matches in one transaction (one ⌘Z), last first so positions stay valid. */
export function replaceMatches(tr: Transaction, matches: FindMatch[], replacement: string, regex: boolean): Transaction {
  for (const m of [...matches].sort((a, b) => b.from - a.from)) {
    const text = expandReplacement(replacement, m, regex);
    const marks = tr.doc.resolve(m.from + 1).marks();
    if (text) tr.replaceWith(m.from, m.to, tr.doc.type.schema.text(text, marks));
    else tr.delete(m.from, m.to);
  }
  return tr;
}

export const findKey = new PluginKey<DecorationSet>('noteitFind');

/** Highlights the matches the find bar hands it (`tr.setMeta(findKey, { matches, current })`). */
export const FindHighlight = Extension.create({
  name: 'noteitFind',
  addProseMirrorPlugins() {
    return [
      new Plugin<DecorationSet>({
        key: findKey,
        state: {
          init: () => DecorationSet.empty,
          apply(tr, set) {
            const meta = tr.getMeta(findKey) as { matches: FindMatch[]; current: number } | undefined;
            if (meta) {
              return DecorationSet.create(
                tr.doc,
                meta.matches.map((m, i) => Decoration.inline(m.from, m.to, { class: i === meta.current ? 'ni-find ni-find-current' : 'ni-find' })),
              );
            }
            return set.map(tr.mapping, tr.doc);
          },
        },
        props: { decorations: (state) => findKey.getState(state) },
      }),
    ];
  },
});
