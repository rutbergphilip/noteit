import { isAllowedLink } from '../schema.js';

/**
 * Synced documents are untrusted input from other devices. Every attribute that reaches `style`, `href` or `src`
 * goes through one of these, in parseHTML, renderHTML and node views alike; anything else becomes null/default.
 */
const ALIGNS = new Set(['left', 'center', 'right', 'justify']);

export function safeAlign(v: unknown): 'left' | 'center' | 'right' | 'justify' | null {
  return typeof v === 'string' && ALIGNS.has(v) ? (v as 'left') : null;
}

export function safeInt(v: unknown, min: number, max: number): number | null {
  const n = typeof v === 'number' ? v : typeof v === 'string' && /^-?\d+$/.test(v) ? Number(v) : NaN;
  return Number.isInteger(n) && n >= min && n <= max ? n : null;
}

export function safePositive(v: unknown, max: number): number | null {
  const n = typeof v === 'number' ? v : typeof v === 'string' && /^\d+(\.\d+)?$/.test(v) ? Number(v) : NaN;
  return Number.isFinite(n) && n > 0 && n <= max ? n : null;
}

/** `#RRGGBB` only (the schema's color format). */
export function safeColor(v: unknown): string | null {
  return typeof v === 'string' && /^#[0-9A-Fa-f]{6}$/.test(v) ? v : null;
}

/** Only the schema's link policy (= Swift LinkPolicy): http, https, mailto, tel and noteit://note. */
export function safeHref(v: unknown): string | null {
  return typeof v === 'string' && isAllowedLink(v) ? v : null;
}

/** Images and attachment downloads come only from blob: URLs this page made for the note's own attachments. */
export function safeBlobUrl(v: unknown): string | null {
  return typeof v === 'string' && /^blob:[^\s"'()<>\\]+$/.test(v) ? v : null;
}

export function safeLanguage(v: unknown): string | null {
  return typeof v === 'string' && /^[A-Za-z0-9+#._-]{1,40}$/.test(v) ? v : null;
}
