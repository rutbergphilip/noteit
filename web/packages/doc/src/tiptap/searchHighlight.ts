/**
 * The list search's words marked in the open note (native SearchHighlightController): decorations only, so the
 * note's text never changes; cleared by an edit, by Esc and when the search is cleared.
 */
import { Extension } from '@tiptap/core';
import type { Node as PMNode } from '@tiptap/pm/model';
import { Plugin, PluginKey } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import { searchHighlightRanges } from '../snippet.js';

export const searchHighlightKey = new PluginKey<DecorationSet>('noteitSearchHighlight');

/** Where the folded search terms occur, as doc positions; each textblock is searched on its own. */
export function searchHighlightPositions(doc: PMNode, terms: readonly string[]): { from: number; to: number }[] {
  const out: { from: number; to: number }[] = [];
  if (!terms.length) return out;
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true;
    const text = node.textBetween(0, node.content.size, undefined, '￼');
    for (const [a, b] of searchHighlightRanges(terms, text)) out.push({ from: pos + 1 + a, to: pos + 1 + b });
    return false;
  });
  return out;
}

/** `tr.setMeta(searchHighlightKey, terms)` marks them; an empty list or any edit clears them. */
export const SearchHighlight = Extension.create({
  name: 'noteitSearchHighlight',
  addProseMirrorPlugins: () => [
    new Plugin<DecorationSet>({
      key: searchHighlightKey,
      state: {
        init: () => DecorationSet.empty,
        apply(tr, set) {
          const terms = tr.getMeta(searchHighlightKey) as string[] | undefined;
          if (terms) return DecorationSet.create(tr.doc, searchHighlightPositions(tr.doc, terms).map((r) => Decoration.inline(r.from, r.to, { class: 'ni-search-hit' })));
          return tr.docChanged ? DecorationSet.empty : set;
        },
      },
      props: { decorations: (state) => searchHighlightKey.getState(state) },
    }),
  ],
});
