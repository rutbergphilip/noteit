<script setup lang="ts">
import { computed, onBeforeUnmount, ref, shallowRef, watch } from 'vue';
import { EditorContent, useEditor } from '@tiptap/vue-3';
import type { Editor } from '@tiptap/core';
import { addAttachment, attachmentTooLargeMessage, type BodyContainer, isAllowedLink, MAX_ATTACHMENT_BYTES, sanitizePastedHtml } from '@noteit/doc';
import { fromEditorJSON, noteItExtensions, prepareForEditor } from '@noteit/doc/tiptap';
import { useNoteit } from '~/composables/useNoteit';
import { safeHex } from '~/utils/icons';
import type { OpenedNote } from '~/worker/types';

const props = defineProps<{ noteId: string }>();
const { state, client, toast, refresh } = useNoteit();

const note = shallowRef<OpenedNote>();
const container = shallowRef<BodyContainer>();
const editable = ref(false);
const readOnlyReason = ref<string>();
const saveState = ref<'saved' | 'saving' | 'unsaved'>('saved');
const urls = new Map<string, string>();
let saveTimer: ReturnType<typeof setTimeout> | undefined;
let lastSaved = '';

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
  extensions: noteItExtensions({ resolver: { url: attachmentUrl } }),
  editable: false,
  content: { type: 'doc', content: [{ type: 'paragraph' }] },
  editorProps: {
    attributes: { class: 'ni-prose', 'aria-label': 'Note' },
    transformPastedHTML: (html) => sanitizePastedHtml(html),
    handlePaste: (_view, event) => {
      const files = [...(event.clipboardData?.files ?? [])];
      if (!files.length) return false;
      void insertFiles(files);
      return true;
    },
    handleDrop: (_view, event) => {
      const files = [...((event as DragEvent).dataTransfer?.files ?? [])];
      if (!files.length) return false;
      void insertFiles(files);
      return true;
    },
  },
  onUpdate: () => scheduleSave(),
});

async function load(): Promise<void> {
  const opened = await client().getNote(props.noteId);
  note.value = opened;
  if (!opened) return;
  container.value = opened.container;
  readOnlyReason.value = opened.readOnly;
  const ed = editor.value;
  if (!ed) return;
  if (opened.container && !opened.readOnly) {
    const prepared = prepareForEditor(opened.container);
    editable.value = prepared.editable;
    if (!prepared.editable) readOnlyReason.value = prepared.reason;
    ed.commands.setContent(prepared.doc, { emitUpdate: false });
    lastSaved = JSON.stringify(opened.container.doc);
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
const edited = computed(() => (row.value ? new Date(row.value.updatedAt).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : ''));

function scheduleSave(): void {
  if (!editable.value) return;
  saveState.value = 'unsaved';
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => void save(), 600);
}

async function save(): Promise<void> {
  saveTimer = undefined;
  const ed = editor.value;
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
    await client().saveNote(props.noteId, next);
    container.value = next;
    lastSaved = json;
    saveState.value = 'saved';
  } catch (e) {
    saveState.value = 'unsaved';
    toast(e instanceof Error ? e.message : 'Could not save');
  }
}

// A pull of this note while nothing is pending reloads it in place.
watch(
  () => row.value?.updatedAt,
  async (now, before) => {
    if (!before || now === before || saveTimer || saveState.value !== 'saved') return;
    const opened = await client().getNote(props.noteId);
    if (opened?.container && JSON.stringify(opened.container.doc) !== lastSaved) await load();
  },
);

watch(editor, (ed) => ed && void load(), { immediate: true });

onBeforeUnmount(() => {
  if (saveTimer) {
    clearTimeout(saveTimer);
    void save();
  }
  for (const url of urls.values()) URL.revokeObjectURL(url);
});

async function insertFiles(files: File[]): Promise<void> {
  const ed = editor.value;
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
  const ed = editor.value;
  if (!ed) return 'paragraph';
  void state.selectedId;
  if (ed.isActive('heading', { level: 1 })) return 'h1';
  if (ed.isActive('heading', { level: 2 })) return 'h2';
  if (ed.isActive('heading', { level: 3 })) return 'h3';
  if (ed.isActive('codeBlock')) return 'code';
  if (ed.isActive('blockquote')) return 'quote';
  return 'paragraph';
});

function setBlock(e: Event): void {
  const ed = editor.value as Editor | undefined;
  if (!ed) return;
  const v = (e.target as HTMLSelectElement).value as Block;
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
  const ed = editor.value;
  if (!ed) return;
  if (ed.isActive('listItem', { kind })) ed.chain().focus().setNode('paragraph').run();
  else ed.chain().focus().setNode('listItem', { kind, level: 0, number: kind === 'ordered' ? 1 : null, checked: kind === 'task' ? false : null }).run();
}

function insertTable(): void {
  const cell = (type: string) => ({ type, content: [{ type: 'paragraph' }] });
  editor.value
    ?.chain()
    .focus()
    .insertContent({ type: 'table', content: [{ type: 'tableRow', content: [cell('tableHeader'), cell('tableHeader')] }, { type: 'tableRow', content: [cell('tableCell'), cell('tableCell')] }] })
    .run();
}

function setLink(): void {
  const ed = editor.value;
  if (!ed) return;
  const current = ed.getAttributes('link').href as string | undefined;
  const href = prompt('Link address (https://, mailto:, tel: or noteit://note/…)', current ?? 'https://');
  if (href === null) return;
  if (href === '') {
    ed.chain().focus().unsetMark('link').run();
    return;
  }
  if (!isAllowedLink(href)) {
    toast('Links can be https, http, mailto, tel or noteit://note links.');
    return;
  }
  ed.chain().focus().setMark('link', { href }).run();
}

const COLORS = ['#FF3B30', '#FF9500', '#34C759', '#007AFF', '#AF52DE'];
const HIGHLIGHTS = ['#FFF3A3', '#C7F0C2', '#CDE4FF', '#FFD6E8'];
const colorMenu = ref<'text' | 'highlight'>();
function applyColor(kind: 'textColor' | 'highlight', color: string | undefined): void {
  const chain = editor.value?.chain().focus();
  if (!chain) return;
  if (color) chain.setMark(kind, { color: safeHex(color) }).run();
  else chain.unsetMark(kind).run();
  colorMenu.value = undefined;
}

// MARK: note actions

async function togglePin(): Promise<void> {
  if (row.value) await client().updateNoteMeta(props.noteId, { isPinned: !row.value.isPinned });
}
async function move(e: Event): Promise<void> {
  const v = (e.target as HTMLSelectElement).value;
  await client().updateNoteMeta(props.noteId, { notebookID: v || null });
}
async function trash(): Promise<void> {
  await save();
  await client().updateNoteMeta(props.noteId, { trashed: true });
  state.selectedId = undefined;
  state.pane = 'list';
  toast('Moved to Recently Deleted');
}
async function recover(): Promise<void> {
  await client().updateNoteMeta(props.noteId, { trashed: false });
  await refresh();
  await load();
}
async function deleteForever(): Promise<void> {
  if (!confirm('Delete this note for good? It is removed from all your devices.')) return;
  await client().deleteForever(props.noteId);
  state.selectedId = undefined;
  state.pane = 'list';
}
function exportNote(): void {
  if (!container.value) return;
  const blob = new Blob([JSON.stringify(container.value)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `${(row.value?.title || 'Untitled').replace(/[\\/:*?"<>|]/g, '-').slice(0, 80)}.noteitdoc`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
</script>

<template>
  <div class="ed">
    <div class="bar">
      <button type="button" class="back" aria-label="Back to notes" @click="state.pane = 'list'"><NiIcon name="back" :size="18" /></button>
      <label class="chip" :style="notebook ? { background: `color-mix(in srgb, ${safeHex(notebook.colorHex)} 16%, transparent)` } : {}">
        <span class="dot" :style="{ background: notebook ? safeHex(notebook.colorHex) : 'var(--ink3)' }" />
        <span class="sr-only">Notebook</span>
        <select :value="row?.notebookID ?? ''" :disabled="!!row?.deletedAt" @change="move">
          <option value="">No Notebook</option>
          <option v-for="nb in state.notebooks" :key="nb.id" :value="nb.id">{{ nb.name || 'Untitled' }}</option>
        </select>
      </label>
      <span class="edited">Edited {{ edited }}</span>
      <div class="actions">
        <template v-if="row?.deletedAt">
          <button type="button" class="ni-btn secondary small" @click="recover"><NiIcon name="restore" :size="15" />Recover</button>
          <button type="button" class="ni-btn danger small" @click="deleteForever">Delete Now</button>
        </template>
        <template v-else>
          <button type="button" class="act" :aria-label="row?.isPinned ? 'Unpin' : 'Pin'" :aria-pressed="!!row?.isPinned" :style="row?.isPinned ? { color: 'var(--pinned)' } : {}" @click="togglePin">
            <NiIcon name="pin" :size="17" />
          </button>
          <button type="button" class="act" aria-label="Download note" :disabled="!container" @click="exportNote"><NiIcon name="share" :size="17" /></button>
          <button type="button" class="act" aria-label="Move to Recently Deleted" @click="trash"><NiIcon name="trash" :size="17" /></button>
        </template>
      </div>
    </div>

    <div v-if="editable && !row?.deletedAt" class="toolbar" role="toolbar" aria-label="Formatting">
      <label>
        <span class="sr-only">Text style</span>
        <select class="style" :value="blockType" @change="setBlock">
          <option value="paragraph">Body</option>
          <option value="h1">Title</option>
          <option value="h2">Heading</option>
          <option value="h3">Subheading</option>
          <option value="code">Code Block</option>
          <option value="quote">Quote</option>
        </select>
      </label>
      <span class="sep" />
      <button type="button" aria-label="Bold" :aria-pressed="active('bold')" class="b" @click="mark('bold')">B</button>
      <button type="button" aria-label="Italic" :aria-pressed="active('italic')" class="i" @click="mark('italic')">I</button>
      <button type="button" aria-label="Underline" :aria-pressed="active('underline')" class="u" @click="mark('underline')">U</button>
      <button type="button" aria-label="Strikethrough" :aria-pressed="active('strike')" class="s" @click="mark('strike')">S</button>
      <button type="button" aria-label="Inline code" :aria-pressed="active('code')" :disabled="active('codeBlock')" @click="mark('code')"><NiIcon name="inlineCode" :size="16" :stroke="2" /></button>
      <span class="sep" />
      <div class="pop-wrap">
        <button type="button" aria-label="Text color" @click="colorMenu = colorMenu === 'text' ? undefined : 'text'"><NiIcon name="textColor" :size="16" :stroke="2" /></button>
        <div v-if="colorMenu === 'text'" class="swatches">
          <button v-for="c in COLORS" :key="c" type="button" class="sw" :aria-label="`Color ${c}`" :style="{ background: c }" @click="applyColor('textColor', c)" />
          <button type="button" class="sw none" aria-label="No color" @click="applyColor('textColor', undefined)">×</button>
        </div>
      </div>
      <div class="pop-wrap">
        <button type="button" aria-label="Highlight" @click="colorMenu = colorMenu === 'highlight' ? undefined : 'highlight'"><NiIcon name="highlight" :size="16" :stroke="2" /></button>
        <div v-if="colorMenu === 'highlight'" class="swatches">
          <button v-for="c in HIGHLIGHTS" :key="c" type="button" class="sw" :aria-label="`Highlight ${c}`" :style="{ background: c }" @click="applyColor('highlight', c)" />
          <button type="button" class="sw none" aria-label="No highlight" @click="applyColor('highlight', undefined)">×</button>
        </div>
      </div>
      <span class="sep" />
      <button type="button" aria-label="Bulleted list" :aria-pressed="active('listItem', { kind: 'bullet' })" @click="toggleList('bullet')"><NiIcon name="bullets" :size="16" :stroke="2" /></button>
      <button type="button" aria-label="Numbered list" :aria-pressed="active('listItem', { kind: 'ordered' })" @click="toggleList('ordered')"><NiIcon name="numbered" :size="16" :stroke="2" /></button>
      <button type="button" aria-label="Checklist" :aria-pressed="active('listItem', { kind: 'task' })" @click="toggleList('task')"><NiIcon name="checklist" :size="16" :stroke="2" /></button>
      <button type="button" aria-label="Table" @click="insertTable"><NiIcon name="table" :size="16" :stroke="2" /></button>
      <button type="button" aria-label="Link" :aria-pressed="active('link')" @click="setLink"><NiIcon name="link" :size="16" :stroke="2" /></button>
      <button type="button" aria-label="Image or file" @click="pickFile"><NiIcon name="image" :size="16" :stroke="2" /></button>
      <input ref="fileInput" type="file" multiple hidden @change="onFiles" />
      <span class="saved">{{ saveState === 'saved' ? 'Saved' : saveState === 'saving' ? 'Saving…' : 'Edited' }}</span>
    </div>

    <div v-if="readOnlyReason === 'legacy'" class="ni-alert warn banner">
      <NiIcon name="alert" />Formatted on an older Mac — open NoteIt on macOS to convert. You can still pin, move or delete it here.
    </div>
    <div v-else-if="readOnlyReason === 'locked'" class="ni-alert warn banner"><NiIcon name="lock" />This note is locked. Unlock it in NoteIt on your Mac.</div>
    <div v-else-if="readOnlyReason" class="ni-alert warn banner">
      <NiIcon name="alert" />This note uses something this version of NoteIt web can't edit yet, so it opens read-only ({{ readOnlyReason }}).
    </div>
    <div v-if="row?.conflictSource" class="ni-alert warn banner">
      <NiIcon name="alert" />This is a conflict copy: the note was changed on {{ row.conflictSource }} and here at the same time. Keep the parts you need, then delete the copy.
    </div>

    <article class="page">
      <h2 v-if="row?.kind === 'legacy' || row?.kind === 'locked'" class="ro-title">{{ row.title || 'Untitled' }}</h2>
      <p v-if="row?.kind === 'legacy' && row.preview" class="ro-preview">{{ row.preview }}</p>
      <EditorContent v-show="row?.kind === 'doc'" :editor="editor" />
    </article>
  </div>
</template>

<style scoped>
.ed {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
}
.bar {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
  padding: 12px 24px;
  border-bottom: 1px solid var(--line);
}
.back {
  display: none;
  width: 36px;
  height: 36px;
  border: 0;
  background: transparent;
  border-radius: 8px;
  color: var(--ink);
  cursor: pointer;
  place-items: center;
}
@container app (max-width: 719px) {
  .back {
    display: grid;
  }
  .bar {
    padding: 8px 12px;
  }
  .toolbar {
    padding: 6px 8px !important;
    flex-wrap: nowrap !important;
    overflow-x: auto;
  }
  .page {
    padding: 20px 16px 56px !important;
  }
}
.chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 26px;
  padding: 0 4px 0 10px;
  border-radius: 999px;
  background: var(--fill);
  font-size: 12px;
  font-weight: 600;
}
.chip select {
  border: 0;
  background: transparent;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  max-width: 160px;
}
.dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
}
.edited {
  font-size: 12px;
  color: var(--ink2);
}
.actions {
  margin-left: auto;
  display: flex;
  gap: 4px;
}
.act {
  width: 32px;
  height: 32px;
  display: grid;
  place-items: center;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: var(--ink2);
  cursor: pointer;
}
.act:hover {
  background: var(--fill);
}
.toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 2px;
  padding: 8px 20px;
  border-bottom: 1px solid var(--line);
}
.toolbar button {
  width: 30px;
  height: 30px;
  flex: none;
  border: 0;
  border-radius: 7px;
  background: transparent;
  cursor: pointer;
  display: grid;
  place-items: center;
  color: var(--ink);
}
.toolbar button[aria-pressed='true'] {
  background: var(--sel);
  color: var(--acct);
}
.toolbar button:disabled {
  opacity: 0.4;
}
.toolbar .b {
  font-weight: 700;
}
.toolbar .i {
  font-style: italic;
  font-family: Georgia, serif;
}
.toolbar .u {
  text-decoration: underline;
}
.toolbar .s {
  text-decoration: line-through;
}
.style {
  height: 30px;
  padding: 0 8px;
  border: 0;
  border-radius: 7px;
  background: var(--fill);
  font-size: 13px;
  cursor: pointer;
}
.sep {
  width: 1px;
  height: 18px;
  background: var(--line);
  margin: 0 6px;
  flex: none;
}
.saved {
  margin-left: auto;
  font-size: 12px;
  color: var(--ink2);
  flex: none;
  padding-left: 8px;
}
.pop-wrap {
  position: relative;
}
.swatches {
  position: absolute;
  top: 34px;
  left: 0;
  z-index: 20;
  display: flex;
  gap: 6px;
  padding: 8px;
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: 10px;
  box-shadow: var(--shadow-dialog);
}
.toolbar .sw {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  border: 1px solid var(--line);
}
.toolbar .sw.none {
  background: var(--bg);
  font-size: 12px;
}
.banner {
  margin: 12px 24px 0;
}
.page {
  flex: 1;
  overflow-y: auto;
  padding: 36px 32px 56px;
}
.ro-title {
  max-width: var(--reading-max);
  margin: 0 auto 12px;
  font-size: 30px;
}
.ro-preview {
  max-width: var(--reading-max);
  margin: 0 auto;
  color: var(--ink2);
}
</style>
