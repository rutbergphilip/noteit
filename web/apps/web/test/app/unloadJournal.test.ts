import { beforeEach, describe, expect, it, vi } from 'vitest';
import { emptyContainer } from '@noteit/doc';
import { clearJournalKey, clearUnsaved, readUnsaved, setJournalKey, writeUnsaved, type UnsavedEdit } from '~/utils/unloadJournal';

class MemoryStorage {
  private items = new Map<string, string>();
  get length() {
    return this.items.size;
  }
  key(i: number) {
    return [...this.items.keys()][i] ?? null;
  }
  getItem(k: string) {
    return this.items.get(k) ?? null;
  }
  setItem(k: string, v: string) {
    this.items.set(k, String(v));
  }
  removeItem(k: string) {
    this.items.delete(k);
  }
  clear() {
    this.items.clear();
  }
}

/** Object.keys(localStorage) lists the stored names in a browser; a Proxy gives the stand-in the same shape. */
function storage(): Storage {
  const mem = new MemoryStorage();
  return new Proxy(mem, {
    ownKeys: () => [...(mem as unknown as { items: Map<string, string> }).items.keys()],
    getOwnPropertyDescriptor: (_t, k) => ({ enumerable: true, configurable: true, value: mem.getItem(String(k)) }),
  }) as unknown as Storage;
}

const ID = '0F5C2E2A-8B1D-4C5B-9C43-3E6B7A1F0D11';
function edit(text: string): UnsavedEdit {
  const container = emptyContainer();
  container.doc = { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text }] }] };
  return { noteId: ID, baseRevision: 'R1', container };
}
const key = (b: number) => new Uint8Array(32).fill(b);

describe('unload journal', () => {
  beforeEach(() => {
    vi.stubGlobal('localStorage', storage());
    clearJournalKey();
  });

  it('round-trips an edit and keeps no plaintext at rest', () => {
    setJournalKey('user-1', key(1));
    expect(writeUnsaved(edit('a secret line'))).toBe(true);
    const stored = Object.keys(localStorage).map((k) => `${k}=${localStorage.getItem(k)}`).join('\n');
    expect(stored).not.toContain('secret');
    expect(readUnsaved()).toEqual([edit('a secret line')]);
    clearUnsaved(ID);
    expect(readUnsaved()).toEqual([]);
  });

  it('writes nothing while locked', () => {
    expect(writeUnsaved(edit('x'))).toBe(false);
    expect(Object.keys(localStorage)).toEqual([]);
  });

  it("drops an entry the current key can't open, and leaves other accounts' entries alone", () => {
    setJournalKey('user-1', key(1));
    writeUnsaved(edit('one'));
    setJournalKey('user-2', key(2));
    writeUnsaved(edit('two'));
    setJournalKey('user-1', key(3));
    expect(readUnsaved()).toEqual([]);
    expect(Object.keys(localStorage)).toHaveLength(1);
    setJournalKey('user-2', key(2));
    expect(readUnsaved()).toEqual([edit('two')]);
  });

  it('binds an entry to its slot, so a moved entry is not opened as another note', () => {
    setJournalKey('user-1', key(1));
    writeUnsaved(edit('mine'));
    const [name] = Object.keys(localStorage);
    localStorage.setItem(name!.replace(ID, 'OTHER'), localStorage.getItem(name!)!);
    expect(readUnsaved()).toEqual([edit('mine')]);
    expect(Object.keys(localStorage)).toEqual([name]);
  });
});
