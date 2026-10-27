/**
 * Code block colours (native Settings › Editor: `codeBlockTheme`, `syntaxHighlighting`). The Mac keeps these in its
 * own preferences, so the web keeps them per browser under the same keys; app.css holds the themes' palettes.
 */
export const CODE_THEMES = [
  { value: 'xcode', label: 'Xcode' },
  { value: 'github', label: 'GitHub' },
  { value: 'solarized', label: 'Solarized' },
  { value: 'nord', label: 'Nord' },
] as const;
export type CodeThemeId = (typeof CODE_THEMES)[number]['value'];

function read(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}
function write(key: string, value: string | null): void {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // Storage refused (a private window): the default stays.
  }
}

export function codeStyle(): { theme: CodeThemeId; highlighting: boolean } {
  const theme = read('codeBlockTheme');
  return { theme: CODE_THEMES.some((t) => t.value === theme) ? (theme as CodeThemeId) : 'xcode', highlighting: read('syntaxHighlighting') !== 'false' };
}

/** Puts the choice on <html>, where app.css picks the palette up. */
export function applyCodeStyle(): void {
  if (typeof document === 'undefined') return;
  const { theme, highlighting } = codeStyle();
  const root = document.documentElement;
  if (theme === 'xcode') delete root.dataset.codeTheme;
  else root.dataset.codeTheme = theme;
  if (highlighting) delete root.dataset.codeHighlight;
  else root.dataset.codeHighlight = 'off';
}

export function setCodeStyle(change: { theme?: CodeThemeId; highlighting?: boolean }): void {
  if (change.theme) write('codeBlockTheme', change.theme === 'xcode' ? null : change.theme);
  if (change.highlighting !== undefined) write('syntaxHighlighting', change.highlighting ? null : 'false');
  applyCodeStyle();
}
