<script setup lang="ts">
import { computed, onBeforeUnmount, ref, shallowRef, watch } from 'vue';
import { EditorContent, useEditor } from '@tiptap/vue-3';
import type { Editor } from '@tiptap/core';
import { addAttachment, attachmentTooLargeMessage, type BodyContainer, isAllowedLink, MAX_ATTACHMENT_BYTES, sanitizePastedHtml } from '@noteit/doc';
import { fromEditorJSON, noteItExtensions, prepareForEditor } from '@noteit/doc/tiptap';
import { useConfirm } from '~/lib/confirm';
import { useNoteit } from '~/composables/useNoteit';
import { notebookIcon, safeHex } from '~/utils/notebooks';
import type { OpenedNote } from '~/worker/types';

const props = defineProps<{ noteId: string }>();
const { state, client, toast, refresh } = useNoteit();
const confirm = useConfirm();

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

const BLOCKS: { value: Block; label: string }[] = [
  { value: 'paragraph', label: 'Body' },
  { value: 'h1', label: 'Title' },
  { value: 'h2', label: 'Heading' },
  { value: 'h3', label: 'Subheading' },
  { value: 'code', label: 'Code Block' },
  { value: 'quote', label: 'Quote' },
];

function setBlock(v: Block): void {
  const ed = editor.value as Editor | undefined;
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

const linkOpen = ref(false);
const linkHref = ref('');
const linkError = ref('');
watch(linkOpen, (open) => {
  if (!open) return;
  linkHref.value = (editor.value?.getAttributes('link').href as string | undefined) ?? 'https://';
  linkError.value = '';
});
function applyLink(): void {
  const ed = editor.value;
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
  if (!(await confirm({ title: 'Delete this note for good?', description: 'It is removed from all your devices.', confirmLabel: 'Delete', danger: true }))) return;
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
          <UTooltip text="Download note">
            <UButton color="neutral" variant="ghost" class="text-muted" icon="i-lucide-share" aria-label="Download note" :disabled="!container" @click="exportNote" />
          </UTooltip>
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
      <UTooltip text="Inline code" :kbds="['meta', 'E']">
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

    <article class="page flex-1 overflow-y-auto">
      <h2 v-if="row?.kind === 'legacy' || row?.kind === 'locked'" class="ro-title">{{ row.title || 'Untitled' }}</h2>
      <p v-if="row?.kind === 'legacy' && row.preview" class="ro-preview">{{ row.preview }}</p>
      <EditorContent v-show="row?.kind === 'doc'" :editor="editor" />
    </article>
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
