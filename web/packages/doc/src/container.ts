import { type BodyContainer, BODY_FORMAT_LOCKED_V1 } from './schema.js';
import { sha256HexSync } from './sha256.js';
import { type Validation, validateContainer } from './validate.js';

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
const RTFD_MAGIC = [0x72, 0x74, 0x66, 0x64, 0, 0, 0, 0];

export type DecodedBody =
  | { kind: 'doc'; container: BodyContainer; validation: Validation }
  | { kind: 'legacyRtfd'; bytes: Uint8Array }
  | { kind: 'locked' }
  | { kind: 'invalid'; reason: string };

/** UTF-8 JSON; unknown top-level keys survive because they are part of `c`. */
export function encodeBody(c: BodyContainer): Uint8Array {
  return encoder.encode(JSON.stringify(c));
}

export function decodeBody(bytes: Uint8Array, bodyFormat: string | undefined): DecodedBody {
  if (bodyFormat === BODY_FORMAT_LOCKED_V1) return { kind: 'locked' };
  if (bodyFormat === undefined || RTFD_MAGIC.every((b, i) => bytes[i] === b)) return { kind: 'legacyRtfd', bytes };
  let parsed: unknown;
  try {
    parsed = JSON.parse(decoder.decode(bytes));
  } catch {
    return { kind: 'invalid', reason: 'not JSON' };
  }
  if (!parsed || typeof parsed !== 'object' || (parsed as { format?: unknown }).format !== 'noteit-doc') {
    return { kind: 'invalid', reason: 'not a noteit-doc container' };
  }
  const container = parsed as BodyContainer;
  return { kind: 'doc', container, validation: validateContainer(container) };
}

/** Adds an attachment under its content hash and returns the key. */
export function addAttachment(c: BodyContainer, data: Uint8Array, name: string, mime: string): string {
  const sha = sha256HexSync(data);
  let bin = '';
  for (let i = 0; i < data.length; i += 0x8000) bin += String.fromCharCode(...data.subarray(i, i + 0x8000));
  c.attachments[sha] = { mime, name, data: btoa(bin) };
  return sha;
}

/** Drops attachments no node references any more. */
export function pruneAttachments(c: BodyContainer): void {
  const used = new Set<string>();
  const walk = (n: unknown): void => {
    if (!n || typeof n !== 'object') return;
    const node = n as { type?: string; attrs?: { sha?: string }; content?: unknown[] };
    if ((node.type === 'image' || node.type === 'attachment') && node.attrs?.sha) used.add(node.attrs.sha);
    node.content?.forEach(walk);
  };
  walk(c.doc);
  for (const key of Object.keys(c.attachments)) if (!used.has(key)) delete c.attachments[key];
}
