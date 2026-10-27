/**
 * Bigger/Smaller (⌘+ ⌘−), alignment (⇧⌘{ ⇧⌘| ⇧⌘}) and Clear Formatting (⌥⌘\), writing the marks and attributes
 * native's TextFormatter produces through its DocConverter: a `fontSize` delta in points from the block's base size
 * (base + delta within 8–96), a block's `align`, and body paragraphs with only links left.
 */
import type { Editor } from '@tiptap/core';
import type { Node as PMNode } from '@tiptap/pm/model';
import type { Align } from '../schema.js';

/** Native's base sizes at the doc format's 14 pt body (EditorStyle.font(for:bodySize:), inline code monospaced at 14). */
export function baseFontSize(block: PMNode): number {
  if (block.type.name === 'codeBlock') return 13;
  if (block.type.name === 'heading') return block.attrs.level === 1 ? 26 : block.attrs.level === 2 ? 19 : 15.5;
  return 14;
}

/** The delta after one step of Bigger or Smaller, keeping the size within 8–96 pt (native adjustFontSize). */
export function steppedDelta(delta: number, base: number, by: number): number {
  return Math.round(Math.min(96, Math.max(8, base + delta + by)) - base);
}

/** ⌘+ / ⌘−: every run in the selection one point bigger or smaller; with no selection, what's typed next. */
export function adjustFontSize(editor: Editor, by: 1 | -1): boolean {
  const { state } = editor;
  const type = state.schema.marks.fontSize;
  if (!type || !editor.isEditable) return false;
  const { from, to, empty, $from } = state.selection;
  const tr = state.tr;
  if (empty) {
    const marks = state.storedMarks ?? $from.marks();
    const current = Number(marks.find((m) => m.type === type)?.attrs.delta ?? 0);
    const next = steppedDelta(current, baseFontSize($from.parent), by);
    tr.setStoredMarks(next ? type.create({ delta: next }).addToSet(marks) : type.removeFromSet(marks));
    editor.view.dispatch(tr);
    return true;
  }
  state.doc.nodesBetween(from, to, (node, pos, parent) => {
    if (!node.isText || !parent || !parent.type.allowsMarkType(type)) return;
    const start = Math.max(from, pos);
    const end = Math.min(to, pos + node.nodeSize);
    const current = Number(node.marks.find((m) => m.type === type)?.attrs.delta ?? 0);
    const next = steppedDelta(current, baseFontSize(parent), by);
    if (next) tr.addMark(start, end, type.create({ delta: next }));
    else tr.removeMark(start, end, type);
  });
  editor.view.dispatch(tr);
  return true;
}

/** Sets `align` on every block in the selection that has one (native setAlignment writes left, center or right). */
export function setAlignment(editor: Editor, align: Align): boolean {
  const { state } = editor;
  if (!editor.isEditable) return false;
  const { from, to } = state.selection;
  const tr = state.tr;
  state.doc.nodesBetween(from, to, (node, pos) => {
    if (node.isTextblock && 'align' in node.attrs) tr.setNodeAttribute(pos, 'align', align);
    return !node.isTextblock;
  });
  editor.view.dispatch(tr);
  return true;
}

/** The current block's alignment, for the toolbar (undefined is natural). */
export function currentAlignment(editor: Editor): Align | undefined {
  return (editor.state.selection.$from.parent.attrs.align as Align | null) ?? undefined;
}

const CLEARED = ['bold', 'italic', 'underline', 'strike', 'code', 'textColor', 'highlight', 'fontSize'];

/**
 * ⌥⌘\: the selection (or, with none, the lines it's in) loses every character format but links, and its lines
 * become plain body paragraphs (no heading, list, quote or code; natural alignment), as native clearFormatting does.
 */
export function clearFormatting(editor: Editor): boolean {
  const { state } = editor;
  if (!editor.isEditable) return false;
  const { from, to, empty, $from, $to } = state.selection;
  const paragraph = state.schema.nodes.paragraph!;
  const tr = state.tr;
  const rangeFrom = empty ? $from.start() : from;
  const rangeTo = empty ? $to.end() : to;
  for (const name of CLEARED) {
    const type = state.schema.marks[name];
    if (type) tr.removeMark(rangeFrom, rangeTo, type);
  }
  state.doc.nodesBetween(from, to, (node, pos) => {
    if (!node.isTextblock) return true;
    if (node.content.size === 0 && node.type === paragraph && !node.attrs.align) return false;
    const indent = node.type === paragraph || node.type.name === 'heading' ? (node.attrs.indent ?? null) : null;
    tr.setNodeMarkup(tr.mapping.map(pos), paragraph, { align: null, indent });
    return false;
  });
  tr.setStoredMarks([]);
  editor.view.dispatch(tr);
  // Quoted lines come out of their quote.
  if (editor.isActive('blockquote')) editor.commands.lift('blockquote');
  return true;
}
