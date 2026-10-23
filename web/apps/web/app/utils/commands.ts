/**
 * The web's commands, keyed by the native palette's command IDs (Sources/NoteIt/Palette/PaletteCommandRegistry.swift)
 * so docs/feature-parity.md and its guard test can line the two up. The palette lists them and app.vue runs their
 * shortcuts. `keys` are native's (docs/keyboard-shortcuts.md); where a browser keeps a key for itself (⌘N, ⇧⌘N, ⇧⌘T
 * in Chrome) the web adds its own alternative after it.
 */
import { useNoteit } from '~/composables/useNoteit';
import { copyMarkdown, copyNoteLink, exportNote, printNote } from '~/utils/exporting';
import { pickImport } from '~/utils/importing';

export interface WebCommand {
  id: string;
  title: string;
  icon: string;
  keys?: string[];
  keywords?: string[];
  /** False: the shortcut does nothing while typing (⌘⌫ deletes text there). */
  inText?: boolean;
  available: () => boolean;
  run: () => void | Promise<void>;
}

export function webCommands(): WebCommand[] {
  const n = useNoteit();
  const { state } = n;
  const note = () => state.notes.find((x) => x.id === state.selectedId);
  const live = () => !!note() && !note()!.deletedAt;
  const editable = () => live() && note()!.kind === 'doc';
  const always = () => true;
  const close = () => (state.palette = false);
  const inspector = (tab: 'links' | 'outline' | 'info') => {
    state.inspector = { open: true, tab };
    state.pane = 'editor';
  };
  return [
    { id: 'newNote', title: 'New Note', icon: 'i-lucide-file-plus', keys: ['mod+n', 'alt+mod+n'], keywords: ['create', 'add'], available: always, run: () => void n.createNote() },
    { id: 'newNoteFromTemplate', title: 'New Note from Template…', icon: 'i-lucide-files', keys: ['alt+shift+mod+n'], keywords: ['template'], available: always, run: () => (state.templatePicker = 'new') },
    { id: 'insertTemplate', title: 'Insert Template…', icon: 'i-lucide-files', keywords: ['template', 'snippet'], available: editable, run: () => (state.templatePicker = 'insert') },
    { id: 'newTemplate', title: 'New Template', icon: 'i-lucide-file-plus-2', keywords: ['template'], available: always, run: () => void n.newTemplate() },
    { id: 'openToday', title: "Today's Note", icon: 'i-lucide-calendar', keys: ['ctrl+mod+t'], keywords: ['daily', 'journal'], available: always, run: () => void n.openToday() },
    { id: 'newNotebook', title: 'New Notebook…', icon: 'i-lucide-folder-plus', keys: ['shift+mod+n', 'alt+shift+mod+b'], keywords: ['folder'], available: always, run: () => (state.notebookDialog = { mode: 'create' }) },
    { id: 'newSmartFolder', title: 'New Smart Folder…', icon: 'i-lucide-folder-search', keywords: ['saved search', 'filter'], available: always, run: () => (state.smartFolderDialog = { mode: 'create' }) },
    {
      id: 'saveSearchAsSmartFolder',
      title: 'Save Search as Smart Folder…',
      icon: 'i-lucide-folder-search',
      keywords: ['saved search', 'filter'],
      available: () => !!state.query.trim(),
      run: () => (state.smartFolderDialog = { mode: 'create', query: state.query.trim() }),
    },
    { id: 'showTasks', title: 'Show Tasks', icon: 'i-lucide-list-checks', keys: ['shift+mod+t', 'alt+shift+mod+t'], keywords: ['todo', 'checkbox', 'due'], available: always, run: () => ((state.view = { kind: 'tasks' }), (state.pane = 'list')) },
    { id: 'searchNotes', title: 'Search Notes', icon: 'i-lucide-search', keys: ['mod+f'], keywords: ['find', 'filter'], available: always, run: () => document.querySelector<HTMLInputElement>('input[aria-label="Search notes"]')?.focus() },
    { id: 'export', title: 'Export Note as Markdown', icon: 'i-lucide-file-down', keys: ['shift+mod+s'], keywords: ['save', 'markdown', 'download'], available: () => !!note(), run: () => exportNote(state.selectedId!, 'markdown') },
    { id: 'import', title: 'Import Markdown Files…', icon: 'i-lucide-file-up', keywords: ['markdown', 'obsidian', 'text', 'md'], available: always, run: () => pickImport(false) },
    { id: 'importFolder', title: 'Import Markdown Folder…', icon: 'i-lucide-folder-up', keywords: ['markdown', 'obsidian', 'vault', 'md'], available: always, run: () => pickImport(true) },
    { id: 'exportHTML', title: 'Export Note as HTML', icon: 'i-lucide-file-code', keywords: ['save', 'html', 'download'], available: () => !!note(), run: () => exportNote(state.selectedId!, 'html') },
    { id: 'print', title: 'Print…', icon: 'i-lucide-printer', keys: ['mod+p'], keywords: ['pdf'], available: () => !!note(), run: () => printNote(state.selectedId!) },
    { id: 'copyMarkdown', title: 'Copy as Markdown', icon: 'i-lucide-clipboard-copy', keys: ['alt+shift+mod+c'], keywords: ['clipboard'], available: () => !!note(), run: () => copyMarkdown(state.selectedId!) },
    { id: 'copyNoteLink', title: 'Copy Note Link', icon: 'i-lucide-link', keys: ['ctrl+mod+l'], keywords: ['url', 'clipboard'], available: live, run: () => copyNoteLink(state.selectedId!) },
    { id: 'find', title: 'Find in Note…', icon: 'i-lucide-text-search', keys: ['alt+mod+f'], keywords: ['search', 'text'], available: () => !!note() && note()!.kind === 'doc', run: () => (state.find = { open: true, replace: false, seq: state.find.seq + 1 }) },
    { id: 'findReplace', title: 'Find and Replace…', icon: 'i-lucide-replace', keys: ['shift+mod+f'], keywords: ['substitute', 'change'], available: editable, run: () => (state.find = { open: true, replace: true, seq: state.find.seq + 1 }) },
    { id: 'setDueDate', title: 'Set Due Date…', icon: 'i-lucide-calendar-clock', keys: ['shift+mod+d'], keywords: ['due', 'deadline', 'task'], available: editable, run: () => void (state.dueDate += 1) },
    { id: 'addReminder', title: 'Add Reminder…', icon: 'i-lucide-bell-plus', keys: ['ctrl+mod+r'], keywords: ['remind', 'alarm', 'notification'], available: editable, run: () => void (state.addReminder += 1) },
    { id: 'linkToNote', title: 'Link to Note…', icon: 'i-lucide-link', keys: ['shift+mod+k'], keywords: ['wiki', 'reference', '[['], available: editable, run: () => void (state.linkToNote += 1) },
    { id: 'showBacklinks', title: 'Show Backlinks', icon: 'i-lucide-link-2', keys: ['alt+mod+i'], keywords: ['links', 'references'], available: live, run: () => inspector('links') },
    { id: 'showOutline', title: 'Show Outline', icon: 'i-lucide-list-tree', keywords: ['headings', 'toc'], available: live, run: () => inspector('outline') },
    { id: 'showNoteInfo', title: 'Show Note Info', icon: 'i-lucide-info', keys: ['ctrl+mod+i'], keywords: ['word count', 'characters', 'reading time', 'statistics'], available: live, run: () => inspector('info') },
    {
      id: 'togglePin',
      title: note()?.isPinned ? 'Unpin Note' : 'Pin Note',
      icon: note()?.isPinned ? 'i-lucide-pin-off' : 'i-lucide-pin',
      keywords: ['favorite'],
      available: live,
      run: () => void n.client().updateNoteMeta(state.selectedId!, { isPinned: !note()!.isPinned }),
    },
    {
      id: 'deleteNote',
      title: 'Delete Note',
      icon: 'i-lucide-trash-2',
      keys: ['mod+backspace'],
      inText: false,
      keywords: ['remove', 'trash'],
      available: live,
      run: () => n.trashNote(state.selectedId!),
    },
    { id: 'showRecentlyDeleted', title: 'Show Recently Deleted', icon: 'i-lucide-trash-2', keywords: ['trash', 'restore'], available: () => state.notes.some((x) => x.deletedAt), run: () => ((state.view = { kind: 'trash' }), (state.pane = 'list')) },
    { id: 'settings', title: 'Settings…', icon: 'i-lucide-sliders-horizontal', keys: ['mod+,'], keywords: ['preferences'], available: always, run: () => (state.settings = true) },
    // Web-only: the browser has no menu bar extra or global hotkeys, and sync runs on its own.
    { id: 'quickCapture', title: 'Open Quick Capture', icon: 'i-lucide-pen-line', keys: ['alt+mod+c'], available: always, run: () => (state.capture = true) },
    { id: 'syncNow', title: 'Sync Now', icon: 'i-lucide-refresh-cw', available: always, run: () => void n.client().syncNow() },
    { id: 'lock', title: 'Lock NoteIt', icon: 'i-lucide-lock', available: always, run: () => void n.lock() },
  ].map((c) => ({ ...c, run: () => (close(), c.run()) })) as WebCommand[];
}

/** Commands that open the palette itself (native ⌘O Open Quickly, ⇧⌘P Command Palette; ⌘K on the web too). */
export const PALETTE_KEYS = ['mod+o', 'shift+mod+p', 'mod+k'];
