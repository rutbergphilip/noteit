import { gcm } from '@noble/ciphers/aes.js';
import type { BodyContainer } from '@noteit/doc';

/**
 * The unload journal: an edit still unsaved as the page goes away, written synchronously to localStorage so it
 * survives a browser that stops the page's async IndexedDB work at unload (Safari), and saved through the normal
 * save path after the next unlock.
 *
 * Entries are sealed with AES-256-GCM under a journal key the sync worker keeps in IndexedDB sealed by the store key,
 * so it is only available while the library is unlocked and no plaintext sits in localStorage. Encryption here is
 * synchronous (WebCrypto has no synchronous API, and an unload handler can't wait).
 */

export interface UnsavedEdit {
  noteId: string;
  /** The revision the edit is based on: a newer note keeps the other version as a conflict copy when replayed. */
  baseRevision?: string;
  container: BodyContainer;
}

const PREFIX = 'noteit-unsaved:';
let key: Uint8Array | undefined;
let owner = '';

export function setJournalKey(userId: string, raw: Uint8Array): void {
  owner = userId;
  key = raw;
}

export function clearJournalKey(): void {
  key = undefined;
  owner = '';
}

export function hasJournalKey(userId: string): boolean {
  return !!key && owner === userId;
}

const slot = (noteId: string) => `${PREFIX}${owner}:${noteId}`;

function b64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
function unb64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function seal(noteId: string, edit: UnsavedEdit): string {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const sealed = gcm(key!, nonce, new TextEncoder().encode(slot(noteId))).encrypt(new TextEncoder().encode(JSON.stringify(edit)));
  return JSON.stringify({ v: 1, n: b64(nonce), c: b64(sealed) });
}

/** Writes an unsaved edit at once; false when the library is locked or storage refuses it. */
export function writeUnsaved(edit: UnsavedEdit): boolean {
  if (!key) return false;
  try {
    localStorage.setItem(slot(edit.noteId), seal(edit.noteId, edit));
    return true;
  } catch {
    // Over quota with large attachments: keep the text; attachments already saved come back from the library.
    try {
      localStorage.setItem(slot(edit.noteId), seal(edit.noteId, { ...edit, container: { ...edit.container, attachments: {} } }));
      return true;
    } catch {
      return false;
    }
  }
}

export function clearUnsaved(noteId: string): void {
  if (!key) return;
  try {
    localStorage.removeItem(slot(noteId));
  } catch {
    // Storage blocked: nothing was written either.
  }
}

/** This account's unsaved edits; entries that don't open under the current key (another store or key) are dropped. */
export function readUnsaved(): UnsavedEdit[] {
  if (!key) return [];
  const out: UnsavedEdit[] = [];
  try {
    const mine = `${PREFIX}${owner}:`;
    for (const name of Object.keys(localStorage).filter((k) => k.startsWith(mine))) {
      try {
        const { n, c } = JSON.parse(localStorage.getItem(name) ?? '') as { n: string; c: string };
        const plain = gcm(key, unb64(n), new TextEncoder().encode(name)).decrypt(unb64(c));
        const edit = JSON.parse(new TextDecoder().decode(plain)) as UnsavedEdit;
        if (slot(edit.noteId) === name) out.push(edit);
        else localStorage.removeItem(name);
      } catch {
        localStorage.removeItem(name);
      }
    }
  } catch {
    // Storage blocked.
  }
  return out;
}
