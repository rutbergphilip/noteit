export type Uuid = string;
export type Align = 'left' | 'center' | 'right' | 'justify';

export type Mark =
  | { type: 'bold' | 'italic' | 'underline' | 'strike' | 'code' }
  | { type: 'link'; attrs: { href: string } }
  | { type: 'textColor'; attrs: { color: string } }
  | { type: 'highlight'; attrs: { color: string } }
  | { type: 'fontSize'; attrs: { delta: number } };

export type Inline =
  | { type: 'text'; text: string; marks?: Mark[] }
  | { type: 'hardBreak' }
  | { type: 'image'; attrs: { sha: string; name: string; mime: string; width?: number } }
  | { type: 'attachment'; attrs: { sha: string; name: string; mime: string } };

export interface ParagraphNode {
  type: 'paragraph';
  attrs?: { align?: Align; indent?: number };
  content?: Inline[];
}

export type Block =
  | ParagraphNode
  | { type: 'heading'; attrs: { level: 1 | 2 | 3; align?: Align; indent?: number }; content?: Inline[] }
  | { type: 'codeBlock'; attrs?: { align?: Align; language?: string }; content?: Inline[] }
  | { type: 'blockquote'; attrs?: { indent?: number }; content: ParagraphNode[] }
  | { type: 'horizontalRule' }
  | { type: 'listItem'; attrs: { kind: 'bullet' | 'ordered' | 'task'; level: number; number?: number; checked?: boolean; align?: Align }; content?: Inline[] }
  | { type: 'table'; attrs?: { columnWidths?: number[] }; content: TableRow[] };

export interface TableRow {
  type: 'tableRow';
  content: { type: 'tableHeader' | 'tableCell'; content: ParagraphNode[] }[];
}

export interface NoteItDoc {
  type: 'doc';
  content: Block[];
}

export interface AttachmentEntry {
  mime: string;
  name: string;
  /** base64 */
  data: string;
}

export interface BodyContainer {
  format: 'noteit-doc';
  version: 1;
  doc: NoteItDoc;
  attachments: Record<string, AttachmentEntry>;
  frontMatter?: string;
  [extra: string]: unknown;
}

export const NOTEITDOC_EXTENSION = 'noteitdoc';
export const BODY_FORMAT_DOC_V1 = 'noteit-doc/1';
export const BODY_FORMAT_LOCKED_V1 = 'noteit-locked/1';
export const CURRENT_VERSION = 1;

/** Same list as Swift LinkPolicy.schemes. */
export const LINK_SCHEMES: readonly string[] = ['http:', 'https:', 'mailto:', 'tel:', 'noteit:'];

/** 25 MB per attachment (spec §3.2), the same as Swift AttachmentLimit.maxBytes. */
export const MAX_ATTACHMENT_BYTES = 26_214_400;

export function attachmentTooLargeMessage(name: string): string {
  return `“${name}” is too large to add. Attachments can be up to 25 MB.`;
}

export const PASSPHRASE_HINT = 'Type it exactly as on your other devices. Letters with accents can differ between keyboards.';

const UUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

/** = Swift LinkPolicy.allows: a listed scheme; a `noteit:` link must name the `note` host. */
export function isAllowedLink(href: string): boolean {
  const m = /^([A-Za-z][A-Za-z0-9+.-]*):/.exec(href.trim());
  if (!m || href !== href.trim() || /[\s\u0000-\u001f]/.test(href)) return false;
  const scheme = `${m[1]!.toLowerCase()}:`;
  if (!LINK_SCHEMES.includes(scheme)) return false;
  if (scheme === 'noteit:') {
    const host = /^noteit:\/\/([^/?#]*)/i.exec(href)?.[1];
    return host?.toLowerCase() === 'note';
  }
  return true;
}

export function parseNoteLink(href: string): { id: Uuid; heading?: string } | { title: string } | undefined {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return undefined;
  }
  if (url.protocol !== 'noteit:' || url.host.toLowerCase() !== 'note') return undefined;
  const path = url.pathname.replace(/^\//, '');
  if (path && UUID_RE.test(path)) {
    const heading = url.searchParams.get('heading');
    return heading ? { id: path.toUpperCase(), heading } : { id: path.toUpperCase() };
  }
  const title = url.searchParams.get('title');
  return !path && title ? { title } : undefined;
}

export function noteLink(id: Uuid, heading?: string): string {
  return `noteit://note/${id.toUpperCase()}${heading ? `?heading=${encodeURIComponent(heading)}` : ''}`;
}

export const emptyDoc = (): NoteItDoc => ({ type: 'doc', content: [{ type: 'paragraph' }] });

export const emptyContainer = (): BodyContainer => ({ format: 'noteit-doc', version: 1, doc: emptyDoc(), attachments: {} });
