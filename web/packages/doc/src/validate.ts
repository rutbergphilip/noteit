import { type BodyContainer, CURRENT_VERSION, isAllowedLink } from './schema.js';
import { sha256HexSync } from './sha256.js';

export type Validation = 'valid' | { readOnly: string };

const FONT_DELTA = 96 - 8;
const ALIGNS = new Set(['left', 'center', 'right', 'justify']);

class Failure extends Error {}
const fail = (reason: string): never => {
  throw new Failure(reason);
};

type Json = Record<string, unknown>;
const isObj = (v: unknown): v is Json => !!v && typeof v === 'object' && !Array.isArray(v);

function base64ToBytes(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function attrsOf(node: Json): Json {
  return isObj(node.attrs) ? node.attrs : {};
}

function checkAlign(a: Json): void {
  if (a.align !== undefined && a.align !== null && !ALIGNS.has(a.align as string)) fail('align');
}

function checkIndent(a: Json): void {
  if (a.indent === undefined || a.indent === null) return;
  if (!Number.isInteger(a.indent) || (a.indent as number) < 0 || (a.indent as number) > 8) fail('indent');
}

function checkWidth(w: unknown, reason: string): void {
  if (typeof w !== 'number' || !Number.isFinite(w) || w <= 0) fail(reason);
}

function checkName(name: unknown): void {
  if (typeof name !== 'string' || name.trim().length === 0) fail('attachment name');
}

function checkMark(mark: unknown): void {
  if (!isObj(mark)) return fail('mark');
  const a = attrsOf(mark);
  switch (mark.type) {
    case 'bold':
    case 'italic':
    case 'underline':
    case 'strike':
    case 'code':
      return;
    case 'link':
      if (typeof a.href !== 'string') fail('link');
      if (!isAllowedLink(a.href as string)) {
        fail(/^noteit:/i.test(a.href as string) ? 'noteit link host' : 'link scheme');
      }
      return;
    case 'textColor':
    case 'highlight':
      if (typeof a.color !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(a.color)) fail('color');
      return;
    case 'fontSize':
      if (!Number.isInteger(a.delta) || Math.abs(a.delta as number) > FONT_DELTA) fail('font size');
      return;
    default:
      fail('unknown mark');
  }
}

function checkInlines(content: unknown): void {
  if (content === undefined) return;
  if (!Array.isArray(content)) return fail('structure');
  for (const node of content) {
    if (!isObj(node)) return fail('structure');
    const a = attrsOf(node);
    switch (node.type) {
      case 'text':
        if (typeof node.text !== 'string') fail('structure');
        if (node.marks !== undefined) {
          if (!Array.isArray(node.marks)) fail('structure');
          for (const m of node.marks as unknown[]) checkMark(m);
        }
        break;
      case 'hardBreak':
        break;
      case 'image':
        if (typeof a.sha !== 'string' || typeof a.mime !== 'string') fail('structure');
        checkName(a.name);
        if (a.width !== undefined && a.width !== null) checkWidth(a.width, 'image width');
        break;
      case 'attachment':
        if (typeof a.sha !== 'string' || typeof a.mime !== 'string') fail('structure');
        checkName(a.name);
        break;
      default:
        fail('unknown node');
    }
  }
}

function checkParagraphs(content: unknown): void {
  if (!Array.isArray(content)) return fail('structure');
  for (const node of content) {
    if (!isObj(node)) return fail('structure');
    if (node.type !== 'paragraph') fail(isKnownBlock(node.type) ? 'nesting' : 'unknown node');
    checkBlock(node);
  }
}

const KNOWN_BLOCKS = new Set(['paragraph', 'heading', 'codeBlock', 'blockquote', 'horizontalRule', 'listItem', 'table']);
const isKnownBlock = (t: unknown) => KNOWN_BLOCKS.has(t as string);

function checkBlock(node: Json): void {
  const a = attrsOf(node);
  switch (node.type) {
    case 'paragraph':
      checkAlign(a);
      checkIndent(a);
      return checkInlines(node.content);
    case 'heading':
      if (a.level !== 1 && a.level !== 2 && a.level !== 3) fail('heading level');
      checkAlign(a);
      checkIndent(a);
      return checkInlines(node.content);
    case 'codeBlock':
      checkAlign(a);
      if (a.language !== undefined && a.language !== null && typeof a.language !== 'string') fail('structure');
      return checkInlines(node.content);
    case 'blockquote':
      checkIndent(a);
      return checkParagraphs(node.content);
    case 'horizontalRule':
      return;
    case 'listItem': {
      if (!['bullet', 'ordered', 'task'].includes(a.kind as string)) fail('list kind');
      if (!Number.isInteger(a.level) || (a.level as number) < 0 || (a.level as number) > 8) fail('list level');
      if (a.number !== undefined && a.number !== null && !Number.isInteger(a.number)) fail('structure');
      if (a.checked !== undefined && a.checked !== null && typeof a.checked !== 'boolean') fail('structure');
      checkAlign(a);
      return checkInlines(node.content);
    }
    case 'table': {
      if (!Array.isArray(node.content)) return fail('structure');
      let columns = 0;
      for (const row of node.content as unknown[]) {
        if (!isObj(row) || row.type !== 'tableRow' || !Array.isArray(row.content)) return fail('structure');
        columns = Math.max(columns, row.content.length);
        for (const cell of row.content as unknown[]) {
          if (!isObj(cell) || (cell.type !== 'tableCell' && cell.type !== 'tableHeader')) return fail('structure');
          checkParagraphs(cell.content);
        }
      }
      if (a.columnWidths !== undefined && a.columnWidths !== null) {
        if (!Array.isArray(a.columnWidths) || a.columnWidths.length !== columns) fail('column widths');
        for (const w of a.columnWidths as unknown[]) checkWidth(w, 'column widths');
      }
      return;
    }
    default:
      fail('unknown node');
  }
}

/** Whether a container can be edited; anything this build can't edit faithfully opens read-only (= Swift DocValidation). */
export function validateContainer(c: unknown): Validation {
  try {
    if (!isObj(c) || c.format !== 'noteit-doc') fail('format');
    const container = c as BodyContainer;
    if (!Number.isInteger(container.version)) fail('version');
    if (container.version > CURRENT_VERSION) fail('version');
    if (!isObj(container.attachments)) fail('attachments');
    for (const [key, att] of Object.entries(container.attachments)) {
      if (!isObj(att) || typeof att.data !== 'string') fail('attachments');
      if (sha256HexSync(base64ToBytes(att.data)) !== key) fail('attachment hash');
    }
    const doc = container.doc as unknown;
    if (!isObj(doc) || doc.type !== 'doc' || !Array.isArray(doc.content)) fail('structure');
    for (const block of (doc as Json).content as unknown[]) {
      if (!isObj(block)) fail('structure');
      checkBlock(block as Json);
    }
    return 'valid';
  } catch (e) {
    if (e instanceof Failure) return { readOnly: e.message };
    return { readOnly: String(e) };
  }
}
