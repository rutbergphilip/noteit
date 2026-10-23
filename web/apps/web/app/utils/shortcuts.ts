/**
 * Native's menu shortcuts in the browser. A combo is written the way docs/keyboard-shortcuts.md writes it, as
 * parts joined by "+": `mod` is ⌘ (Ctrl off a Mac), `ctrl` is ⌃ (Alt off a Mac, where ⌥ is Alt too), `alt` is ⌥
 * and `shift` is ⇧; the key is a letter, digit or named key, matched on `KeyboardEvent.code` so ⌥ combinations
 * work on a Mac keyboard (⌥N types "˜").
 */
export const isMac = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

const CODES: Record<string, string> = {
  ',': 'Comma',
  '[': 'BracketLeft',
  ']': 'BracketRight',
  backspace: 'Backspace',
  delete: 'Backspace',
  arrowleft: 'ArrowLeft',
  arrowright: 'ArrowRight',
};

function parse(combo: string) {
  const parts = combo.toLowerCase().split('+');
  const key = parts.pop()!;
  const has = (p: string) => parts.includes(p);
  const code = CODES[key] ?? (/^[a-z]$/.test(key) ? `Key${key.toUpperCase()}` : /^[0-9]$/.test(key) ? `Digit${key}` : key);
  // Off a Mac ⌃ becomes Alt, so ⌃⌘L is Ctrl+Alt+L.
  return isMac
    ? { meta: has('mod'), ctrl: has('ctrl'), alt: has('alt'), shift: has('shift'), code }
    : { meta: false, ctrl: has('mod'), alt: has('alt') || has('ctrl'), shift: has('shift'), code };
}

export function matchesCombo(e: KeyboardEvent, combo: string): boolean {
  const c = parse(combo);
  return e.code === c.code && e.metaKey === c.meta && e.ctrlKey === c.ctrl && e.altKey === c.alt && e.shiftKey === c.shift;
}

/** Nuxt UI `kbds` for a tooltip or palette row (`meta` already shows ⌘ or Ctrl per platform). */
export function comboKbds(combo: string): string[] {
  const parts = combo.toLowerCase().split('+');
  const key = parts.pop()!;
  const out: string[] = [];
  if (parts.includes('ctrl')) out.push(isMac ? 'ctrl' : 'alt');
  if (parts.includes('alt') && !(out.includes('alt'))) out.push('alt');
  if (parts.includes('shift')) out.push('shift');
  if (parts.includes('mod')) out.push('meta');
  out.push(key.length === 1 ? key.toUpperCase() : key);
  return out;
}
