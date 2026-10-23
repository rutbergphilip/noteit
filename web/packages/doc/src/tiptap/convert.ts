import type { NoteItDoc } from '../schema.js';

type Json = { type?: string; attrs?: Record<string, unknown>; content?: Json[]; marks?: Json[]; text?: string };

/** ProseMirror JSON carries every attribute with its default (null); noteit-doc omits absent ones. */
function clean(node: Json): Json {
  const out: Json = { type: node.type };
  if (node.attrs) {
    const attrs: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(node.attrs)) {
      if (v === null || v === undefined) continue;
      if (k === 'indent' && v === 0) continue;
      attrs[k] = v;
    }
    if (node.type === 'listItem') {
      if (attrs.kind !== 'ordered') delete attrs.number;
      if (attrs.kind !== 'task') delete attrs.checked;
    }
    if (Object.keys(attrs).length > 0) out.attrs = attrs;
  }
  if (node.text !== undefined) out.text = node.text;
  if (node.marks && node.marks.length > 0) out.marks = node.marks.map(clean);
  if (node.content && node.content.length > 0) out.content = node.content.map(clean);
  else if (node.type === 'blockquote' || node.type === 'table' || node.type === 'tableRow' || node.type === 'tableCell' || node.type === 'tableHeader') {
    out.content = [];
  }
  return out;
}

export function fromEditorJSON(json: unknown): NoteItDoc {
  const doc = clean(json as Json) as unknown as NoteItDoc;
  if (!doc.content || doc.content.length === 0) doc.content = [{ type: 'paragraph' }];
  return doc;
}

/** noteit-doc is already ProseMirror-shaped; an empty doc still needs one block. */
export function toEditorJSON(doc: NoteItDoc): Record<string, unknown> {
  const copy = JSON.parse(JSON.stringify(doc)) as NoteItDoc;
  if (!copy.content || copy.content.length === 0) copy.content = [{ type: 'paragraph' }];
  return copy as unknown as Record<string, unknown>;
}
