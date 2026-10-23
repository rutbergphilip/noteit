<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue';
import type { Block, BodyContainer } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

const { state, createNote, toast } = useNoteit();

// The draft lives in memory for this tab only: never written to browser storage unencrypted.
const draft = (globalThis as { __noteitCaptureDraft?: { title: string; body: string; notebook: string } }).__noteitCaptureDraft ??= reactive({
  title: '',
  body: '',
  notebook: state.notebooks.find((n) => n.name.toLowerCase() === 'inbox')?.id ?? '',
});
const titleInput = ref<HTMLInputElement>();
onMounted(() => titleInput.value?.focus());

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
  if (!draft.title.trim() && !draft.body.trim()) return;
  await createNote(toContainer(), draft.notebook || undefined);
  discard();
  toast('Saved to your notes');
}

function discard(): void {
  draft.title = '';
  draft.body = '';
  state.capture = false;
}

function onKey(e: KeyboardEvent): void {
  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
    e.preventDefault();
    void save();
  } else if (e.key === 'Escape') state.capture = false;
}
</script>

<template>
  <!-- design p04 -->
  <div class="ni-scrim" @click="state.capture = false" />
  <form class="ni-dialog capture" role="dialog" aria-modal="true" aria-label="Quick Capture" @submit.prevent="save" @keydown="onKey">
    <div class="top">
      <span class="badge"><NiIcon name="capture" :size="16" color="var(--acc)" /></span>
      <span class="name">Quick Capture</span>
      <label class="dest">Save to
        <select v-model="draft.notebook">
          <option value="">No Notebook</option>
          <option v-for="nb in state.notebooks" :key="nb.id" :value="nb.id">{{ nb.name }}</option>
        </select>
      </label>
    </div>
    <label><span class="sr-only">Title</span><input ref="titleInput" v-model="draft.title" class="title" placeholder="Title" /></label>
    <label><span class="sr-only">Note</span><textarea v-model="draft.body" rows="6" placeholder="Write something. - [ ] makes a checklist item." /></label>
    <div class="foot">
      <kbd>esc</kbd>
      <span class="hint">to dismiss · draft is kept until you close this tab</span>
      <button type="button" class="ni-btn ghost small" @click="discard">Discard</button>
      <button type="submit" class="ni-btn small">Save Note ⌘↵</button>
    </div>
  </form>
</template>

<style scoped>
.capture {
  top: 140px;
  width: min(600px, calc(100% - 32px));
  padding: 18px 22px;
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.top {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.badge {
  width: 28px;
  height: 28px;
  border-radius: 8px;
  background: var(--sel);
  display: grid;
  place-items: center;
}
.name {
  font-size: 14px;
  font-weight: 600;
}
.dest {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  color: var(--ink2);
}
.dest select {
  border: 0;
  background: var(--fill);
  border-radius: 8px;
  padding: 5px 8px;
  font-size: 13px;
}
.title {
  width: 100%;
  border: 0;
  outline: none;
  background: transparent;
  font-size: 22px;
  font-weight: 600;
  color: var(--ink);
}
textarea {
  width: 100%;
  border: 0;
  outline: none;
  background: transparent;
  font-size: 14px;
  line-height: 1.5;
  resize: vertical;
  color: var(--ink);
}
.foot {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  border-top: 1px solid var(--line);
  padding-top: 12px;
}
kbd {
  font: inherit;
  font-size: 12px;
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 2px 6px;
  color: var(--ink2);
}
.hint {
  font-size: 12px;
  color: var(--ink2);
  margin-right: auto;
}
</style>
