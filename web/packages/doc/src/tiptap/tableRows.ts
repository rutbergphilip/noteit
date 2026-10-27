/**
 * Format › Table › Add Row Above / Add Row Below / Delete Row (native TextFormatter addTableRow / deleteTableRow):
 * new rows are body rows with the table's column count; there's no row above the header; deleting the header row
 * makes the next row the header, and deleting the only row deletes the table.
 */
import type { Editor } from '@tiptap/core';
import type { Node as PMNode } from '@tiptap/pm/model';
import { TextSelection } from '@tiptap/pm/state';

/** The table, row and their positions around the caret, if it's in a table. */
function tableAt(editor: Editor): { table: PMNode; tablePos: number; rowIndex: number; rowPos: number } | undefined {
  const { $from } = editor.state.selection;
  for (let d = $from.depth; d > 0; d--) {
    if ($from.node(d).type.name !== 'tableRow' || d < 2) continue;
    return { table: $from.node(d - 1), tablePos: $from.before(d - 1), rowIndex: $from.index(d - 1), rowPos: $from.before(d) };
  }
  return undefined;
}

export function inTable(editor: Editor): boolean {
  return !!tableAt(editor);
}

export function addTableRow(editor: Editor, below: boolean): boolean {
  const at = tableAt(editor);
  if (!at || !editor.isEditable || (!below && at.rowIndex === 0)) return false;
  const { schema } = editor.state;
  const columns = Math.max(...Array.from({ length: at.table.childCount }, (_, i) => at.table.child(i).childCount));
  const cells = Array.from({ length: columns }, () => schema.nodes.tableCell!.create(null, schema.nodes.paragraph!.create()));
  const row = schema.nodes.tableRow!.create(null, cells);
  const insertAt = below ? at.rowPos + at.table.child(at.rowIndex).nodeSize : at.rowPos;
  const tr = editor.state.tr.insert(insertAt, row);
  tr.setSelection(TextSelection.create(tr.doc, insertAt + 3));
  editor.view.dispatch(tr.scrollIntoView());
  return true;
}

export function deleteTableRow(editor: Editor): boolean {
  const at = tableAt(editor);
  if (!at || !editor.isEditable) return false;
  const { schema } = editor.state;
  const tr = editor.state.tr;
  if (at.table.childCount <= 1) {
    tr.delete(at.tablePos, at.tablePos + at.table.nodeSize);
    if (tr.doc.childCount === 0) tr.insert(0, schema.nodes.paragraph!.create());
    tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(at.tablePos, tr.doc.content.size))));
    editor.view.dispatch(tr.scrollIntoView());
    return true;
  }
  const row = at.table.child(at.rowIndex);
  tr.delete(at.rowPos, at.rowPos + row.nodeSize);
  // The row that moves up into the header takes header cells.
  if (at.rowIndex === 0 && row.firstChild?.type.name === 'tableHeader') {
    const next = tr.doc.nodeAt(at.rowPos);
    next?.forEach((cell, offset) => {
      if (cell.type.name === 'tableCell') tr.setNodeMarkup(at.rowPos + 1 + offset, schema.nodes.tableHeader!);
    });
  }
  const caretRow = Math.min(at.rowPos, at.tablePos + tr.doc.nodeAt(at.tablePos)!.nodeSize - 2);
  tr.setSelection(TextSelection.near(tr.doc.resolve(caretRow + 1)));
  editor.view.dispatch(tr.scrollIntoView());
  return true;
}
