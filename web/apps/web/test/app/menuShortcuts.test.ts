import { beforeEach, describe, expect, it } from 'vitest';
import {
  MENU_SHORTCUT_COMMANDS,
  STORAGE_KEY,
  clearShortcut,
  comboFromEvent,
  comboLabel,
  currentCombos,
  decodeOverrides,
  encodeOverrides,
  evaluateShortcut,
  keysForWebCommand,
  loadMenuShortcuts,
  menuOverrides,
  normalizeCombo,
  paletteCombos,
  resetAllShortcuts,
  resetBlocker,
  resetShortcut,
  setShortcut,
} from '~/utils/menuShortcuts';
import { isMac, matchesCombo } from '~/utils/shortcuts';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

class MemoryStorage {
  map = new Map<string, string>();
  getItem(k: string) {
    return this.map.get(k) ?? null;
  }
  setItem(k: string, v: string) {
    this.map.set(k, v);
  }
  removeItem(k: string) {
    this.map.delete(k);
  }
}
const store = () => new MemoryStorage() as unknown as Storage;
const key = (code: string, mods: Partial<Record<'meta' | 'ctrl' | 'alt' | 'shift', boolean>> = {}) => ({ code, metaKey: !!mods.meta, ctrlKey: !!mods.ctrl, altKey: !!mods.alt, shiftKey: !!mods.shift });

beforeEach(() => {
  menuOverrides.value = {};
});

describe('menu shortcut commands', () => {
  it('lists native MenuShortcutCommand cases (bar Version History) in order', () => {
    const swift = readFileSync(fileURLToPath(new URL('../../../../../Sources/NoteIt/App/MenuShortcuts.swift', import.meta.url)), 'utf8');
    const block = swift.slice(swift.indexOf('enum MenuShortcutCommand'));
    const cases = [...block.slice(0, block.indexOf('var title')).matchAll(/^\s+case (\w+)$/gm)].map((m) => m[1]);
    expect(cases.filter((c) => c !== 'versionHistory')).toEqual(MENU_SHORTCUT_COMMANDS.map((c) => c.id));
  });
});

describe('combos', () => {
  it('normalizes modifier order and case', () => {
    expect(normalizeCombo('mod+shift+N')).toBe('shift+mod+n');
    expect(normalizeCombo('mod+alt+ctrl+shift+k')).toBe('ctrl+alt+shift+mod+k');
    expect(normalizeCombo('mod+delete')).toBe('mod+backspace');
  });
  it('records a key press by code', () => {
    expect(comboFromEvent(key('KeyJ', { meta: true, shift: true }), true)).toBe('shift+mod+j');
    expect(comboFromEvent(key('KeyJ', { ctrl: true, meta: true }), true)).toBe('ctrl+mod+j');
    expect(comboFromEvent(key('KeyJ', { ctrl: true, alt: true }), false)).toBe('alt+mod+j');
    expect(comboFromEvent(key('Comma', { meta: true }), true)).toBe('mod+,');
    expect(comboFromEvent(key('F5'), true)).toBe('f5');
    expect(comboFromEvent(key('ShiftLeft', { shift: true }), true)).toBeUndefined();
  });
  it('labels as native on a Mac, words elsewhere', () => {
    expect(comboLabel('alt+shift+mod+c', true)).toBe('⌥⇧⌘C');
    expect(comboLabel('ctrl+mod+arrowleft', true)).toBe('⌃⌘←');
    expect(comboLabel('shift+mod+j', false)).toBe('Ctrl+Shift+J');
    expect(comboLabel('ctrl+mod+arrowleft', false)).toBe('Ctrl+Alt+Left');
  });
  it('a recorded combo matches its own key press', () => {
    for (const c of ['shift+mod+j', 'mod+,', 'mod+\\', 'mod+=', 'f5', 'alt+mod+arrowup', 'mod+.']) {
      const parts = c.split('+');
      const k = parts.pop()!;
      const code = /^[a-z]$/.test(k) ? `Key${k.toUpperCase()}` : ({ ',': 'Comma', '\\': 'Backslash', '=': 'Equal', '.': 'Period', f5: 'F5', arrowup: 'ArrowUp' } as Record<string, string>)[k]!;
      const e = key(code, { [isMac ? 'meta' : 'ctrl']: parts.includes('mod'), alt: parts.includes('alt'), shift: parts.includes('shift') }) as KeyboardEvent;
      expect(comboFromEvent(e)).toBe(normalizeCombo(c));
      expect([c, matchesCombo(e, c)]).toEqual([c, true]);
    }
  });
});

describe('storage in native MenuShortcutCoding JSON', () => {
  it('roundtrips with sorted keys and native modifier names', () => {
    const json = encodeOverrides({ print: null, find: 'mod+j' });
    expect(json).toBe('{"find":{"key":"j","modifiers":["command"]},"print":{"none":true}}');
    expect(decodeOverrides(json)).toEqual({ find: 'mod+j', print: null });
    expect(encodeOverrides({})).toBeUndefined();
  });
  it('drops unknown commands, modifiers, invalid combos and defaults', () => {
    const json = JSON.stringify({
      nope: { key: 'j', modifiers: ['command'] },
      find: { key: 'j', modifiers: ['hyper'] },
      print: { key: 'j', modifiers: [] },
      newNote: { key: 'n', modifiers: ['command'] },
      dailyNoteForDate: { none: true },
      goBack: 'x',
    });
    expect(decodeOverrides(json)).toEqual({});
    expect(decodeOverrides('not json')).toEqual({});
  });
  it("gives a command whose default is taken by the user's shortcut none", () => {
    expect(decodeOverrides(encodeOverrides({ find: 'mod+p' }))).toEqual({ find: 'mod+p', print: null });
  });
  it('saves to and loads from storage', () => {
    const s = store();
    setShortcut('find', 'mod+j', {}, s);
    expect(s.getItem(STORAGE_KEY)).toBe('{"find":{"key":"j","modifiers":["command"]}}');
    menuOverrides.value = {};
    loadMenuShortcuts(s);
    expect(currentCombos('find')).toEqual(['mod+j']);
    resetAllShortcuts(s);
    expect(s.getItem(STORAGE_KEY)).toBeNull();
    expect(currentCombos('find')).toEqual(['alt+mod+f']);
  });
});

describe('overrides in effect', () => {
  it('keeps the browser alternative until the command is changed', () => {
    expect(keysForWebCommand('newNote', undefined)).toEqual(['mod+n', 'alt+mod+n']);
    setShortcut('newNote', 'ctrl+mod+n', undefined, store());
    expect(keysForWebCommand('newNote', undefined)).toEqual(['ctrl+mod+n']);
    clearShortcut('newNote', undefined, store());
    expect(keysForWebCommand('newNote', undefined)).toEqual([]);
    resetShortcut('newNote', undefined, store());
    expect(keysForWebCommand('newNote', undefined)).toEqual(['mod+n', 'alt+mod+n']);
  });
  it('leaves commands native has no menu shortcut for alone', () => {
    expect(keysForWebCommand('quickCapture', ['alt+mod+c'])).toEqual(['alt+mod+c']);
  });
  it('maps Open Quickly and Command Palette to the palette, keeping ⌘K', () => {
    setShortcut('openQuickly', 'mod+j', undefined, store());
    expect(paletteCombos()).toEqual(['mod+j', 'shift+mod+p', 'mod+k']);
  });
  it('setting the default back removes the override', () => {
    setShortcut('find', 'mod+j', undefined, store());
    setShortcut('find', 'mod+alt+f', undefined, store());
    expect(menuOverrides.value).toEqual({});
  });
  it("can't restore a default another command has taken", () => {
    setShortcut('find', 'mod+j', undefined, store());
    setShortcut('print', 'alt+mod+f', undefined, store());
    expect(resetBlocker('find')?.id).toBe('print');
    resetShortcut('find', undefined, store());
    expect(currentCombos('find')).toEqual(['mod+j']);
  });
});

describe('rules (native MenuShortcutRules)', () => {
  it('rejects Esc, missing ⌘/⌃ and editing keys', () => {
    expect(evaluateShortcut('mod+escape', 'find')).toMatchObject({ accept: false, message: "Esc can't be used in a shortcut." });
    expect(evaluateShortcut('shift+j', 'find')).toMatchObject({ accept: false });
    expect(evaluateShortcut('f6', 'find')).toEqual({ accept: true });
    expect(evaluateShortcut('mod+arrowup', 'find')).toMatchObject({ accept: false, message: 'Arrow, delete and page keys are kept for moving around and editing text.' });
    expect(evaluateShortcut('ctrl+mod+arrowleft', 'goBack')).toEqual({ accept: true });
  });
  it('rejects a combo another command, a fixed or a system shortcut uses', () => {
    expect(evaluateShortcut('mod+p', 'find')).toEqual({ accept: false, message: 'CTRL+P is already used for “Print…”.'.replace('CTRL+P', comboLabel('mod+p')) });
    expect(evaluateShortcut('mod+b', 'find')).toMatchObject({ accept: false, message: `${comboLabel('mod+b')} is already used for “Bold”.` });
    expect(evaluateShortcut('mod+c', 'find')).toMatchObject({ accept: false, message: `${comboLabel('mod+c')} is already used for “Copy”.` });
    expect(evaluateShortcut('alt+mod+n', 'find')).toMatchObject({ accept: false, message: `${comboLabel('alt+mod+n')} is already used for “New Note”.` });
  });
  it('accepts a browser-kept key with a heads-up', () => {
    expect(evaluateShortcut('mod+j', 'find')).toMatchObject({ accept: true, warning: `${comboLabel('mod+j')} is also a browser shortcut and may not work.` });
    expect(evaluateShortcut('ctrl+mod+j', 'find')).toEqual({ accept: true });
  });
});
