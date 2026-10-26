<script setup lang="ts">
import { computed, reactive, ref } from 'vue';
import type { Block, BodyContainer } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';
import { useOpeningKey } from '~/utils/overlay';

const { state, createNote, toast } = useNoteit();

// The draft lives in memory for this tab only: never written to browser storage unencrypted. Closing the dialog
// (esc, outside click) keeps it; Discard clears it.
const draft = ((globalThis as { __noteitCaptureDraft?: { title: string; body: string; notebook: string } }).__noteitCaptureDraft ??= reactive({ title: '', body: '', notebook: 'none' }));
const destinations = computed(() => [{ label: 'No Notebook', value: 'none' }, ...state.notebooks.map((n) => ({ label: n.name || 'Untitled', value: n.id }))]);
const empty = computed(() => !draft.title.trim() && !draft.body.trim());

function onOpen(open: boolean): void {
  if (open && draft.notebook === 'none') draft.notebook = state.notebooks.find((n) => n.name.toLowerCase() === 'inbox')?.id ?? 'none';
}

/** Plain text → noteit-doc: the title as a Title line, "- [ ]" lines as checklist items, "- " as bullets. */
function toContainer(): BodyContainer {
  const content: Block[] = [];
  if (draft.title.trim()) content.push({ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: draft.title.trim() }] });
  for (const line of draft.body.split('\n')) {
    const task = /^\s*[-*] \[( |x|X)\] (.*)$/.exec(line);
    const bullet = /^\s*[-*•] (.*)$/.exec(line);
    const text = task?.[2] ?? bullet?.[1] ?? line;
    const inline = text ? [{ type: 'text' as const, text }] : undefined;
    if (task) content.push({ type: 'listItem', attrs: { kind: 'task', level: 0, checked: task[1] !== ' ' }, ...(inline ? { content: inline } : {}) });
    else if (bullet) content.push({ type: 'listItem', attrs: { kind: 'bullet', level: 0 }, ...(inline ? { content: inline } : {}) });
    else content.push(inline ? { type: 'paragraph', content: inline } : { type: 'paragraph' });
  }
  return { format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content: content.length ? content : [{ type: 'paragraph' }] } };
}

async function save(): Promise<void> {
  if (empty.value) return;
  await createNote(toContainer(), draft.notebook === 'none' ? undefined : draft.notebook);
  discard();
  toast('Saved to your notes', 'success');
}
function discard(): void {
  draft.title = '';
  draft.body = '';
  state.capture = false;
}
const titleInput = ref<HTMLInputElement>();
/** Return in the title goes on to the body, as on the Mac; ⌘↩ saves from anywhere. */
function titleEnter(e: KeyboardEvent): void {
  if (e.metaKey || e.ctrlKey || e.isComposing) return;
  e.preventDefault();
  document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Note"]')?.focus();
}
/** The dialog opens on the title, not the "Save to" picker. */
function focusTitle(e: Event): void {
  e.preventDefault();
  titleInput.value?.focus();
}
function onKey(e: KeyboardEvent): void {
  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
    e.preventDefault();
    void save();
  }
}
// A fresh portal per opening, so it shows above the sidebar drawer (see useOpeningKey).
const portalKey = useOpeningKey(() => state.capture);
</script>

<template>
  <!-- design p04 -->
  <UModal :key="portalKey" v-model:open="state.capture" title="Quick Capture" description="Draft a note without leaving what you're doing." :content="{ onOpenAutoFocus: focusTitle }" :ui="{ content: 'sm:max-w-[600px] sm:top-[140px] sm:translate-y-0 top-auto' }" @update:open="onOpen">
    <template #content>
      <form class="flex flex-col gap-3 px-5.5 py-4.5" @submit.prevent="save" @keydown="onKey">
        <div class="flex flex-wrap items-center gap-2.5">
          <span class="grid size-7 place-items-center rounded-lg bg-(--sel)"><UIcon name="i-lucide-pen-line" class="size-4 text-primary" /></span>
          <span class="text-sm font-semibold">Quick Capture</span>
          <label class="ms-auto flex items-center gap-2 text-[13px] text-muted">
            Save to
            <USelect v-model="draft.notebook" :items="destinations" size="sm" variant="soft" class="min-w-36" />
          </label>
        </div>
        <input ref="titleInput" v-model="draft.title" class="w-full bg-transparent text-[22px] font-semibold outline-none placeholder:text-dimmed" placeholder="Title" aria-label="Title" @keydown.enter="titleEnter" />
        <UTextarea v-model="draft.body" :rows="6" autoresize :maxrows="14" variant="none" placeholder="Write something. - [ ] makes a checklist item." aria-label="Note" :ui="{ base: 'px-0 text-sm/normal' }" />
        <div class="flex flex-wrap items-center gap-2 border-t border-default pt-3">
          <UKbd value="escape" />
          <span class="me-auto text-xs text-muted">to dismiss · draft is kept until you close this tab</span>
          <UButton color="neutral" variant="ghost" size="sm" label="Discard" @click="discard" />
          <UButton type="submit" size="sm" :disabled="empty" label="Save Note">
            <template #trailing><UKbd value="meta" size="sm" /><UKbd value="enter" size="sm" /></template>
          </UButton>
        </div>
      </form>
    </template>
  </UModal>
</template>
