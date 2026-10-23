import { Extension, Mark, mergeAttributes, Node, textblockTypeInputRule, type AnyExtension, type Editor } from '@tiptap/core';
import { history, redo, undo } from '@tiptap/pm/history';
import { isAllowedLink } from '../schema.js';

const BULLETS = ['•', '◦', '▪'];

const alignAttr = {
  align: {
    default: null,
    parseHTML: (el: HTMLElement) => el.style.textAlign || null,
    renderHTML: (a: Record<string, unknown>) => (a.align ? { style: `text-align: ${String(a.align)}` } : {}),
  },
};
const indentAttr = {
  indent: {
    default: null,
    parseHTML: (el: HTMLElement) => (el.dataset.indent ? Number(el.dataset.indent) : null),
    renderHTML: (a: Record<string, unknown>) => (a.indent ? { 'data-indent': String(a.indent), style: `margin-left: ${Number(a.indent) * 24}px` } : {}),
  },
};

export const DocNodeExt = Node.create({ name: 'doc', topNode: true, content: 'block+' });
export const TextNode = Node.create({ name: 'text', group: 'inline' });

export const ParagraphNode = Node.create({
  name: 'paragraph',
  priority: 1000,
  group: 'block',
  content: 'inline*',
  addAttributes: () => ({ ...alignAttr, ...indentAttr }),
  parseHTML: () => [{ tag: 'p' }],
  renderHTML: ({ HTMLAttributes }) => ['p', HTMLAttributes, 0],
});

export const HeadingNode = Node.create({
  name: 'heading',
  group: 'block',
  content: 'inline*',
  defining: true,
  addAttributes: () => ({ level: { default: 1, rendered: false }, ...alignAttr, ...indentAttr }),
  parseHTML: () => [1, 2, 3].map((level) => ({ tag: `h${level}`, attrs: { level } })),
  renderHTML: ({ node, HTMLAttributes }) => [`h${node.attrs.level as number}`, HTMLAttributes, 0],
  addInputRules() {
    return [1, 2, 3].map((level) => textblockTypeInputRule({ find: new RegExp(`^(#{${level}})\\s$`), type: this.type, getAttributes: { level } }));
  },
});

export const CodeBlockNode = Node.create({
  name: 'codeBlock',
  group: 'block',
  content: 'inline*',
  marks: 'bold italic underline strike link textColor highlight fontSize',
  whitespace: 'pre',
  defining: true,
  addAttributes: () => ({ ...alignAttr, language: { default: null, parseHTML: (el) => el.dataset.language || null, renderHTML: (a) => (a.language ? { 'data-language': a.language } : {}) } }),
  parseHTML: () => [{ tag: 'pre', preserveWhitespace: 'full' }],
  renderHTML: ({ HTMLAttributes }) => ['pre', mergeAttributes(HTMLAttributes, { class: 'ni-code' }), 0],
  addInputRules() {
    return [textblockTypeInputRule({ find: /^```$/, type: this.type })];
  },
  addKeyboardShortcuts() {
    return {
      // One codeBlock per native code paragraph: Enter makes the next code paragraph; Enter on an empty one leaves.
      Enter: ({ editor }) => {
        const { $from, empty } = editor.state.selection;
        if (!empty || $from.parent.type.name !== 'codeBlock') return false;
        if ($from.parent.content.size === 0) return editor.commands.setNode('paragraph');
        const attrs = { ...$from.parent.attrs };
        return editor.chain().splitBlock().setNode('codeBlock', attrs).run();
      },
      'Shift-Enter': ({ editor }) => editor.state.selection.$from.parent.type.name === 'codeBlock' && editor.commands.setHardBreak(),
    };
  },
});

export const BlockquoteNode = Node.create({
  name: 'blockquote',
  group: 'block',
  content: 'paragraph+',
  defining: true,
  addAttributes: () => ({ ...indentAttr }),
  parseHTML: () => [{ tag: 'blockquote' }],
  renderHTML: ({ HTMLAttributes }) => ['blockquote', HTMLAttributes, 0],
});

export const HorizontalRuleNode = Node.create({
  name: 'horizontalRule',
  group: 'block',
  atom: true,
  parseHTML: () => [{ tag: 'hr' }],
  renderHTML: () => ['hr'],
});

/** Flat list items (spec §3.3): kind + level, glyph from level % 3, stored numbers, derived checked styling. */
export const ListItemNode = Node.create({
  name: 'listItem',
  group: 'block',
  content: 'inline*',
  defining: true,
  addAttributes: () => ({
    kind: { default: 'bullet', parseHTML: (el) => el.dataset.kind ?? 'bullet', renderHTML: (a) => ({ 'data-kind': a.kind }) },
    level: { default: 0, parseHTML: (el) => Number(el.dataset.level ?? 0), renderHTML: (a) => ({ 'data-level': String(a.level) }) },
    number: { default: null, parseHTML: (el) => (el.dataset.number ? Number(el.dataset.number) : null), renderHTML: (a) => (a.number != null ? { 'data-number': String(a.number) } : {}) },
    checked: { default: null, parseHTML: (el) => (el.dataset.checked ? el.dataset.checked === 'true' : null), renderHTML: (a) => (a.checked != null ? { 'data-checked': String(a.checked) } : {}) },
    ...alignAttr,
  }),
  parseHTML: () => [{ tag: 'div[data-type="list-item"]' }],
  renderHTML: ({ HTMLAttributes }) => ['div', mergeAttributes(HTMLAttributes, { 'data-type': 'list-item', class: 'ni-li' }), 0],
  addNodeView() {
    return ({ node, getPos, editor }) => {
      const dom = document.createElement('div');
      const marker = document.createElement('span');
      const content = document.createElement('div');
      marker.contentEditable = 'false';
      marker.className = 'ni-li-marker';
      content.className = 'ni-li-content';
      dom.append(marker, content);
      const render = (n: typeof node) => {
        const a = n.attrs as { kind: string; level: number; number: number | null; checked: boolean | null; align: string | null };
        dom.className = `ni-li ni-li-${a.kind}${a.checked ? ' is-checked' : ''}`;
        dom.dataset.level = String(a.level);
        dom.style.paddingLeft = `${a.level * 24}px`;
        content.style.textAlign = a.align ?? '';
        marker.replaceChildren();
        if (a.kind === 'task') {
          const box = document.createElement('input');
          box.type = 'checkbox';
          box.checked = !!a.checked;
          box.setAttribute('aria-label', a.checked ? 'Mark as not done' : 'Mark as done');
          box.addEventListener('mousedown', (e) => e.preventDefault());
          box.addEventListener('click', (e) => {
            e.preventDefault();
            const pos = typeof getPos === 'function' ? getPos() : undefined;
            if (pos === undefined || !editor.isEditable) return;
            editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, { ...n.attrs, checked: !a.checked }));
          });
          marker.append(box);
        } else {
          marker.textContent = a.kind === 'ordered' ? `${a.number ?? 1}.` : BULLETS[a.level % 3]!;
        }
      };
      render(node);
      return {
        dom,
        contentDOM: content,
        update: (updated) => {
          if (updated.type.name !== 'listItem') return false;
          node = updated;
          render(updated);
          return true;
        },
      };
    };
  },
  addInputRules() {
    return [
      textblockTypeInputRule({ find: /^\s*([-*•])\s$/, type: this.type, getAttributes: { kind: 'bullet', level: 0 } }),
      textblockTypeInputRule({ find: /^(\d+)\.\s$/, type: this.type, getAttributes: (m) => ({ kind: 'ordered', level: 0, number: Number(m[1]) }) }),
      textblockTypeInputRule({ find: /^\[( |x)?\]\s$/, type: this.type, getAttributes: (m) => ({ kind: 'task', level: 0, checked: m[1] === 'x' }) }),
    ];
  },
  addKeyboardShortcuts() {
    const inItem = (editor: Editor) => editor.state.selection.$from.parent.type.name === 'listItem';
    const shift = (editor: Editor, by: number) => {
      if (!inItem(editor)) return false;
      const attrs = editor.state.selection.$from.parent.attrs as { level: number };
      return editor.commands.updateAttributes('listItem', { level: Math.min(8, Math.max(0, attrs.level + by)) });
    };
    return {
      Enter: ({ editor }) => {
        if (!inItem(editor) || !editor.state.selection.empty) return false;
        const parent = editor.state.selection.$from.parent;
        if (parent.content.size === 0) return editor.commands.setNode('paragraph');
        const a = parent.attrs as { kind: string; level: number; number: number | null; align: string | null };
        const next = { kind: a.kind, level: a.level, number: a.kind === 'ordered' ? (a.number ?? 1) + 1 : null, checked: a.kind === 'task' ? false : null, align: a.align };
        return editor.chain().splitBlock().setNode('listItem', next).run();
      },
      Tab: ({ editor }) => shift(editor, 1),
      'Shift-Tab': ({ editor }) => shift(editor, -1),
      Backspace: ({ editor }) => {
        const { $from, empty } = editor.state.selection;
        if (!empty || $from.parent.type.name !== 'listItem' || $from.parentOffset !== 0) return false;
        return editor.commands.setNode('paragraph');
      },
    };
  },
});

const cellSpec = (name: 'tableCell' | 'tableHeader', tag: 'td' | 'th') =>
  Node.create({
    name,
    content: 'paragraph+',
    isolating: true,
    parseHTML: () => [{ tag }],
    renderHTML: ({ HTMLAttributes }) => [tag, HTMLAttributes, 0],
  });

export const TableCellNode = cellSpec('tableCell', 'td');
export const TableHeaderNode = cellSpec('tableHeader', 'th');
export const TableRowNode = Node.create({
  name: 'tableRow',
  content: '(tableHeader | tableCell)+',
  parseHTML: () => [{ tag: 'tr' }],
  renderHTML: () => ['tr', 0],
});
export const TableNode = Node.create({
  name: 'table',
  group: 'block',
  content: 'tableRow+',
  isolating: true,
  addAttributes: () => ({ columnWidths: { default: null, rendered: false } }),
  parseHTML: () => [{ tag: 'table' }],
  renderHTML: ({ HTMLAttributes }) => ['table', mergeAttributes(HTMLAttributes, { class: 'ni-table' }), ['tbody', 0]],
});

export interface AttachmentResolver {
  /** An object URL for an attachment's bytes, or undefined when missing. */
  url(sha: string): string | undefined;
}

export const ImageNode = Node.create<{ resolver?: AttachmentResolver }>({
  name: 'image',
  group: 'inline',
  inline: true,
  atom: true,
  draggable: true,
  addOptions: () => ({}),
  addAttributes: () => ({
    sha: { default: '' },
    name: { default: '' },
    mime: { default: 'image/png' },
    width: { default: null },
  }),
  // Pasted <img> elements are never parsed: an image is always an attachment of the note, never a remote URL.
  parseHTML: () => [],
  renderHTML: ({ HTMLAttributes }) => ['img', { alt: HTMLAttributes.name, 'data-sha': HTMLAttributes.sha }],
  addNodeView() {
    return ({ node }) => {
      const img = document.createElement('img');
      img.className = 'ni-image';
      img.alt = String(node.attrs.name ?? '');
      const src = this.options.resolver?.url(String(node.attrs.sha));
      if (src) img.src = src;
      if (node.attrs.width) img.style.width = `${Number(node.attrs.width)}px`;
      return { dom: img };
    };
  },
});

export const AttachmentNode = Node.create<{ resolver?: AttachmentResolver }>({
  name: 'attachment',
  group: 'inline',
  inline: true,
  atom: true,
  addOptions: () => ({}),
  addAttributes: () => ({ sha: { default: '' }, name: { default: '' }, mime: { default: 'application/octet-stream' } }),
  parseHTML: () => [],
  renderHTML: ({ HTMLAttributes }) => ['span', { class: 'ni-attachment', 'data-sha': HTMLAttributes.sha }, String(HTMLAttributes.name)],
  addNodeView() {
    return ({ node }) => {
      const a = document.createElement('a');
      a.className = 'ni-attachment';
      a.textContent = `📎 ${String(node.attrs.name)}`;
      const src = this.options.resolver?.url(String(node.attrs.sha));
      if (src) {
        a.href = src;
        a.download = String(node.attrs.name);
      }
      return { dom: a };
    };
  },
});

export const HardBreakNode = Node.create({
  name: 'hardBreak',
  group: 'inline',
  inline: true,
  selectable: false,
  parseHTML: () => [{ tag: 'br' }],
  renderHTML: () => ['br'],
  addKeyboardShortcuts: () => ({ 'Shift-Enter': ({ editor }) => editor.commands.setHardBreak() }),
  addCommands: () => ({
    setHardBreak:
      () =>
      ({ commands }) =>
        commands.insertContent({ type: 'hardBreak' }),
  }),
});

declare module '@tiptap/core' {
  interface Commands<ReturnType> {
    hardBreak: { setHardBreak: () => ReturnType };
  }
}

const simpleMark = (name: string, tags: string[], shortcut?: string, style?: string) =>
  Mark.create({
    name,
    parseHTML: () => [...tags.map((tag) => ({ tag })), ...(style ? [{ style }] : [])],
    renderHTML: ({ HTMLAttributes }) => [tags[0]!, HTMLAttributes, 0],
    addKeyboardShortcuts() {
      return shortcut ? { [shortcut]: () => this.editor.commands.toggleMark(name) } : {};
    },
  });

export const BoldMark = simpleMark('bold', ['strong', 'b'], 'Mod-b', 'font-weight=bold');
export const ItalicMark = simpleMark('italic', ['em', 'i'], 'Mod-i', 'font-style=italic');
export const UnderlineMark = simpleMark('underline', ['u'], 'Mod-u');
export const StrikeMark = simpleMark('strike', ['s', 'del', 'strike'], 'Mod-Shift-x');
export const CodeMark = simpleMark('code', ['code'], 'Mod-e');

export const LinkMark = Mark.create({
  name: 'link',
  inclusive: false,
  addAttributes: () => ({ href: { default: null } }),
  parseHTML: () => [
    {
      tag: 'a[href]',
      getAttrs: (el) => {
        const href = (el as HTMLElement).getAttribute('href') ?? '';
        return isAllowedLink(href) ? { href } : false;
      },
    },
  ],
  renderHTML: ({ HTMLAttributes }) => {
    const href = String(HTMLAttributes.href ?? '');
    return ['a', { href: isAllowedLink(href) ? href : null, rel: 'noopener noreferrer nofollow', target: href.startsWith('noteit:') ? null : '_blank' }, 0];
  },
});

const colorMark = (name: 'textColor' | 'highlight', tag: string, cssProp: string) =>
  Mark.create({
    name,
    addAttributes: () => ({ color: { default: '#000000' } }),
    parseHTML: () => [
      {
        tag: `${tag}[data-${name}]`,
        getAttrs: (el) => {
          const color = (el as HTMLElement).getAttribute(`data-${name}`) ?? '';
          return /^#[0-9A-Fa-f]{6}$/.test(color) ? { color } : false;
        },
      },
    ],
    renderHTML: ({ HTMLAttributes }) => {
      const color = /^#[0-9A-Fa-f]{6}$/.test(String(HTMLAttributes.color)) ? String(HTMLAttributes.color) : '#000000';
      return [tag, { [`data-${name}`]: color, style: `${cssProp}: ${color}` }, 0];
    },
  });

export const TextColorMark = colorMark('textColor', 'span', 'color');
export const HighlightMark = colorMark('highlight', 'mark', 'background-color');

export const FontSizeMark = Mark.create({
  name: 'fontSize',
  addAttributes: () => ({ delta: { default: 0 } }),
  parseHTML: () => [{ tag: 'span[data-font-delta]', getAttrs: (el) => ({ delta: Number((el as HTMLElement).dataset.fontDelta ?? 0) }) }],
  renderHTML: ({ HTMLAttributes }) => {
    const delta = Math.trunc(Number(HTMLAttributes.delta) || 0);
    return ['span', { 'data-font-delta': String(delta), style: `font-size: calc(1em + ${delta}px)` }, 0];
  },
});

export const BlockShortcuts = Extension.create({
  name: 'noteitShortcuts',
  addProseMirrorPlugins: () => [history()],
  addKeyboardShortcuts() {
    const run = (cmd: typeof undo) => () => cmd(this.editor.state, this.editor.view.dispatch);
    return {
      'Mod-z': run(undo),
      'Shift-Mod-z': run(redo),
      'Mod-y': run(redo),
      'Mod-Alt-1': () => this.editor.commands.setNode('heading', { level: 1 }),
      'Mod-Alt-2': () => this.editor.commands.setNode('heading', { level: 2 }),
      'Mod-Alt-3': () => this.editor.commands.setNode('heading', { level: 3 }),
      'Mod-Alt-0': () => this.editor.commands.setNode('paragraph'),
    };
  },
});

export function noteItExtensions(opts: { resolver?: AttachmentResolver } = {}): AnyExtension[] {
  return [
    DocNodeExt,
    TextNode,
    ParagraphNode,
    HeadingNode,
    CodeBlockNode,
    BlockquoteNode,
    HorizontalRuleNode,
    ListItemNode,
    TableNode,
    TableRowNode,
    TableHeaderNode,
    TableCellNode,
    ImageNode.configure(opts),
    AttachmentNode.configure(opts),
    HardBreakNode,
    BoldMark,
    ItalicMark,
    UnderlineMark,
    StrikeMark,
    CodeMark,
    LinkMark,
    TextColorMark,
    HighlightMark,
    FontSizeMark,
    BlockShortcuts,
  ];
}

export { toEditorJSON, fromEditorJSON } from './convert.js';
