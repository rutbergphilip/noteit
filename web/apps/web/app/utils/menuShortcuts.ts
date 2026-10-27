/**
 * Settings › Shortcuts, as native's "In NoteIt" section (Sources/NoteIt/App/MenuShortcutStore.swift and
 * MenuShortcutRules.swift). Native keeps a user's menu shortcuts in its own UserDefaults and never syncs them, so the
 * web keeps its own per browser, in localStorage under native's key and in native's JSON shape:
 * `{"find":{"key":"j","modifiers":["command"]},"print":{"none":true}}`. Only changes from the defaults are stored,
 * keyed by native's command names; `key` is the web's key name (a letter, digit or punctuation, or a named key such
 * as `arrowleft`).
 */
import { shallowRef } from 'vue';
import { isMac } from '~/utils/shortcuts';

export const STORAGE_KEY = 'menuShortcutOverrides';

export interface MenuShortcutCommand {
  /** Native's MenuShortcutCommand raw value (the stored key). */
  id: string;
  /** The web command it runs (utils/commands.ts), or the palette. */
  webId: string;
  title: string;
  /** The default combos: native's, then a web alternative where a browser keeps the key. */
  defaults: string[];
}

/** Native's MenuShortcutCommand.allCases in order, without Version History (native-only, local data). */
export const MENU_SHORTCUT_COMMANDS: MenuShortcutCommand[] = [
  { id: 'newNote', webId: 'newNote', title: 'New Note', defaults: ['mod+n', 'alt+mod+n'] },
  { id: 'newNotebook', webId: 'newNotebook', title: 'New Notebook…', defaults: ['shift+mod+n', 'alt+shift+mod+b'] },
  { id: 'openQuickly', webId: 'palette', title: 'Open Quickly…', defaults: ['mod+o'] },
  { id: 'commandPalette', webId: 'palette', title: 'Command Palette…', defaults: ['shift+mod+p'] },
  { id: 'searchNotes', webId: 'searchNotes', title: 'Search Notes', defaults: ['mod+f'] },
  { id: 'find', webId: 'find', title: 'Find…', defaults: ['alt+mod+f'] },
  { id: 'findAndReplace', webId: 'findReplace', title: 'Find and Replace…', defaults: ['shift+mod+f'] },
  { id: 'exportNote', webId: 'export', title: 'Export Note As…', defaults: ['shift+mod+s'] },
  { id: 'print', webId: 'print', title: 'Print…', defaults: ['mod+p'] },
  { id: 'copyAsMarkdown', webId: 'copyMarkdown', title: 'Copy as Markdown', defaults: ['alt+shift+mod+c'] },
  { id: 'copyNoteLink', webId: 'copyNoteLink', title: 'Copy Note Link', defaults: ['ctrl+mod+l'] },
  { id: 'deleteNote', webId: 'deleteNote', title: 'Delete Note', defaults: ['mod+backspace'] },
  { id: 'goBack', webId: 'goBack', title: 'Go Back', defaults: ['ctrl+mod+arrowleft'] },
  { id: 'goForward', webId: 'goForward', title: 'Go Forward', defaults: ['ctrl+mod+arrowright'] },
  { id: 'linkToNote', webId: 'linkToNote', title: 'Link to Note…', defaults: ['shift+mod+k'] },
  // ⌥⌘N is New Note's alternative on the web, so New Note from Template is ⌥⇧⌘N here.
  { id: 'newNoteFromTemplate', webId: 'newNoteFromTemplate', title: 'New Note from Template…', defaults: ['alt+shift+mod+n'] },
  { id: 'toggleInspector', webId: 'showBacklinks', title: 'Show Links and Outline', defaults: ['alt+mod+i'] },
  { id: 'openToday', webId: 'openToday', title: "Open Today's Note", defaults: ['ctrl+mod+t'] },
  { id: 'dailyNoteForDate', webId: 'dailyNoteForDate', title: 'Daily Note for Date…', defaults: [] },
  { id: 'newSmartFolder', webId: 'newSmartFolder', title: 'New Smart Folder…', defaults: [] },
  { id: 'saveSearchAsSmartFolder', webId: 'saveSearchAsSmartFolder', title: 'Save Search as Smart Folder…', defaults: [] },
  { id: 'showTasks', webId: 'showTasks', title: 'Tasks', defaults: ['shift+mod+t', 'alt+shift+mod+t'] },
  { id: 'setDueDate', webId: 'setDueDate', title: 'Set Due Date…', defaults: ['shift+mod+d'] },
  { id: 'addReminder', webId: 'addReminder', title: 'Add Reminder…', defaults: ['ctrl+mod+r'] },
  { id: 'showNoteInfo', webId: 'showNoteInfo', title: 'Show Note Info', defaults: ['ctrl+mod+i'] },
];

const BY_ID = new Map(MENU_SHORTCUT_COMMANDS.map((c) => [c.id, c]));
const BY_WEB_ID = new Map(MENU_SHORTCUT_COMMANDS.filter((c) => c.webId !== 'palette').map((c) => [c.webId, c]));

/** A user's change: another combo, or none (`null`). */
export type Overrides = Record<string, string | null>;

// MARK: combos

const MODS = ['ctrl', 'alt', 'shift', 'mod'] as const;
const NATIVE_MODS: Record<(typeof MODS)[number], string> = { ctrl: 'control', alt: 'option', shift: 'shift', mod: 'command' };
const NAMED = new Set(['backspace', 'delete', 'forwarddelete', 'arrowleft', 'arrowright', 'arrowup', 'arrowdown', 'enter', 'tab', 'space', 'escape', 'home', 'end', 'pageup', 'pagedown']);
const PUNCT = new Set([',', '.', '/', ';', "'", '`', '-', '=', '[', ']', '\\']);
const EDITING = new Set(['arrowleft', 'arrowright', 'arrowup', 'arrowdown', 'backspace', 'delete', 'forwarddelete', 'home', 'end', 'pageup', 'pagedown']);

const validKey = (k: string) => /^[a-z0-9]$/.test(k) || PUNCT.has(k) || NAMED.has(k) || /^f([1-9]|1[0-9]|20)$/.test(k);

/** `shift+mod+N` and `mod+shift+n` are the same combo: modifiers in native's ⌃⌥⇧⌘ order, the key lowercased. */
export function normalizeCombo(combo: string): string {
  const parts = combo.toLowerCase().split('+');
  const key = parts.pop()!;
  const k = key === 'delete' ? 'backspace' : key;
  return [...MODS.filter((m) => parts.includes(m)), k].join('+');
}

function splitCombo(combo: string): { mods: Set<string>; key: string } {
  const parts = normalizeCombo(combo).split('+');
  const key = parts.pop()!;
  return { mods: new Set(parts), key };
}

/** Native's `isValid`: ⌘ or ⌃, or a function key. */
export function isValidCombo(combo: string): boolean {
  const { mods, key } = splitCombo(combo);
  if (!validKey(key)) return false;
  return mods.has('mod') || mods.has('ctrl') || /^f\d+$/.test(key);
}

const KEY_GLYPHS: Record<string, string> = {
  backspace: '⌫',
  forwarddelete: '⌦',
  arrowleft: '←',
  arrowright: '→',
  arrowup: '↑',
  arrowdown: '↓',
  enter: '↩',
  tab: '⇥',
  space: 'Space',
  escape: '⎋',
  home: '↖',
  end: '↘',
  pageup: '⇞',
  pagedown: '⇟',
};

const KEY_WORDS: Record<string, string> = { arrowleft: 'Left', arrowright: 'Right', arrowup: 'Up', arrowdown: 'Down', forwarddelete: 'Delete', escape: 'Esc', pageup: 'PageUp', pagedown: 'PageDown' };

/** "⌥⇧⌘C" on a Mac, "Ctrl+Alt+Shift+C" elsewhere (⌃ is Alt off a Mac). */
export function comboLabel(combo: string, mac = isMac): string {
  const { mods, key } = splitCombo(combo);
  const name = KEY_GLYPHS[key] ?? key.toUpperCase();
  if (mac) return [mods.has('ctrl') && '⌃', mods.has('alt') && '⌥', mods.has('shift') && '⇧', mods.has('mod') && '⌘'].filter(Boolean).join('') + name;
  const words = [mods.has('mod') && 'Ctrl', (mods.has('alt') || mods.has('ctrl')) && 'Alt', mods.has('shift') && 'Shift'].filter(Boolean) as string[];
  const word = KEY_GLYPHS[key] ? (KEY_WORDS[key] ?? key.replace(/^./, (c) => c.toUpperCase())) : name;
  return [...words, word].join('+');
}

const CODE_KEYS: Record<string, string> = {
  Comma: ',',
  Period: '.',
  Slash: '/',
  Semicolon: ';',
  Quote: "'",
  Backquote: '`',
  Minus: '-',
  Equal: '=',
  BracketLeft: '[',
  BracketRight: ']',
  Backslash: '\\',
  Backspace: 'backspace',
  Delete: 'forwarddelete',
  ArrowLeft: 'arrowleft',
  ArrowRight: 'arrowright',
  ArrowUp: 'arrowup',
  ArrowDown: 'arrowdown',
  Enter: 'enter',
  NumpadEnter: 'enter',
  Tab: 'tab',
  Space: 'space',
  Escape: 'escape',
  Home: 'home',
  End: 'end',
  PageUp: 'pageup',
  PageDown: 'pagedown',
};

export type KeyLike = Pick<KeyboardEvent, 'code' | 'metaKey' | 'ctrlKey' | 'altKey' | 'shiftKey'>;

/** A key press as a combo, by `code` so ⌥ combinations record their key; undefined for a lone modifier or an unknown key. */
export function comboFromEvent(e: KeyLike, mac = isMac): string | undefined {
  const key = /^Key[A-Z]$/.test(e.code) ? e.code.slice(3).toLowerCase() : /^Digit\d$/.test(e.code) ? e.code.slice(5) : /^F\d{1,2}$/.test(e.code) ? e.code.toLowerCase() : CODE_KEYS[e.code];
  if (!key || !validKey(key)) return undefined;
  // Off a Mac, Ctrl is ⌘ and Alt is ⌥; the Windows key isn't used.
  const mods = mac ? { ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, mod: e.metaKey } : { ctrl: false, alt: e.altKey, shift: e.shiftKey, mod: e.ctrlKey };
  return normalizeCombo([...MODS.filter((m) => mods[m]), key].join('+'));
}

/** Nuxt UI `kbds` for a combo (⌃ shows as Alt off a Mac). */
export function comboKbdList(combo: string, mac = isMac): string[] {
  const { mods, key } = splitCombo(combo);
  const out: string[] = [];
  if (mods.has('ctrl')) out.push(mac ? 'ctrl' : 'alt');
  if (mods.has('alt') && !out.includes('alt')) out.push('alt');
  if (mods.has('shift')) out.push('shift');
  if (mods.has('mod')) out.push('meta');
  out.push(key.length === 1 || /^f\d+$/.test(key) ? key.toUpperCase() : key);
  return out;
}

// MARK: storage (native MenuShortcutCoding)

/** The stored JSON → overrides. Unknown commands, unknown modifiers, invalid combos and defaults are dropped. */
export function decodeOverrides(json: string | null | undefined): Overrides {
  if (!json) return {};
  let raw: unknown;
  try {
    raw = JSON.parse(json);
  } catch {
    return {};
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const out: Overrides = {};
  for (const [id, entry] of Object.entries(raw as Record<string, unknown>)) {
    const command = BY_ID.get(id);
    if (!command || !entry || typeof entry !== 'object') continue;
    const e = entry as { key?: unknown; modifiers?: unknown; none?: unknown };
    if (e.none === true && e.key === undefined) {
      if (command.defaults.length) out[id] = null;
      continue;
    }
    if (e.none === true || typeof e.key !== 'string' || !Array.isArray(e.modifiers)) continue;
    const mods: string[] = [];
    let ok = true;
    for (const name of e.modifiers) {
      const mod = MODS.find((m) => NATIVE_MODS[m] === name);
      if (!mod) ok = false;
      else mods.push(mod);
    }
    const combo = normalizeCombo([...mods, e.key.toLowerCase()].join('+'));
    if (!ok || !isValidCombo(combo)) continue;
    if (command.defaults[0] && normalizeCombo(command.defaults[0]) === combo) continue;
    out[id] = combo;
  }
  return clearingTakenDefaults(out);
}

/** Overrides → the stored JSON (sorted keys, as native's encoder), or undefined when there are none. */
export function encodeOverrides(overrides: Overrides): string | undefined {
  const ids = Object.keys(overrides).sort();
  if (!ids.length) return undefined;
  const out: Record<string, unknown> = {};
  for (const id of ids) {
    const combo = overrides[id];
    if (combo === null) out[id] = { none: true };
    else if (combo !== undefined) {
      const { mods, key } = splitCombo(combo);
      out[id] = { key, modifiers: MODS.filter((m) => mods.has(m)).map((m) => NATIVE_MODS[m]) };
    }
  }
  return JSON.stringify(out);
}

/** A command added later whose default one of the user's own shortcuts already uses starts with none. */
export function clearingTakenDefaults(overrides: Overrides): Overrides {
  const taken = new Set(Object.values(overrides).filter((v): v is string => typeof v === 'string'));
  const out = { ...overrides };
  for (const c of MENU_SHORTCUT_COMMANDS) {
    if (c.id in overrides) continue;
    if (c.defaults.some((d) => taken.has(normalizeCombo(d)))) out[c.id] = null;
  }
  return out;
}

// MARK: the store

/** The current overrides; reactive, so the palette and tooltips follow a change. */
export const menuOverrides = shallowRef<Overrides>({});

function storage(): Storage | undefined {
  try {
    return typeof localStorage === 'undefined' ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

export function loadMenuShortcuts(store = storage()): void {
  let json: string | null = null;
  try {
    json = store?.getItem(STORAGE_KEY) ?? null;
  } catch {
    json = null;
  }
  menuOverrides.value = decodeOverrides(json);
}

function save(next: Overrides, store = storage()): void {
  menuOverrides.value = next;
  try {
    const json = encodeOverrides(next);
    if (json) store?.setItem(STORAGE_KEY, json);
    else store?.removeItem(STORAGE_KEY);
  } catch {
    // Private windows can refuse storage: the change still holds for this page.
  }
}

/** A command's combos in effect now: the user's one, none, or the defaults (with the browser alternative). */
export function currentCombos(id: string, overrides = menuOverrides.value): string[] {
  const c = BY_ID.get(id);
  if (!c) return [];
  if (id in overrides) {
    const o = overrides[id];
    return o ? [o] : [];
  }
  return c.defaults;
}

/** The combos for a web command id: overridable commands follow Settings; others keep `fallback`. */
export function keysForWebCommand(webId: string, fallback: string[] | undefined): string[] | undefined {
  const c = BY_WEB_ID.get(webId);
  return c ? currentCombos(c.id) : fallback;
}

/** Nuxt UI `kbds` for a command's first shortcut in effect, or none. */
export function commandKbds(id: string): string[] | undefined {
  const combo = currentCombos(id)[0];
  return combo ? comboKbdList(combo) : undefined;
}

/** ⌘O and ⇧⌘P (as set in Settings), and ⌘K, which always opens the palette on the web. */
export function paletteCombos(): string[] {
  return [...currentCombos('openQuickly'), ...currentCombos('commandPalette'), 'mod+k'];
}

export const isCustomized = (id: string, overrides = menuOverrides.value) => id in overrides;
export const hasCustomizations = (overrides = menuOverrides.value) => Object.keys(overrides).length > 0;

/** The other commands now using `combo`. */
export function commandsUsing(combo: string, excluding?: string, overrides = menuOverrides.value): MenuShortcutCommand[] {
  const n = normalizeCombo(combo);
  return MENU_SHORTCUT_COMMANDS.filter((c) => c.id !== excluding && currentCombos(c.id, overrides).some((x) => normalizeCombo(x) === n));
}

/** The command using `id`'s default shortcut, which stops it from being restored. */
export function resetBlocker(id: string, overrides = menuOverrides.value): MenuShortcutCommand | undefined {
  const c = BY_ID.get(id);
  if (!c || !(id in overrides) || !c.defaults[0]) return undefined;
  return c.defaults.map((d) => commandsUsing(d, id, overrides)[0]).find(Boolean);
}

export function setShortcut(id: string, combo: string, overrides = menuOverrides.value, store = storage()): void {
  const c = BY_ID.get(id);
  if (!c) return;
  const next = { ...overrides };
  if (c.defaults[0] && normalizeCombo(c.defaults[0]) === normalizeCombo(combo)) delete next[id];
  else next[id] = normalizeCombo(combo);
  save(next, store);
}

/** Leaves the command without a shortcut. */
export function clearShortcut(id: string, overrides = menuOverrides.value, store = storage()): void {
  const c = BY_ID.get(id);
  if (!c) return;
  const next = { ...overrides };
  if (c.defaults.length) next[id] = null;
  else delete next[id];
  save(next, store);
}

/** Back to the default, unless another command has taken it meanwhile. */
export function resetShortcut(id: string, overrides = menuOverrides.value, store = storage()): void {
  if (resetBlocker(id, overrides)) return;
  const next = { ...overrides };
  delete next[id];
  save(next, store);
}

export function resetAllShortcuts(store = storage()): void {
  save({}, store);
}

// MARK: rules (native MenuShortcutRules)

/** NoteIt shortcuts that can't be changed: the editor's formatting, find and the fixed web commands. */
export const FIXED_SHORTCUTS: [string, string][] = [
  ['mod+b', 'Bold'],
  ['mod+i', 'Italic'],
  ['mod+u', 'Underline'],
  ['shift+mod+x', 'Strikethrough'],
  ['shift+mod+e', 'Code'],
  ['alt+mod+1', 'Title'],
  ['alt+mod+2', 'Heading'],
  ['alt+mod+3', 'Subheading'],
  ['alt+mod+0', 'Body'],
  ['alt+mod+4', 'Code Block'],
  ['alt+mod+5', 'Quote'],
  ['shift+mod+8', 'Bulleted List'],
  ['shift+mod+7', 'Numbered List'],
  ['shift+mod+l', 'Checklist'],
  ['shift+mod+u', 'Check or Uncheck'],
  ['mod+]', 'Indent'],
  ['mod+[', 'Outdent'],
  ['shift+mod+[', 'Align Left'],
  ['shift+mod+\\', 'Center'],
  ['shift+mod+]', 'Align Right'],
  ['mod+k', 'Command Palette'],
  ['shift+mod+h', 'Highlight'],
  ['mod+=', 'Bigger'],
  ['shift+mod+=', 'Bigger'],
  ['mod+-', 'Smaller'],
  ['alt+shift+mod+d', 'Divider'],
  ['alt+mod+\\', 'Clear Formatting'],
  ['mod+0', 'NoteIt Notes'],
  ['mod+g', 'Find Next'],
  ['shift+mod+g', 'Find Previous'],
  ['mod+e', 'Use Selection for Find'],
  ['shift+mod+1', 'Replace'],
  ['alt+mod+enter', 'Replace All'],
  ['mod+,', 'Settings…'],
  ['alt+mod+c', 'Open Quick Capture'],
];

/** Shortcuts the system or every text field uses (native's systemShortcuts, as the browser has them). */
export const SYSTEM_SHORTCUTS: [string, string][] = [
  ['mod+q', 'Quit'],
  ['mod+w', 'Close'],
  ['mod+h', 'Hide'],
  ['alt+mod+h', 'Hide Others'],
  ['mod+m', 'Minimize'],
  ['mod+a', 'Select All'],
  ['mod+c', 'Copy'],
  ['mod+v', 'Paste'],
  ['mod+x', 'Cut'],
  ['mod+z', 'Undo'],
  ['shift+mod+z', 'Redo'],
  ['mod+y', 'Redo'],
  ['shift+mod+v', 'Paste and Match Style'],
  ['alt+shift+mod+v', 'Paste and Match Style'],
  ['mod+`', 'Cycle Through Windows'],
  ['shift+mod+/', 'Help'],
  ['ctrl+mod+f', 'Enter Full Screen'],
  ['ctrl+mod+q', 'Lock Screen'],
  ['mod+space', 'Spotlight'],
  ['ctrl+mod+space', 'Emoji & Symbols'],
  ['ctrl+space', 'Select the previous input source'],
  ['mod+tab', 'Switch Apps'],
  ['shift+mod+tab', 'Switch Apps'],
  ['shift+mod+3', 'Screenshot'],
  ['shift+mod+4', 'Screenshot'],
  ['shift+mod+5', 'Screenshot'],
];

/** Keys a browser keeps for itself: they're accepted with a heads-up, as native warns about macOS shortcuts. */
export const BROWSER_SHORTCUTS = ['mod+n', 'shift+mod+n', 'mod+t', 'shift+mod+t', 'mod+r', 'shift+mod+r', 'mod+l', 'mod+d', 'mod+j', 'mod+s', 'mod+o', 'shift+mod+b', 'alt+mod+i', 'alt+mod+j'].map(normalizeCombo);

export type Verdict = { accept: true; warning?: string } | { accept: false; message: string };

function alreadyUsed(combo: string, names: string[]): string {
  const quoted = names.map((n) => `“${n}”`);
  const list = quoted.length > 1 ? `${quoted.slice(0, -1).join(', ')} and ${quoted.at(-1)}` : quoted.join('');
  return `${comboLabel(combo)} is already used for ${list}.`;
}

/** Native's MenuShortcutRules.evaluate: whether `combo` can be `id`'s shortcut. */
export function evaluateShortcut(combo: string, id: string, overrides = menuOverrides.value): Verdict {
  const n = normalizeCombo(combo);
  const { key } = splitCombo(n);
  const command = BY_ID.get(id);
  if (key === 'escape') return { accept: false, message: "Esc can't be used in a shortcut." };
  if (!isValidCombo(n)) return { accept: false, message: `Include ${isMac ? '⌘ or ⌃' : 'Ctrl'} — or use a function key.` };
  if (EDITING.has(key) && !command?.defaults.some((d) => normalizeCombo(d) === n)) {
    return { accept: false, message: 'Arrow, delete and page keys are kept for moving around and editing text.' };
  }
  const others = commandsUsing(n, id, overrides);
  if (others.length) return { accept: false, message: alreadyUsed(n, others.map((c) => c.title)) };
  const reserved = [...FIXED_SHORTCUTS, ...SYSTEM_SHORTCUTS].find(([c]) => normalizeCombo(c) === n);
  if (reserved) return { accept: false, message: alreadyUsed(n, [reserved[1]]) };
  if (BROWSER_SHORTCUTS.includes(n)) return { accept: true, warning: `${comboLabel(n)} is also a browser shortcut and may not work.` };
  return { accept: true };
}
