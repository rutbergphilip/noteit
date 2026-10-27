<script setup lang="ts">
import { computed, onBeforeUnmount, ref, shallowRef, watch } from 'vue';
import { EditorContent, useEditor } from '@tiptap/vue-3';
import type { Editor } from '@tiptap/core';
import type { DropdownMenuItem } from '@nuxt/ui';
import { dailyNotebook, parseDailyTitle, localDateTimeToken, localFirstWeekday, localFromDate, parseNaturalDate, addAttachment, attachmentTooLargeMessage, markdownForPaste, noteIDForTitle, linkSuggestions, noteLinkURL, WIKI_LINK_OPEN, wikiLink, type LinkTarget, type BodyContainer, HIGHLIGHT_COLORS, isAllowedLink, MAX_ATTACHMENT_BYTES, type NoteItDoc, parseNoteLink, sanitizePastedHtml, TEXT_COLORS } from '@noteit/doc';
import { fromEditorJSON, insertTable as insertTableAt, noteItExtensions, prepareForEditor } from '@noteit/doc/tiptap';
import { useConfirm } from '~/lib/confirm';
import { useNoteit } from '~/composables/useNoteit';
import { copyMarkdown, copyNoteLink, exportNote, printNote } from '~/utils/exporting';
import { formatDateTime } from '~/utils/format';
import { notebookIcon, safeHex } from '~/utils/notebooks';
import { commandKbds } from '~/utils/menuShortcuts';
import type { OpenedNote } from '~/worker/types';
import { useOpeningKey } from '~/utils/overlay';

const props = defineProps<{ noteId: string }>();
const { state, client, toast, refresh, openNote, createNote, trashNote, openDaily } = useNoteit();
const confirm = useConfirm();

const note = shallowRef<OpenedNote>();
const container = shallowRef<BodyContainer>();
const editable = ref(false);
const readOnlyReason = ref<string>();
const saveState = ref<'saved' | 'saving' | 'unsaved'>('saved');
const urls = new Map<string, string>();
let saveTimer: ReturnType<typeof setTimeout> | undefined;
let lastSaved = '';
/** The revision the editor's content is based on; a save from an older base makes a conflict copy, never an overwrite. */
let baseRevision: string | undefined;
/** The doc as typed, for the Links and Outline panel (word count updates as you type). */
const liveDoc = shallowRef<NoteItDoc>();
let liveTimer: ReturnType<typeof setTimeout> | undefined;

function attachmentUrl(sha: string): string | undefined {
  const cached = urls.get(sha);
  if (cached) return cached;
  const entry = container.value?.attachments[sha];
  if (!entry) return undefined;
  const bin = atob(entry.data);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  // Only image types render inline; anything else is served as a plain download.
  const type = /^image\/(png|jpe?g|gif|webp|avif|bmp)$/.test(entry.mime) ? entry.mime : 'application/octet-stream';
  const url = URL.createObjectURL(new Blob([bytes], { type }));
  urls.set(sha, url);
  return url;
}

const editor = useEditor({
  extensions: noteItExtensions({
    resolver: { url: attachmentUrl },
    wikiLink: (inner) => wikiLink(inner, { notes: state.notes, noteID: props.noteId, noteTitle: row.value?.title ?? '', ...(row.value?.notebookID ? { notebookID: row.value.notebookID } : {}) }),
  }),
  editable: false,
  content: { type: 'doc', content: [{ type: 'paragraph' }] },
  editorProps: {
    // The `[[` list takes ↑ ↓ (⌃P ⌃N), ↩ or Tab and Esc while it's open.
    handleKeyDown: (_view, e) => {
      // ⇧⌘V / ⌥⇧⌘V: Paste and Match Style, so the next paste stays plain text.
      if (e.code === 'KeyV' && e.shiftKey && (e.metaKey || e.ctrlKey)) plainPaste = true;
      return linkListKey(e);
    },
    attributes: { class: 'ni-prose', 'aria-label': 'Note' },
    transformPastedHTML: (html) => sanitizePastedHtml(html),
    handlePaste: (view, event) => {
      const files = [...(event.clipboardData?.files ?? [])];
      if (files.length) {
        void insertFiles(files);
        return true;
      }
      const plain = plainPaste;
      plainPaste = false;
      return pasteMarkdown(view.state.selection.$from.parent.type.name === 'codeBlock' || plain, event.clipboardData);
    },
    handleDOMEvents: {
      // noteit://note links open the note here (or create it, for a link by title to a note that doesn't exist).
      click: (_view, event) => {
        const a = (event.target as HTMLElement | null)?.closest?.('a[href^="noteit:"]');
        if (!a) return false;
        event.preventDefault();
        void followNoteLink(a.getAttribute('href') ?? '');
        return true;
      },
    },
    handleDrop: (_view, event) => {
      const files = [...((event as DragEvent).dataTransfer?.files ?? [])];
      if (!files.length) return false;
      void insertFiles(files);
      return true;
    },
  },
  // Typing opens the `[[` list; moving the caret only updates or closes an open one, so a body loaded or restored
  // with `[[` at its end doesn't pop it up (native opens completions on typing).
  onSelectionUpdate: () => linkList.value && updateLinkList(),
  onUpdate: () => {
    updateLinkList();
    scheduleSave();
    if (liveTimer) clearTimeout(liveTimer);
    liveTimer = setTimeout(() => editor.value && (liveDoc.value = fromEditorJSON(editor.value.getJSON())), 250);
  },
});

/** The editor while it's mounted: after unmount useEditor keeps the destroyed instance, whose `commands` throw. */
function liveEditor(): typeof editor.value {
  const ed = editor.value;
  return ed && !ed.isDestroyed ? ed : undefined;
}

// MARK: `[[` note suggestions and Link to Note… (native InlineCompletionController / LinkCompletionSource)

const linkList = ref<{ from: number; typed: string; items: LinkTarget[]; index: number; x: number; y: number; above: boolean }>();
const LINK_LIST_WIDTH = 288;
const LINK_LIST_MAX_HEIGHT = 256;
/** Where Link to Note… put its `[[`, while its list is open: closing the list without a choice takes them out again. */
let insertedOpening: number | undefined;
/** Closes the `[[` list as Esc does (native InlineCompletionController.cancel / LinkCompletionSource.didCancel). */
function closeLinkList(): void {
  linkList.value = undefined;
  const at = insertedOpening;
  insertedOpening = undefined;
  const ed = liveEditor();
  if (at === undefined || !ed || at + 2 > ed.state.doc.content.size) return;
  // Only while they are still there: an undo may have taken them out already.
  if (ed.state.doc.textBetween(at, at + 2) !== '[[') return;
  ed.view.dispatch(ed.state.tr.delete(at, at + 2));
}
function updateLinkList(): void {
  const ed = liveEditor();
  if (!ed || !editable.value) return closeLinkList();
  const { $from, empty } = ed.state.selection;
  const parent = $from.parent;
  if (!empty || parent.type.name === 'codeBlock' || ed.isActive('code')) return closeLinkList();
  const prefix = parent.textBetween(0, $from.parentOffset, undefined, '\ufffc');
  const m = WIKI_LINK_OPEN.exec(prefix);
  if (!m) return closeLinkList();
  const typed = m[1]!;
  const items = linkSuggestions(state.notes, typed, { exclude: props.noteId });
  const from = $from.start() + m.index;
  const at = ed.view.coordsAtPos(from);
  const keep = linkList.value?.from === from ? Math.min(linkList.value.index, Math.max(0, items.length - 1)) : 0;
  // Kept inside the window: shifted left at the right edge, and flipped above the line near the bottom.
  const x = Math.max(8, Math.min(at.left, window.innerWidth - LINK_LIST_WIDTH - 8));
  const above = at.bottom + 4 + LINK_LIST_MAX_HEIGHT > window.innerHeight - 8 && at.top - 4 - LINK_LIST_MAX_HEIGHT >= 8;
  linkList.value = { from, typed, items, index: keep, x, y: above ? at.top - 4 : at.bottom + 4, above };
}
function chooseLink(target: LinkTarget): void {
  const ed = liveEditor();
  const list = linkList.value;
  if (!ed || !list) return;
  const heading = list.typed.includes('#') ? list.typed.slice(list.typed.indexOf('#') + 1).split('|')[0]!.trim() : '';
  const href = noteLinkURL({ id: target.id, ...(heading ? { heading } : {}) });
  const text = heading ? `${target.title} › ${heading}` : target.title;
  const to = ed.state.selection.from;
  linkList.value = undefined;
  insertedOpening = undefined;
  ed.chain()
    .focus()
    .insertContentAt({ from: list.from, to }, [{ type: 'text', text, marks: [{ type: 'link', attrs: { href } }] }])
    .unsetMark('link')
    .run();
}
function linkListKey(e: KeyboardEvent): boolean {
  const list = linkList.value;
  if (!list) return false;
  const move = (by: number) => {
    if (list.items.length) list.index = (list.index + by + list.items.length) % list.items.length;
    return true;
  };
  if (e.key === 'ArrowDown' || (e.ctrlKey && e.key === 'n')) return move(1);
  if (e.key === 'ArrowUp' || (e.ctrlKey && e.key === 'p')) return move(-1);
  if ((e.key === 'Enter' || e.key === 'Tab') && list.items[list.index]) {
    chooseLink(list.items[list.index]!);
    return true;
  }
  if (e.key === 'Escape') {
    closeLinkList();
    return true;
  }
  return false;
}

/** Link to Note… (⇧⌘K): types `[[` at the caret (around the selection's text) and opens the list. */
function linkToNote(): void {
  const ed = liveEditor();
  if (!ed || !editable.value) return;
  const { from, to, empty } = ed.state.selection;
  const selected = empty ? '' : ed.state.doc.textBetween(from, to, ' ');
  ed.chain().focus().insertContentAt({ from, to }, `[[${selected.replace(/[[\]\n]/g, ' ')}`).run();
  updateLinkList();
  if (linkList.value) insertedOpening = from;
}
watch(
  () => state.linkToNote,
  (n) => {
    if (!n) return;
    state.linkToNote = 0;
    linkToNote();
  },
);

// MARK: pasting Markdown (native MarkdownPaste): clearly-Markdown plain text comes in formatted; HTML from a web page
// keeps its own formatting, and code blocks and Paste and Match Style take the text as it is.

let plainPaste = false;
function pasteMarkdown(asText: boolean, data: DataTransfer | null): boolean {
  const ed = liveEditor();
  const text = data?.getData('text/plain') ?? '';
  if (asText || !ed || !text || data?.types.includes('text/html')) return false;
  const pasted = markdownForPaste(text, { resolveNoteLink: (title) => noteIDForTitle(state.notes, title, row.value?.notebookID) });
  if (!pasted) return false;
  const content = prepareForEditor({ format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content: pasted.blocks } }).doc.content as unknown[];
  if (pasted.inline) {
    const inline = (content[0] as { content?: unknown[] } | undefined)?.content ?? [];
    return ed.chain().focus().insertContent(inline as never).run();
  }
  const blocks = pasted.endsWithNewline ? [...content, { type: 'paragraph' }] : content;
  return ed.chain().focus().insertContent(blocks as never).run();
}

// MARK: Set Due Date… (native DatePopover for the checklist item under the cursor)

const due = ref<{ kind: 'due' | 'remind'; date: string; time: string; pos: number }>();
watch(
  () => state.dueDate,
  (n) => {
    if (!n) return;
    const ed = liveEditor();
    if (!ed || !editable.value) return;
    const { $from } = ed.state.selection;
    const item = $from.parent;
    if (item.type.name !== 'listItem' || item.attrs.kind !== 'task') return toast('Put the cursor on a checklist item to give it a due date.');
    const existing = /@due\((\d{4}-\d{2}-\d{2})(?: (\d{2}:\d{2}))?\)/.exec(item.textContent);
    const today = localDateTimeToken(localFromDate(new Date(), false));
    due.value = { kind: 'due', date: existing?.[1] ?? today, time: existing?.[2] ?? '', pos: $from.before() };
  },
);
// Add Reminder… (⌃⌘R): the line's own date ("call Bo tomorrow 3pm") when it has one, else the picker at 09:00.
watch(
  () => state.addReminder,
  (n) => {
    if (!n) return;
    const ed = liveEditor();
    if (!ed || !editable.value) return;
    const { $from } = ed.state.selection;
    if (!$from.parent.isTextblock || $from.parent.type.name === 'codeBlock') return;
    const pos = $from.before();
    const line = $from.parent.textContent.replace(/@remind\([^()\n]*\)/g, '');
    const found = parseNaturalDate(line, new Date(), { defaultHour: 9, firstWeekday: localFirstWeekday() });
    const existing = /@remind\((\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})/.exec($from.parent.textContent);
    if (found && !existing) {
      due.value = { kind: 'remind', date: '', time: '', pos };
      return applyDue(localDateTimeToken(found.value));
    }
    due.value = { kind: 'remind', date: existing?.[1] ?? localDateTimeToken(localFromDate(new Date(Date.now() + 86_400_000), false)), time: existing?.[2] ?? '09:00', pos };
  },
);
function dayToken(offset: number): string {
  return localDateTimeToken(localFromDate(new Date(Date.now() + offset * 86_400_000), false));
}
/** Writes `@due(…)` into the item: replaces the one there, else adds it at the end; empty removes it. */
function applyDue(token: string | undefined): void {
  const ed = liveEditor();
  const d = due.value;
  due.value = undefined;
  if (!ed || !d) return;
  const node = ed.state.doc.nodeAt(d.pos);
  if (!node || !node.isTextblock) return;
  const text = node.textBetween(0, node.content.size, undefined, '\ufffc');
  const name = d.kind;
  const m = (name === 'due' ? /\s?@due\([^()\n]*\)/ : /\s?@remind\([^()\n]*\)/).exec(text);
  const start = d.pos + 1;
  const tr = ed.state.tr;
  if (m) {
    if (token) tr.insertText(`${m[0].startsWith(' ') ? ' ' : ''}@${name}(${token})`, start + m.index, start + m.index + m[0].length);
    else tr.delete(start + m.index, start + m.index + m[0].length);
  } else if (token) {
    tr.insertText(`${text && !text.endsWith(' ') ? ' ' : ''}@${name}(${token})`, start + node.content.size);
  }
  ed.view.dispatch(tr);
  ed.commands.focus();
}

async function followNoteLink(href: string): Promise<void> {
  const link = parseNoteLink(href);
  if (!link) return;
  if ('id' in link) {
    const target = state.notes.find((n) => n.id.toUpperCase() === link.id);
    if (target) openNote(target.id);
    else toast("That note isn't in this library (it may have been deleted).");
    return;
  }
  const byTitle = state.notes.find((n) => !n.deletedAt && n.title.toLowerCase() === link.title.toLowerCase());
  if (byTitle) return openNote(byTitle.id);
  await createNote({ format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: link.title }] }, { type: 'paragraph' }] } });
}

/** Scrolls to a top-level block (Outline). */
function jumpTo(block: number): void {
  const ed = liveEditor();
  if (!ed) return;
  let pos = 0;
  for (let i = 0; i < block && i < ed.state.doc.childCount; i++) pos += ed.state.doc.child(i).nodeSize;
  ed.chain().focus().setTextSelection(pos + 1).scrollIntoView().run();
}

// Insert Template…: the picker leaves the expanded template here; it goes in at the caret.
watch(
  () => state.pendingInsert,
  (c) => {
    const ed = liveEditor();
    if (!c || !ed || !container.value || !editable.value) return;
    state.pendingInsert = undefined;
    Object.assign(container.value.attachments, c.attachments);
    ed.chain().focus().insertContent(prepareForEditor(c).doc.content ?? []).run();
    scheduleSave();
  },
);

async function load(): Promise<void> {
  const opened = await client().getNote(props.noteId);
  note.value = opened;
  if (!opened) return;
  baseRevision = opened.row.revision;
  container.value = opened.container;
  readOnlyReason.value = opened.readOnly;
  const ed = liveEditor();
  if (!ed) return;
  if (opened.container && !opened.readOnly) {
    const prepared = prepareForEditor(opened.container);
    editable.value = prepared.editable;
    if (!prepared.editable) readOnlyReason.value = prepared.reason;
    ed.commands.setContent(prepared.doc, { emitUpdate: false });
    lastSaved = JSON.stringify(opened.container.doc);
    liveDoc.value = opened.container.doc;
  } else if (opened.container) {
    const prepared = prepareForEditor(opened.container);
    editable.value = false;
    ed.commands.setContent(prepared.doc, { emitUpdate: false });
  } else {
    editable.value = false;
    ed.commands.setContent({ type: 'doc', content: [{ type: 'paragraph' }] }, { emitUpdate: false });
  }
  ed.setEditable(editable.value && !row.value?.deletedAt);
  if (editable.value && !row.value?.title) ed.commands.focus('end');
}

const row = computed(() => state.notes.find((n) => n.id === props.noteId) ?? note.value?.row);
const notebook = computed(() => state.notebooks.find((n) => n.id === row.value?.notebookID));
/** A daily note (titled with its day, in the daily notebook) gets ‹ › to the days around it. */
const dailyDay = computed(() => {
  const r = row.value;
  if (!r || r.deletedAt || r.notebookID !== dailyNotebook(state.notebooks, state.notes)) return undefined;
  return parseDailyTitle(r.title);
});
function openDailyOffset(days: number): void {
  const d = dailyDay.value;
  if (d) void openDaily(new Date(d.year, d.month - 1, d.day + days, 12));
}
const edited = computed(() => (row.value ? formatDateTime(row.value.updatedAt) : ''));

function scheduleSave(): void {
  if (!editable.value) return;
  saveState.value = 'unsaved';
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => void save(), 600);
}

/** Saves run one after another: two in flight from the same base would read as a conflict with ourselves. */
let saving: Promise<void> = Promise.resolve();
function save(): Promise<void> {
  saving = saving.then(saveNow, saveNow);
  return saving;
}

async function saveNow(): Promise<void> {
  saveTimer = undefined;
  const ed = liveEditor();
  if (!ed || !container.value || !editable.value) return;
  const doc = fromEditorJSON(ed.getJSON());
  const json = JSON.stringify(doc);
  if (json === lastSaved) {
    saveState.value = 'saved';
    return;
  }
  saveState.value = 'saving';
  const next: BodyContainer = { ...container.value, doc };
  try {
    const saved = await client().saveNote(props.noteId, next, baseRevision);
    baseRevision = saved.revision;
    container.value = next;
    lastSaved = json;
    saveState.value = 'saved';
    if (saved.conflictCopy) toast('This note was changed somewhere else while you typed. That version is kept as a conflict copy.');
  } catch (e) {
    saveState.value = 'unsaved';
    toast(e instanceof Error ? e.message : 'Could not save');
  }
}

// A new revision of this note (a pull, or another tab's save) reloads it in place while nothing is pending. With an
// edit pending, the save notices the newer base and keeps the other version as a conflict copy.
watch(
  () => row.value?.revision,
  async (now) => {
    if (!now || now === baseRevision || saveTimer || saveState.value !== 'saved') return;
    const opened = await client().getNote(props.noteId);
    if (!opened || saveTimer || saveState.value !== 'saved') return;
    if (opened.container && JSON.stringify(opened.container.doc) === lastSaved) baseRevision = opened.row.revision;
    else await load();
  },
);

watch(editor, (ed) => ed && void load(), { immediate: true });

/** Saves a pending edit now instead of after the debounce. */
function flush(): void {
  if (!saveTimer) return;
  clearTimeout(saveTimer);
  void save();
}

// Leaving or hiding the page saves at once: the debounce would otherwise drop an edit typed just before a reload.
// beforeunload also asks to stay while that save is still on its way to the library.
function onBeforeUnload(e: BeforeUnloadEvent): void {
  flush();
  if (saveState.value === 'saved') return;
  e.preventDefault();
  e.returnValue = '';
}
const onHidden = () => document.visibilityState === 'hidden' && flush();
window.addEventListener('beforeunload', onBeforeUnload);
window.addEventListener('noteit:flush', flush);
document.addEventListener('visibilitychange', onHidden);

onBeforeUnmount(() => {
  window.removeEventListener('beforeunload', onBeforeUnload);
  window.removeEventListener('noteit:flush', flush);
  document.removeEventListener('visibilitychange', onHidden);
  flush();
  for (const url of urls.values()) URL.revokeObjectURL(url);
});

async function insertFiles(files: File[]): Promise<void> {
  const ed = liveEditor();
  if (!ed || !container.value || !editable.value) return;
  for (const file of files) {
    if (file.size > MAX_ATTACHMENT_BYTES) {
      toast(attachmentTooLargeMessage(file.name));
      continue;
    }
    const bytes = new Uint8Array(await file.arrayBuffer());
    const mime = file.type || 'application/octet-stream';
    const sha = addAttachment(container.value, bytes, file.name || 'Attachment', mime);
    const isImage = /^image\/(png|jpe?g|gif|webp|avif)$/.test(mime);
    ed.chain().focus().insertContent({ type: isImage ? 'image' : 'attachment', attrs: { sha, name: file.name || 'Attachment', mime } }).run();
  }
  scheduleSave();
}

const fileInput = ref<HTMLInputElement>();
function pickFile(): void {
  fileInput.value?.click();
}
async function onFiles(e: Event): Promise<void> {
  const input = e.target as HTMLInputElement;
  await insertFiles([...(input.files ?? [])]);
  input.value = '';
}

// MARK: toolbar

type Block = 'paragraph' | 'h1' | 'h2' | 'h3' | 'code' | 'quote';
const blockType = computed<Block>(() => {
  const ed = liveEditor();
  if (!ed) return 'paragraph';
  void state.selectedId;
  if (ed.isActive('heading', { level: 1 })) return 'h1';
  if (ed.isActive('heading', { level: 2 })) return 'h2';
  if (ed.isActive('heading', { level: 3 })) return 'h3';
  if (ed.isActive('codeBlock')) return 'code';
  if (ed.isActive('blockquote')) return 'quote';
  return 'paragraph';
});

const BLOCKS: { value: Block; label: string }[] = [
  { value: 'paragraph', label: 'Body' },
  { value: 'h1', label: 'Title' },
  { value: 'h2', label: 'Heading' },
  { value: 'h3', label: 'Subheading' },
  { value: 'code', label: 'Code Block' },
  { value: 'quote', label: 'Quote' },
];

function setBlock(v: Block): void {
  const ed = liveEditor() as Editor | undefined;
  if (!ed || v === blockType.value) return;
  const chain = ed.chain().focus();
  if (ed.isActive('blockquote')) chain.lift('blockquote');
  if (v === 'paragraph') chain.setNode('paragraph').run();
  else if (v === 'code') chain.setNode('codeBlock').unsetMark('fontSize').unsetMark('highlight').unsetMark('bold').unsetMark('italic').run();
  else if (v === 'quote') chain.setNode('paragraph').wrapIn('blockquote').run();
  else chain.setNode('heading', { level: Number(v.slice(1)) }).run();
}

const mark = (name: string) => editor.value?.chain().focus().toggleMark(name).run();
const active = (name: string, attrs?: Record<string, unknown>) => !!editor.value?.isActive(name, attrs);

function toggleList(kind: 'bullet' | 'ordered' | 'task'): void {
  const ed = liveEditor();
  if (!ed) return;
  if (ed.isActive('listItem', { kind })) ed.chain().focus().setNode('paragraph').run();
  else ed.chain().focus().setNode('listItem', { kind, level: 0, number: kind === 'ordered' ? 1 : null, checked: kind === 'task' ? false : null }).run();
}

function insertTable(): void {
  const ed = liveEditor();
  if (ed) insertTableAt(ed);
}

const linkOpen = ref(false);
const linkHref = ref('');
const linkError = ref('');
watch(linkOpen, (open) => {
  if (!open) return;
  linkHref.value = (editor.value?.getAttributes('link').href as string | undefined) ?? 'https://';
  linkError.value = '';
});
function applyLink(): void {
  const ed = liveEditor();
  if (!ed) return;
  const href = linkHref.value.trim();
  if (href && !isAllowedLink(href)) {
    linkError.value = 'Links can be https, http, mailto, tel or noteit://note links.';
    return;
  }
  if (href) ed.chain().focus().setMark('link', { href }).run();
  else ed.chain().focus().unsetMark('link').run();
  linkOpen.value = false;
}

// Native's Format menu colours, so a colour picked here is the same swatch on the Mac.
const COLORS = TEXT_COLORS.map((c) => c.hex);
const HIGHLIGHTS = HIGHLIGHT_COLORS.map((c) => c.hex);
const colorMenu = ref<'text' | 'highlight'>();
function applyColor(kind: 'textColor' | 'highlight', color: string | undefined): void {
  const chain = editor.value?.chain().focus();
  if (!chain) return;
  if (color) chain.setMark(kind, { color: safeHex(color) }).run();
  else chain.unsetMark(kind).run();
  colorMenu.value = undefined;
}

/** Toolbar buttons: the mark/list name for aria-pressed, a Lucide icon and the shortcut TipTap binds. */
const MARKS = [
  { mark: 'bold', label: 'Bold', icon: 'i-lucide-bold', kbds: ['meta', 'B'] },
  { mark: 'italic', label: 'Italic', icon: 'i-lucide-italic', kbds: ['meta', 'I'] },
  { mark: 'underline', label: 'Underline', icon: 'i-lucide-underline', kbds: ['meta', 'U'] },
  { mark: 'strike', label: 'Strikethrough', icon: 'i-lucide-strikethrough', kbds: ['meta', 'shift', 'X'] },
] as const;
const LISTS = [
  { kind: 'bullet', label: 'Bulleted list', icon: 'i-lucide-list' },
  { kind: 'ordered', label: 'Numbered list', icon: 'i-lucide-list-ordered' },
  { kind: 'task', label: 'Checklist', icon: 'i-lucide-list-checks' },
] as const;

// MARK: note actions

async function togglePin(): Promise<void> {
  if (row.value) await client().updateNoteMeta(props.noteId, { isPinned: !row.value.isPinned });
}
const notebookChoices = computed(() => [
  { label: 'No Notebook', value: NO_NOTEBOOK, icon: 'i-lucide-circle-dashed' },
  ...state.notebooks.map((nb) => ({ label: nb.name || 'Untitled', value: nb.id, icon: notebookIcon(nb.symbol) })),
]);
/** Reka's Select can't hold an empty value, so "no notebook" has a sentinel. */
const NO_NOTEBOOK = 'none';
async function move(v: string): Promise<void> {
  const notebookID = v === NO_NOTEBOOK ? null : v;
  if (notebookID === (row.value?.notebookID ?? null)) return;
  await client().updateNoteMeta(props.noteId, { notebookID });
}
async function trash(): Promise<void> {
  flush();
  await save();
  await trashNote(props.noteId);
}
async function recover(): Promise<void> {
  await client().updateNoteMeta(props.noteId, { trashed: false });
  await refresh();
  await load();
}
async function deleteForever(): Promise<void> {
  if (!(await confirm({ title: 'Delete this note for good?', description: 'It is removed from all your devices.', confirmLabel: 'Delete', danger: true }))) return;
  await client().deleteForever(props.noteId);
  state.selectedId = undefined;
  state.pane = 'list';
}
const shareItems = computed<DropdownMenuItem[][]>(() => [
  [
    { label: 'Export as Markdown', icon: 'i-lucide-file-down', kbds: commandKbds('exportNote'), onSelect: () => void exportNote(props.noteId, 'markdown') },
    { label: 'Export as HTML', icon: 'i-lucide-file-code', onSelect: () => void exportNote(props.noteId, 'html') },
    { label: 'Print or Save as PDF…', icon: 'i-lucide-printer', kbds: commandKbds('print'), onSelect: () => void printNote(props.noteId) },
    { label: 'Download NoteIt Document', icon: 'i-lucide-download', onSelect: () => void exportNote(props.noteId, 'noteitdoc') },
  ],
  [
    { label: 'Copy as Markdown', icon: 'i-lucide-clipboard-copy', kbds: commandKbds('copyAsMarkdown'), onSelect: () => void copyMarkdown(props.noteId) },
    { label: 'Copy Note Link', icon: 'i-lucide-link', kbds: commandKbds('copyNoteLink'), onSelect: () => void copyNoteLink(props.noteId) },
  ],
]);

const narrowQuery = typeof window !== 'undefined' ? window.matchMedia('(max-width: 1023px)') : undefined;
const narrow = ref(!!narrowQuery?.matches);
const onNarrow = (e: MediaQueryListEvent) => (narrow.value = e.matches);
narrowQuery?.addEventListener('change', onNarrow);
onBeforeUnmount(() => {
  narrowQuery?.removeEventListener('change', onNarrow);
  if (liveTimer) clearTimeout(liveTimer);
});
// Fresh portals per opening, so these show above the sidebar drawer (see useOpeningKey).
const duePortalKey = useOpeningKey(() => due.value);
const inspectorPortalKey = useOpeningKey(() => state.inspector.open && narrow.value);
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <div class="flex flex-wrap items-center gap-3 border-b border-default px-6 py-3 max-md:px-3 max-md:py-2">
      <UButton class="md:hidden" color="neutral" variant="ghost" icon="i-lucide-chevron-left" aria-label="Back to notes" @click="state.pane = 'list'" />
      <USelect
        :model-value="row?.notebookID ?? NO_NOTEBOOK"
        :items="notebookChoices"
        :disabled="!!row?.deletedAt"
        size="xs"
        variant="none"
        aria-label="Notebook"
        class="h-[26px] max-w-[200px] rounded-full"
        :style="{ background: notebook ? `color-mix(in srgb, ${safeHex(notebook.colorHex)} 16%, transparent)` : 'var(--fill)' }"
        :ui="{ base: 'py-0 ps-5 pe-6 text-xs font-semibold', leading: 'ps-2.5', trailing: 'pe-1.5', content: 'min-w-48' }"
        @update:model-value="(v) => move(String(v))"
      >
        <template #leading><span class="size-2 rounded-full" :style="{ background: notebook ? safeHex(notebook.colorHex) : 'var(--ink3)' }" /></template>
      </USelect>
      <span class="text-xs text-muted">Edited {{ edited }}</span>
      <span v-if="dailyDay" class="flex items-center">
        <UTooltip text="Previous day"><UButton color="neutral" variant="ghost" size="xs" icon="i-lucide-chevron-left" aria-label="Previous day's note" @click="openDailyOffset(-1)" /></UTooltip>
        <UTooltip text="Next day"><UButton color="neutral" variant="ghost" size="xs" icon="i-lucide-chevron-right" aria-label="Next day's note" @click="openDailyOffset(1)" /></UTooltip>
      </span>
      <div class="ms-auto flex gap-1">
        <template v-if="row?.deletedAt">
          <UButton color="neutral" variant="soft" size="sm" icon="i-lucide-rotate-ccw" label="Recover" @click="recover" />
          <UButton color="error" size="sm" label="Delete Now" @click="deleteForever" />
        </template>
        <template v-else>
          <UTooltip :text="row?.isPinned ? 'Unpin' : 'Pin'">
            <UButton
              color="neutral"
              variant="ghost"
              icon="i-lucide-pin"
              :class="row?.isPinned ? 'text-(--pinned)' : 'text-muted'"
              :aria-label="row?.isPinned ? 'Unpin' : 'Pin'"
              :aria-pressed="!!row?.isPinned"
              @click="togglePin"
            />
          </UTooltip>
          <UTooltip text="Links and Outline" :kbds="commandKbds('toggleInspector')">
            <UButton
              color="neutral"
              variant="ghost"
              icon="i-lucide-panel-right"
              aria-label="Links and Outline"
              :aria-pressed="state.inspector.open"
              :class="state.inspector.open ? 'text-(--acct)' : 'text-muted'"
              @click="state.inspector.open = !state.inspector.open"
            />
          </UTooltip>
          <UDropdownMenu :items="shareItems" :content="{ align: 'end' }">
            <UButton color="neutral" variant="ghost" class="text-muted" icon="i-lucide-share" aria-label="Export and share" :disabled="!container" />
          </UDropdownMenu>
          <UTooltip text="Move to Recently Deleted">
            <UButton color="neutral" variant="ghost" class="text-muted" icon="i-lucide-trash-2" aria-label="Move to Recently Deleted" @click="trash" />
          </UTooltip>
        </template>
      </div>
    </div>

    <div
      v-if="editable && !row?.deletedAt"
      class="flex flex-wrap items-center gap-0.5 border-b border-default px-5 py-2 max-md:flex-nowrap max-md:overflow-x-auto max-md:px-2 max-md:py-1.5"
      role="toolbar"
      aria-label="Formatting"
    >
      <USelect :model-value="blockType" :items="BLOCKS" size="sm" variant="soft" aria-label="Text style" class="w-32 flex-none bg-(--fill)" @update:model-value="(v) => setBlock(v as Block)" />
      <USeparator orientation="vertical" class="mx-1.5 h-[18px]" />
      <UTooltip v-for="m in MARKS" :key="m.mark" :text="m.label" :kbds="[...m.kbds]">
        <UButton color="neutral" variant="ghost" size="sm" square class="size-[30px] justify-center" :icon="m.icon" :aria-label="m.label" :aria-pressed="active(m.mark)" :class="active(m.mark) && 'bg-(--sel) text-(--acct)'" @click="mark(m.mark)" />
      </UTooltip>
      <UTooltip text="Inline code" :kbds="['shift', 'meta', 'E']">
        <UButton color="neutral" variant="ghost" size="sm" icon="i-lucide-code" aria-label="Inline code" :aria-pressed="active('code')" :class="active('code') && 'bg-(--sel) text-(--acct)'" :disabled="active('codeBlock')" @click="mark('code')" />
      </UTooltip>
      <USeparator orientation="vertical" class="mx-1.5 h-[18px]" />
      <UPopover :open="colorMenu === 'text'" @update:open="(o) => (colorMenu = o ? 'text' : undefined)">
        <UTooltip text="Text color">
          <UButton color="neutral" variant="ghost" size="sm" icon="i-lucide-baseline" aria-label="Text color" />
        </UTooltip>
        <template #content>
          <div class="flex gap-1.5 p-2">
            <button v-for="c in COLORS" :key="c" type="button" class="size-[22px] cursor-pointer rounded-full ring-1 ring-(--line) hover:scale-110 transition-transform" :aria-label="`Color ${c}`" :style="{ background: c }" @click="applyColor('textColor', c)" />
            <UButton color="neutral" variant="outline" size="xs" class="size-[22px] justify-center rounded-full p-0" icon="i-lucide-x" aria-label="No color" @click="applyColor('textColor', undefined)" />
          </div>
        </template>
      </UPopover>
      <UPopover :open="colorMenu === 'highlight'" @update:open="(o) => (colorMenu = o ? 'highlight' : undefined)">
        <UTooltip text="Highlight">
          <UButton color="neutral" variant="ghost" size="sm" icon="i-lucide-highlighter" aria-label="Highlight" />
        </UTooltip>
        <template #content>
          <div class="flex gap-1.5 p-2">
            <button v-for="c in HIGHLIGHTS" :key="c" type="button" class="size-[22px] cursor-pointer rounded-full ring-1 ring-(--line) hover:scale-110 transition-transform" :aria-label="`Highlight ${c}`" :style="{ background: c }" @click="applyColor('highlight', c)" />
            <UButton color="neutral" variant="outline" size="xs" class="size-[22px] justify-center rounded-full p-0" icon="i-lucide-x" aria-label="No highlight" @click="applyColor('highlight', undefined)" />
          </div>
        </template>
      </UPopover>
      <USeparator orientation="vertical" class="mx-1.5 h-[18px]" />
      <UTooltip v-for="l in LISTS" :key="l.kind" :text="l.label">
        <UButton
          color="neutral"
          variant="ghost"
          size="sm"
          :icon="l.icon"
          :aria-label="l.label"
          :aria-pressed="active('listItem', { kind: l.kind })"
          :class="active('listItem', { kind: l.kind }) && 'bg-(--sel) text-(--acct)'"
          @click="toggleList(l.kind)"
        />
      </UTooltip>
      <UTooltip text="Table">
        <UButton color="neutral" variant="ghost" size="sm" icon="i-lucide-table" aria-label="Table" @click="insertTable" />
      </UTooltip>
      <UPopover v-model:open="linkOpen">
        <UTooltip text="Link">
          <UButton color="neutral" variant="ghost" size="sm" icon="i-lucide-link" aria-label="Link" :aria-pressed="active('link')" :class="active('link') && 'bg-(--sel) text-(--acct)'" />
        </UTooltip>
        <template #content>
          <form class="flex w-80 flex-col gap-2 p-3" @submit.prevent="applyLink">
            <UFormField label="Link address" :error="linkError || undefined" help="https://, mailto:, tel: or noteit://note/… Leave empty to remove.">
              <UInput v-model="linkHref" autofocus size="sm" spellcheck="false" autocapitalize="none" />
            </UFormField>
            <div class="flex justify-end gap-2">
              <UButton color="neutral" variant="ghost" size="xs" label="Cancel" @click="linkOpen = false" />
              <UButton type="submit" size="xs" label="Apply" />
            </div>
          </form>
        </template>
      </UPopover>
      <UTooltip text="Image or file">
        <UButton color="neutral" variant="ghost" size="sm" icon="i-lucide-image" aria-label="Image or file" @click="pickFile" />
      </UTooltip>
      <input ref="fileInput" type="file" multiple hidden @change="onFiles" />
      <span class="ms-auto flex-none ps-2 text-xs text-muted transition-opacity" :class="saveState === 'saving' && 'opacity-60'">{{ saveState === 'saved' ? 'Saved' : saveState === 'saving' ? 'Saving…' : 'Edited' }}</span>
    </div>

    <FindBar :editor="editor" :can-replace="editable && !row?.deletedAt" />

    <div v-if="readOnlyReason || row?.conflictSource" class="flex flex-col gap-2 px-6 pt-3">
      <UAlert
        v-if="readOnlyReason === 'legacy'"
        color="warning"
        variant="subtle"
        icon="i-lucide-triangle-alert"
        description="Formatted on an older Mac — open NoteIt on macOS to convert. You can still pin, move or delete it here."
      />
      <UAlert v-else-if="readOnlyReason === 'locked'" color="warning" variant="subtle" icon="i-lucide-lock" description="This note is locked. Unlock it in NoteIt on your Mac." />
      <UAlert
        v-else-if="readOnlyReason"
        color="warning"
        variant="subtle"
        icon="i-lucide-triangle-alert"
        :description="`This note uses something this version of NoteIt web can't edit yet, so it opens read-only (${readOnlyReason}).`"
      />
      <UAlert
        v-if="row?.conflictSource"
        color="warning"
        variant="subtle"
        icon="i-lucide-copy"
        :description="`This is a conflict copy: the note was changed on ${row.conflictSource} and here at the same time. Keep the parts you need, then delete the copy.`"
      />
    </div>

    <div class="flex min-h-0 flex-1">
      <article class="page min-w-0 flex-1 overflow-y-auto">
        <h2 v-if="row?.kind === 'legacy' || row?.kind === 'locked'" class="ro-title">{{ row.title || 'Untitled' }}</h2>
        <p v-if="row?.kind === 'legacy' && row.preview" class="ro-preview">{{ row.preview }}</p>
        <EditorContent v-show="row?.kind === 'doc'" :editor="editor" />
        <div
          v-if="linkList"
          class="fixed z-50 max-h-64 w-72 max-w-[calc(100vw-16px)] overflow-y-auto rounded-lg bg-default py-1 text-sm shadow-lg ring ring-default"
          :class="linkList.above && '-translate-y-full'"
          :style="{ left: `${linkList.x}px`, top: `${linkList.y}px` }"
          role="listbox"
          aria-label="Link to note"
        >
          <p v-if="!linkList.items.length" class="px-3 py-1.5 text-muted">No matching notes. Type ]] to link by title.</p>
          <button
            v-for="(n, i) in linkList.items"
            :key="n.id"
            type="button"
            role="option"
            :aria-selected="i === linkList.index"
            class="flex w-full items-center gap-2 px-3 py-1.5 text-left"
            :class="i === linkList.index ? 'bg-(--sel)' : 'hover:bg-(--fill)'"
            @mousedown.prevent="chooseLink(n)"
          >
            <UIcon name="i-lucide-file-text" class="size-4 shrink-0 text-muted" />
            <span class="truncate">{{ n.title }}</span>
          </button>
        </div>
      </article>
      <div v-if="state.inspector.open && !row?.deletedAt && !narrow" class="w-[280px] flex-none border-s border-default bg-(--side)">
        <NoteInspector :note-id="noteId" :doc="liveDoc" @jump="jumpTo" />
      </div>
    </div>
    <UModal :key="duePortalKey" :open="!!due" :title="due?.kind === 'remind' ? 'Add Reminder' : 'Set Due Date'" :description="due?.kind === 'remind' ? 'For the line under the cursor' : 'For the checklist item under the cursor'" :ui="{ content: 'sm:max-w-[380px]', footer: 'justify-end gap-2' }" @update:open="(o: boolean) => !o && (due = undefined)">
      <template #body>
        <form v-if="due" id="due-form" class="flex flex-col gap-3" @submit.prevent="applyDue(due.date ? `${due.date}${due.time || due.kind === 'remind' ? ` ${due.time || '09:00'}` : ''}` : undefined)">
          <div class="flex gap-2">
            <UButton color="neutral" variant="soft" size="xs" label="Today" @click="due.date = dayToken(0)" />
            <UButton color="neutral" variant="soft" size="xs" label="Tomorrow" @click="due.date = dayToken(1)" />
            <UButton color="neutral" variant="soft" size="xs" label="Next Week" @click="due.date = dayToken(7)" />
          </div>
          <div class="flex gap-2">
            <UFormField label="Date" class="flex-1"><UInput v-model="due.date" type="date" autofocus class="w-full" /></UFormField>
            <UFormField :label="due.kind === 'remind' ? 'Time' : 'Time (optional)'"><UInput v-model="due.time" type="time" /></UFormField>
          </div>
        </form>
      </template>
      <template #footer>
        <UButton color="error" variant="ghost" class="me-auto" label="Remove" @click="applyDue(undefined)" />
        <UButton color="neutral" variant="soft" label="Cancel" @click="due = undefined" />
        <UButton type="submit" form="due-form" label="Set" :disabled="!due?.date" />
      </template>
    </UModal>
    <USlideover
      :key="inspectorPortalKey"
      :open="state.inspector.open && !row?.deletedAt && narrow"
      side="right"
      title="Links and Outline"
      :ui="{ content: 'max-w-[320px] bg-(--side)' }"
      @update:open="(v: boolean) => !v && (state.inspector.open = false)"
    >
      <template #content><NoteInspector :note-id="noteId" :doc="liveDoc" @jump="(b: number) => ((state.inspector.open = false), jumpTo(b))" /></template>
    </USlideover>
  </div>
</template>

<style scoped>
.page {
  padding: 36px 32px 56px;
}
@media (max-width: 767px) {
  .page {
    padding: 20px 16px 56px;
  }
}
.ro-title {
  max-width: var(--reading-max);
  margin: 0 auto 12px;
  font-size: 30px;
  font-weight: 700;
}
.ro-preview {
  max-width: var(--reading-max);
  margin: 0 auto;
  color: var(--ink2);
}
</style>
