import { Extension, Mark, mergeAttributes, Node, type AnyExtension, type Editor } from '@tiptap/core';
import { closeHistory, history, redo, undo } from '@tiptap/pm/history';
import { Plugin, TextSelection } from '@tiptap/pm/state';
import type { EditorView } from '@tiptap/pm/view';
import { WIKI_LINK_TRIGGER } from '../linking.js';
import { dateTokenRewrite, localFirstWeekday } from '../natural.js';
import { FindHighlight } from './find.js';
import { CodeHighlight } from './highlight.js';
import { SearchHighlight } from './searchHighlight.js';
import { adjustFontSize, clearFormatting, setAlignment } from './format.js';
import { codeLanguageId } from './languages.js';
import { safeAlign, safeBlobUrl, safeColor, safeHref, safeInt, safeLanguage, safePositive } from './safe.js';

const BULLETS = ['•', '◦', '▪'];
const safeKind = (v: unknown): 'bullet' | 'ordered' | 'task' => (v === 'ordered' || v === 'task' ? v : 'bullet');

const alignAttr = {
  align: {
    default: null,
    parseHTML: (el: HTMLElement) => safeAlign(el.style.textAlign),
    renderHTML: (a: Record<string, unknown>) => {
      const align = safeAlign(a.align);
      return align ? { style: `text-align: ${align}` } : {};
    },
  },
};
const indentAttr = {
  indent: {
    default: null,
    parseHTML: (el: HTMLElement) => safeInt(el.dataset.indent, 0, 8),
    renderHTML: (a: Record<string, unknown>) => {
      const indent = safeInt(a.indent, 0, 8);
      return indent ? { 'data-indent': String(indent), style: `margin-left: ${indent * 24}px` } : {};
    },
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
  renderHTML: ({ node, HTMLAttributes }) => [`h${safeInt(node.attrs.level, 1, 3) ?? 1}`, HTMLAttributes, 0],
});

export const CodeBlockNode = Node.create({
  name: 'codeBlock',
  group: 'block',
  content: 'inline*',
  marks: 'bold italic underline strike link textColor highlight fontSize',
  whitespace: 'pre',
  defining: true,
  addAttributes: () => ({ ...alignAttr, language: { default: null, parseHTML: (el) => safeLanguage(el.dataset.language), renderHTML: (a) => (safeLanguage(a.language) ? { 'data-language': safeLanguage(a.language) } : {}) } }),
  parseHTML: () => [{ tag: 'pre', preserveWhitespace: 'full' }],
  renderHTML: ({ HTMLAttributes }) => ['pre', mergeAttributes(HTMLAttributes, { class: 'ni-code' }), 0],
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
    kind: { default: 'bullet', parseHTML: (el) => safeKind(el.dataset.kind), renderHTML: (a) => ({ 'data-kind': safeKind(a.kind) }) },
    level: { default: 0, parseHTML: (el) => safeInt(el.dataset.level, 0, 8) ?? 0, renderHTML: (a) => ({ 'data-level': String(safeInt(a.level, 0, 8) ?? 0) }) },
    number: { default: null, parseHTML: (el) => safeInt(el.dataset.number, -1e9, 1e9), renderHTML: (a) => (safeInt(a.number, -1e9, 1e9) != null ? { 'data-number': String(safeInt(a.number, -1e9, 1e9)) } : {}) },
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
        const a = { kind: safeKind(n.attrs.kind), level: safeInt(n.attrs.level, 0, 8) ?? 0, number: safeInt(n.attrs.number, -1e9, 1e9), checked: n.attrs.checked === true };
        dom.className = `ni-li ni-li-${a.kind}${a.checked ? ' is-checked' : ''}`;
        dom.dataset.level = String(a.level);
        dom.style.paddingLeft = `${a.level * 24}px`;
        content.style.textAlign = safeAlign(n.attrs.align) ?? '';
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
  addKeyboardShortcuts() {
    const inItem = (editor: Editor) => editor.state.selection.$from.parent.type.name === 'listItem';
    return {
      Enter: ({ editor }) => {
        if (!inItem(editor) || !editor.state.selection.empty) return false;
        const parent = editor.state.selection.$from.parent;
        if (parent.content.size === 0) return editor.commands.setNode('paragraph');
        const a = parent.attrs as { kind: string; level: number; number: number | null; align: string | null };
        const next = { kind: a.kind, level: a.level, number: a.kind === 'ordered' ? (a.number ?? 1) + 1 : null, checked: a.kind === 'task' ? false : null, align: a.align };
        return editor.chain().splitBlock().setNode('listItem', next).run();
      },
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
  renderHTML: ({ HTMLAttributes }) => ['img', { alt: String(HTMLAttributes.name ?? ''), 'data-sha': /^[0-9a-f]{64}$/.test(String(HTMLAttributes.sha)) ? HTMLAttributes.sha : null }],
  addNodeView() {
    return ({ node }) => {
      const img = document.createElement('img');
      img.className = 'ni-image';
      img.alt = String(node.attrs.name ?? '');
      const src = safeBlobUrl(this.options.resolver?.url(String(node.attrs.sha)));
      if (src) img.src = src;
      const width = safePositive(node.attrs.width, 10_000);
      if (width) img.style.width = `${width}px`;
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
      const src = safeBlobUrl(this.options.resolver?.url(String(node.attrs.sha)));
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
// Inline code is ⇧⌘E, as on the Mac, where ⌘E is Use Selection for Find.
export const CodeMark = simpleMark('code', ['code']);

export const LinkMark = Mark.create({
  name: 'link',
  inclusive: false,
  addAttributes: () => ({ href: { default: null } }),
  parseHTML: () => [
    {
      tag: 'a[href]',
      getAttrs: (el) => {
        const href = safeHref((el as HTMLElement).getAttribute('href'));
        return href ? { href } : false;
      },
    },
  ],
  renderHTML: ({ HTMLAttributes }) => {
    const href = safeHref(HTMLAttributes.href);
    return ['a', { href, rel: 'noopener noreferrer nofollow', target: href && !href.startsWith('noteit:') ? '_blank' : null }, 0];
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
          const color = safeColor((el as HTMLElement).getAttribute(`data-${name}`));
          return color ? { color } : false;
        },
      },
    ],
    renderHTML: ({ HTMLAttributes }) => {
      const color = safeColor(HTMLAttributes.color);
      return color ? [tag, { [`data-${name}`]: color, style: `${cssProp}: ${color}` }, 0] : [tag, {}, 0];
    },
  });

export const TextColorMark = colorMark('textColor', 'span', 'color');
export const HighlightMark = colorMark('highlight', 'mark', 'background-color');

export const FontSizeMark = Mark.create({
  name: 'fontSize',
  addAttributes: () => ({ delta: { default: 0 } }),
  parseHTML: () => [{ tag: 'span[data-font-delta]', getAttrs: (el) => ({ delta: safeInt((el as HTMLElement).dataset.fontDelta, -88, 88) ?? 0 }) }],
  renderHTML: ({ HTMLAttributes }) => {
    const delta = safeInt(HTMLAttributes.delta, -88, 88) ?? 0;
    return ['span', { 'data-font-delta': String(delta), style: `font-size: calc(1em + ${delta}px)` }, 0];
  },
});

/** Turns the line into a list item of `kind`, or back into body text when it already is one. */
function setList(editor: Editor, kind: 'bullet' | 'ordered' | 'task'): boolean {
  if (editor.isActive('listItem', { kind })) return editor.commands.setNode('paragraph');
  return editor.commands.setNode('listItem', { kind, level: 0, number: kind === 'ordered' ? 1 : null, checked: kind === 'task' ? false : null });
}

/** ⌘] / ⌘[: a list item's level, else the paragraph's indent (0…8). */
function shiftLevel(editor: Editor, by: number): boolean {
  const node = editor.state.selection.$from.parent;
  if (node.type.name === 'listItem') return editor.commands.updateAttributes('listItem', { level: Math.min(8, Math.max(0, (node.attrs.level ?? 0) + by)) });
  if (node.type.name === 'paragraph' || node.type.name === 'heading') {
    const indent = Math.min(8, Math.max(0, (node.attrs.indent ?? 0) + by));
    return editor.commands.updateAttributes(node.type.name, { indent: indent || null });
  }
  return false;
}

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
      // The rest of native's Format menu (docs/keyboard-shortcuts.md); ⌘ is Ctrl off a Mac.
      'Mod-Alt-4': () => this.editor.commands.setNode('codeBlock'),
      'Mod-Alt-5': () => this.editor.chain().setNode('paragraph').wrapIn('blockquote').run(),
      'Shift-Mod-8': () => setList(this.editor, 'bullet'),
      'Shift-Mod-7': () => setList(this.editor, 'ordered'),
      'Shift-Mod-l': () => setList(this.editor, 'task'),
      'Shift-Mod-u': () => {
        const { $from } = this.editor.state.selection;
        const node = $from.parent;
        if (node.type.name !== 'listItem' || node.attrs.kind !== 'task') return false;
        return this.editor.commands.updateAttributes('listItem', { checked: node.attrs.checked !== true });
      },
      'Shift-Mod-e': () => this.editor.commands.toggleMark('code'),
      'Shift-Mod-h': () =>
        this.editor.isActive('highlight') ? this.editor.commands.unsetMark('highlight') : this.editor.commands.setMark('highlight', { color: '#FFED8C' }),
      'Shift-Mod-Alt-d': () => this.editor.chain().insertContent({ type: 'horizontalRule' }).run(),
      'Mod-]': () => shiftLevel(this.editor, 1),
      'Mod-[': () => shiftLevel(this.editor, -1),
      // Format › Font and Text (native FormatCommand): ⌘+ (also ⇧⌘=) ⌘−, ⇧⌘{ ⇧⌘| ⇧⌘}, ⌥⌘\.
      'Mod-=': () => adjustFontSize(this.editor, 1),
      'Shift-Mod-=': () => adjustFontSize(this.editor, 1),
      'Mod-+': () => adjustFontSize(this.editor, 1),
      'Mod--': () => adjustFontSize(this.editor, -1),
      'Shift-Mod-[': () => setAlignment(this.editor, 'left'),
      'Mod-{': () => setAlignment(this.editor, 'left'),
      'Shift-Mod-\\': () => setAlignment(this.editor, 'center'),
      'Mod-|': () => setAlignment(this.editor, 'center'),
      'Shift-Mod-]': () => setAlignment(this.editor, 'right'),
      'Mod-}': () => setAlignment(this.editor, 'right'),
      'Mod-Alt-\\': () => clearFormatting(this.editor),
    };
  },
});

// MARK: Markdown as you type (native MarkdownShortcuts.swift)

const BOLD = /\*\*([^*\s](?:[^*\n]*[^*\s])?)\*$/;
const ITALIC = /(?:^|(?<=[^*\w]))\*([^*\s](?:[^*\n]*[^*\s])?)$/;
const CODE = /`([^`\n]*[^`\s][^`\n]*)$/;
const STRIKE = /~~([^~\s](?:[^~\n]*[^~\s])?)~$/;
const NUMBERED = /^(\d{1,3})[.)]$/;
const FENCE = /^```([A-Za-z0-9+#_.-]*)$/;
const DIVIDERS = ['---', '***', '___', '—-', '—', '–-'];

/** ```` ``` ```` or ```` ```swift ````: a fence and its language (null = automatic); undefined when not a fence or unknown. */
function codeFence(prefix: string): string | null | undefined {
  const m = FENCE.exec(prefix);
  if (!m) return undefined;
  if (!m[1]) return null;
  return codeLanguageId(m[1]);
}

/** Applies a conversion as its own undo step after the typed trigger, so one ⌘Z gives back the literal Markdown. */
function convertAfterTyping(view: EditorView, from: number, to: number, text: string, convert: () => boolean): boolean {
  view.dispatch(view.state.tr.insertText(text, from, to));
  view.dispatch(closeHistory(view.state.tr));
  return convert();
}

/** Turns `[[inner]` + `]` into a note link; the host resolves titles (native handleWikiLinkTrigger). */
export type WikiLinkResolver = (inner: string) => { href: string; text: string } | undefined;

function wikiLinkTyped(view: EditorView, from: number, prefix: string, start: number, resolve: WikiLinkResolver | undefined): boolean {
  const m = resolve ? WIKI_LINK_TRIGGER.exec(prefix) : null;
  const link = m ? resolve!(m[1]!) : undefined;
  const linkType = view.state.schema.marks.link;
  if (!m || !link || !linkType) return false;
  const at = start + m.index;
  return convertAfterTyping(view, from, from, ']', () => {
    const tr = view.state.tr.insertText(link.text, at, from + 1);
    tr.addMark(at, at + link.text.length, linkType.create({ href: link.href }));
    tr.setStoredMarks([]);
    view.dispatch(tr);
    return true;
  });
}

/** `@due(fri)` → `@due(2026-10-23)` as its `)` is typed (native DateTokenAutoFormat); one ⌘Z puts back the words. */
function dateTokenTyped(view: EditorView, from: number, prefix: string, start: number): boolean {
  if (!prefix.includes('@')) return false;
  const r = dateTokenRewrite(`${prefix})`, new Date(), { firstWeekday: localFirstWeekday() });
  if (!r) return false;
  return convertAfterTyping(view, from, from, ')', () => {
    view.dispatch(view.state.tr.insertText(r.replacement, start + r.start, start + r.end));
    return true;
  });
}

function handleTyped(editor: Editor, view: EditorView, from: number, to: number, text: string, resolve?: WikiLinkResolver): boolean {
  if (text.length !== 1 || from !== to || !editor.isEditable) return false;
  const { $from } = view.state.selection;
  const parent = $from.parent;
  if (parent.type.name === 'codeBlock' || !parent.isTextblock) return false;
  const inCode = (view.state.storedMarks ?? $from.marks()).some((m) => m.type.name === 'code');
  if (inCode && text !== '`') return false;
  const prefix = parent.textBetween(0, $from.parentOffset, undefined, '￼');
  const start = $from.start();

  if (text === ' ') return blockShortcut(editor, view, prefix, from, text);
  if (text === ']') return !inCode && wikiLinkTyped(view, from, prefix, start, resolve);
  if (text === ')' && !inCode) return dateTokenTyped(view, from, prefix, start);

  const inline: Record<string, { re: RegExp; mark: string; open: number; typedClose: number }> = {
    '*': { re: BOLD, mark: 'bold', open: 2, typedClose: 1 },
    '`': { re: CODE, mark: 'code', open: 1, typedClose: 0 },
    '~': { re: STRIKE, mark: 'strike', open: 2, typedClose: 1 },
  };
  let rule = inline[text];
  let m = rule ? rule.re.exec(prefix) : null;
  if (text === '*' && !m) {
    rule = { re: ITALIC, mark: 'italic', open: 1, typedClose: 0 };
    m = ITALIC.exec(prefix);
  }
  if (!rule || !m) return false;
  const markType = view.state.schema.marks[rule.mark];
  if (!markType) return false;
  const contentFrom = start + m.index + m[0].length - rule.typedClose - m[1]!.length;
  const contentTo = contentFrom + m[1]!.length;
  const { open, typedClose } = rule;
  return convertAfterTyping(view, from, to, text, () => {
    const tr = view.state.tr;
    tr.delete(contentTo, contentTo + typedClose + 1);
    tr.addMark(contentFrom, contentTo, markType.create());
    tr.delete(contentFrom - open, contentFrom);
    tr.setStoredMarks((view.state.storedMarks ?? $from.marks()).filter((x) => x.type !== markType));
    view.dispatch(tr);
    return true;
  });
}

function blockShortcut(editor: Editor, view: EditorView, prefix: string, at: number, text: string): boolean {
  const { $from } = view.state.selection;
  if ($from.parent.type.name === 'listItem') return false;
  const fence = codeFence(prefix);
  const numbered = NUMBERED.exec(prefix);
  type Target = { type: string; attrs?: Record<string, unknown>; wrap?: boolean };
  let target: Target | undefined;
  if (fence !== undefined) target = { type: 'codeBlock', attrs: { language: fence } };
  else if (prefix === '#' || prefix === '##' || prefix === '###') target = { type: 'heading', attrs: { level: prefix.length } };
  else if (prefix === '>') target = { type: 'blockquote', wrap: true };
  else if (['-', '*', '+', '•'].includes(prefix)) target = { type: 'listItem', attrs: { kind: 'bullet', level: 0, number: null, checked: null } };
  else if (['[]', '[ ]', '[x]', '[X]'].includes(prefix)) target = { type: 'listItem', attrs: { kind: 'task', level: 0, number: null, checked: prefix.toLowerCase() === '[x]' } };
  else if (numbered) target = { type: 'listItem', attrs: { kind: 'ordered', level: 0, number: Number(numbered[1]), checked: null } };
  if (!target) return false;
  const blockStart = $from.start();
  // Only where that block can go (not inside a table cell or a quote's quote).
  const probe = target.wrap ? editor.can().wrapIn('blockquote') : editor.can().chain().setTextSelection(blockStart).setNode(target.type, target.attrs ?? {}).run();
  if (!probe) return false;
  const t = target;
  return convertAfterTyping(view, at, at, text, () => {
    const chain = editor.chain().deleteRange({ from: blockStart, to: blockStart + prefix.length + 1 });
    if (t.wrap) return chain.wrapIn('blockquote').run();
    return chain.setNode(t.type, t.attrs ?? {}).run();
  });
}

/** Return after ```` ``` ```` (any info string) makes a code block; after `---`, `***` or `___` a divider. */
function fenceOrDivider(editor: Editor): boolean {
  const { $from, empty } = editor.state.selection;
  const parent = $from.parent;
  if (!empty || parent.type.name !== 'paragraph' || $from.depth !== 1 || $from.parentOffset !== parent.content.size) return false;
  const trimmed = parent.textContent.trim();
  const from = $from.before(1);
  const to = $from.after(1);
  if (trimmed.startsWith('```')) {
    const language = codeLanguageId(trimmed.slice(3)) ?? null;
    return editor.chain().insertContentAt({ from, to }, { type: 'codeBlock', attrs: { language } }).setTextSelection(from + 1).run();
  }
  if (DIVIDERS.includes(trimmed)) {
    const followed = to < editor.state.doc.content.size;
    if (followed) return editor.chain().insertContentAt({ from, to }, { type: 'horizontalRule' }).setTextSelection(from + 2).run();
    return editor.chain().insertContentAt({ from, to }, [{ type: 'horizontalRule' }, { type: 'paragraph' }]).setTextSelection(from + 2).run();
  }
  return false;
}

// MARK: Tab (native insertTab / insertBacktab)

const isCell = (name: string) => name === 'tableCell' || name === 'tableHeader';

/** Tab / ⇧Tab in a table: the next or previous cell, its text selected; Tab in the last cell adds a row. */
function moveToAdjacentCell(editor: Editor, forward: boolean): boolean {
  const { $from } = editor.state.selection;
  let d = $from.depth;
  while (d > 0 && !isCell($from.node(d).type.name)) d--;
  if (d < 3) return false;
  const table = $from.node(d - 2);
  const tableStart = $from.start(d - 2);
  const cells: { pos: number; size: number }[] = [];
  table.descendants((node, pos) => {
    if (!isCell(node.type.name)) return true;
    cells.push({ pos: tableStart + pos, size: node.nodeSize });
    return false;
  });
  const index = cells.findIndex((c) => c.pos === $from.before(d));
  const target = index + (forward ? 1 : -1);
  if (target < 0) return true;
  if (target >= cells.length) {
    const row = $from.node(d - 1);
    const after = $from.after(d - 1);
    const cell = { type: 'tableCell', content: [{ type: 'paragraph' }] };
    return editor.chain().insertContentAt(after, { type: 'tableRow', content: Array.from({ length: row.childCount }, () => cell) }).setTextSelection(after + 3).run();
  }
  const c = cells[target]!;
  const { tr } = editor.state;
  tr.setSelection(TextSelection.create(tr.doc, c.pos + 2, c.pos + c.size - 2));
  editor.view.dispatch(tr.scrollIntoView());
  return true;
}

/** Tab / ⇧Tab: a table moves between cells; selected list items change level; otherwise Tab types a tab. */
function handleTab(editor: Editor, forward: boolean): boolean {
  if (!editor.isEditable) return false;
  const { state } = editor;
  const { $from, from, to } = state.selection;
  for (let d = $from.depth; d > 0; d--) if (isCell($from.node(d).type.name)) return moveToAdjacentCell(editor, forward);
  const items: { pos: number; level: number }[] = [];
  state.doc.nodesBetween(from, to, (node, pos) => {
    if (node.type.name === 'listItem') items.push({ pos, level: Number(node.attrs.level ?? 0) });
    return !node.isTextblock;
  });
  if (items.length) {
    const tr = state.tr;
    for (const item of items) tr.setNodeAttribute(item.pos, 'level', Math.min(8, Math.max(0, item.level + (forward ? 1 : -1))));
    editor.view.dispatch(tr);
    return true;
  }
  if (forward) return editor.commands.insertContent('\t');
  // ⇧Tab with nothing to outdent keeps the focus in the note rather than jumping to a checkbox or button.
  return true;
}

/** Inserts a 2×2 table (a header row and a body row) and puts the caret in its first cell. */
export function insertTable(editor: Editor): boolean {
  const { $from } = editor.state.selection;
  if ($from.depth < 1) return false;
  const top = $from.node(1);
  const replace = top.type.name === 'paragraph' && top.content.size === 0;
  const at = replace ? $from.before(1) : $from.after(1);
  const cell = (type: string) => ({ type, content: [{ type: 'paragraph' }] });
  const table = { type: 'table', content: [{ type: 'tableRow', content: [cell('tableHeader'), cell('tableHeader')] }, { type: 'tableRow', content: [cell('tableCell'), cell('tableCell')] }] };
  return editor
    .chain()
    .focus()
    .insertContentAt(replace ? { from: at, to: $from.after(1) } : at, table)
    .setTextSelection(at + 4)
    .run();
}

export const MarkdownShortcuts = Extension.create<{ wikiLink?: WikiLinkResolver }>({
  name: 'noteitMarkdownShortcuts',
  priority: 200,
  addOptions: () => ({}),
  addProseMirrorPlugins() {
    const editor = this.editor;
    const options = this.options;
    return [new Plugin({ props: { handleTextInput: (view, from, to, text) => handleTyped(editor, view, from, to, text, options.wikiLink) } })];
  },
  addKeyboardShortcuts() {
    return {
      Enter: ({ editor }) => fenceOrDivider(editor),
      Tab: ({ editor }) => handleTab(editor, true),
      'Shift-Tab': ({ editor }) => handleTab(editor, false),
    };
  },
});

export function noteItExtensions(opts: { resolver?: AttachmentResolver; wikiLink?: WikiLinkResolver } = {}): AnyExtension[] {
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
    ImageNode.configure({ resolver: opts.resolver }),
    AttachmentNode.configure({ resolver: opts.resolver }),
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
    MarkdownShortcuts.configure({ wikiLink: opts.wikiLink }),
    FindHighlight,
    CodeHighlight,
    SearchHighlight,
  ];
}

export { toEditorJSON, fromEditorJSON, prepareForEditor } from './convert.js';
export * from './find.js';
export * from './highlight.js';
export * from './format.js';
export * from './searchHighlight.js';
export * from './tableRows.js';
export * from './languages.js';
export * from './safe.js';
