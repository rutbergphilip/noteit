/** SF Symbol names the Mac app stores → Lucide icons (bundled; see nuxt.config `icon`). */
export const SYMBOL_ICONS: Record<string, string> = {
  tray: 'i-lucide-inbox',
  'tray.fill': 'i-lucide-inbox',
  command: 'i-lucide-command',
  lightbulb: 'i-lucide-lightbulb',
  'chevron.left.forwardslash.chevron.right': 'i-lucide-code-xml',
  book: 'i-lucide-book',
  'book.closed': 'i-lucide-book',
  briefcase: 'i-lucide-briefcase',
  'server.rack': 'i-lucide-server',
  lock: 'i-lucide-lock',
  photo: 'i-lucide-image',
  link: 'i-lucide-link',
  bolt: 'i-lucide-zap',
  clock: 'i-lucide-clock',
  tag: 'i-lucide-tag',
  pin: 'i-lucide-pin',
  magnifyingglass: 'i-lucide-search',
  checklist: 'i-lucide-list-checks',
  folder: 'i-lucide-folder',
};

/** A notebook's icon; unknown symbols fall back to a folder. */
export const notebookIcon = (symbol: string | undefined) => (symbol && SYMBOL_ICONS[symbol]) || 'i-lucide-folder';

/** The icon picker in the New Notebook dialog (design p05): label → SF Symbol name written to the store. */
export const NOTEBOOK_SYMBOLS: { label: string; symbol: string }[] = [
  { label: 'Tray', symbol: 'tray' },
  { label: 'Command', symbol: 'command' },
  { label: 'Lightbulb', symbol: 'lightbulb' },
  { label: 'Code', symbol: 'chevron.left.forwardslash.chevron.right' },
  { label: 'Book', symbol: 'book' },
  { label: 'Briefcase', symbol: 'briefcase' },
  { label: 'Server', symbol: 'server.rack' },
  { label: 'Lock', symbol: 'lock' },
  { label: 'Image', symbol: 'photo' },
  { label: 'Link', symbol: 'link' },
  { label: 'Bolt', symbol: 'bolt' },
  { label: 'Clock', symbol: 'clock' },
  { label: 'Tag', symbol: 'tag' },
  { label: 'Pin', symbol: 'pin' },
  { label: 'Search', symbol: 'magnifyingglass' },
  { label: 'Checklist', symbol: 'checklist' },
];

/** The ten notebook colors (Tokens.swift), written as #RRGGBB like native. */
export const NOTEBOOK_COLORS: { label: string; hex: string }[] = [
  { label: 'Blue', hex: '#0A84FF' },
  { label: 'Indigo', hex: '#5E5CE6' },
  { label: 'Purple', hex: '#BF5AF2' },
  { label: 'Pink', hex: '#FF375F' },
  { label: 'Red', hex: '#FF453A' },
  { label: 'Orange', hex: '#FF9F0A' },
  { label: 'Yellow', hex: '#FFD60A' },
  { label: 'Green', hex: '#30D158' },
  { label: 'Teal', hex: '#64D2FF' },
  { label: 'Gray', hex: '#8E8E93' },
];

/** Notebook colors come from synced data: only #RRGGBB is ever put into a style. */
export function safeHex(v: string | undefined): string {
  return v && /^#[0-9A-Fa-f]{6}$/.test(v) ? v : '#8E8E93';
}
