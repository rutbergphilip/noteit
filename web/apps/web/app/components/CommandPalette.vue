<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from 'vue';
import { searchFold } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';
import type { NoteRow } from '~/worker/types';

const { state, client, tags, createNote, setTheme, lock } = useNoteit();
const query = ref(state.query);
const hits = ref<NoteRow[]>([]);
const cursor = ref(0);
const input = ref<HTMLInputElement>();

type Item = { kind: 'note'; note: NoteRow } | { kind: 'tag'; tag: string; count: number } | { kind: 'command'; label: string; hint?: string; run: () => void };

async function update(): Promise<void> {
  const q = query.value.trim();
  if (!q) {
    hits.value = [...state.notes].filter((n) => !n.deletedAt).sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt)).slice(0, 6);
    return;
  }
  const ids = new Set(await client().search(q));
  hits.value = state.notes.filter((n) => ids.has(n.id)).slice(0, 8);
}
watch(query, () => {
  cursor.value = 0;
  void update();
});
onMounted(async () => {
  await update();
  await nextTick();
  input.value?.focus();
  input.value?.select();
});

const close = () => (state.palette = false);

const items = computed<Item[]>(() => {
  const q = query.value.trim();
  const fq = searchFold(q.replace(/^#/, ''));
  const out: Item[] = hits.value.map((note) => ({ kind: 'note', note }));
  if (q) for (const t of tags.value.filter((t) => searchFold(t.tag).includes(fq)).slice(0, 4)) out.push({ kind: 'tag', ...t });
  const commands: Item[] = [
    {
      kind: 'command',
      label: q ? `New Note Titled “${q}”` : 'New Note',
      hint: '⌥⌘N',
      run: () =>
        void createNote(q ? { format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content: [{ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: q }] }, { type: 'paragraph' }] } } : undefined),
    },
    { kind: 'command', label: 'Open Quick Capture', hint: '⌥⌘C', run: () => (state.capture = true) },
    { kind: 'command', label: 'New Notebook', run: () => (state.notebookDialog = { mode: 'create' }) },
    { kind: 'command', label: state.theme === 'dark' ? 'Switch to Light Mode' : 'Switch to Dark Mode', run: () => setTheme(state.theme === 'dark' ? 'light' : 'dark') },
    { kind: 'command', label: 'Sync Now', run: () => void client().syncNow() },
    { kind: 'command', label: 'Show Recently Deleted', run: () => (state.view = { kind: 'trash' }) },
    { kind: 'command', label: 'Settings', run: () => (state.settings = true) },
    { kind: 'command', label: 'Lock NoteIt', run: () => void lock() },
  ];
  const fold = searchFold(q);
  return [...out, ...commands.filter((c) => c.kind === 'command' && (!q || c.label.startsWith('New Note') || searchFold(c.label).includes(fold)))];
});

function choose(item: Item | undefined): void {
  if (!item) return;
  close();
  if (item.kind === 'note') {
    state.selectedId = item.note.id;
    state.pane = 'editor';
  } else if (item.kind === 'tag') {
    state.view = { kind: 'tag', tag: item.tag };
    state.pane = 'list';
  } else item.run();
}

function onKey(e: KeyboardEvent): void {
  if (e.key === 'ArrowDown') {
    e.preventDefault();
    cursor.value = Math.min(items.value.length - 1, cursor.value + 1);
  } else if (e.key === 'ArrowUp') {
    e.preventDefault();
    cursor.value = Math.max(0, cursor.value - 1);
  } else if (e.key === 'Enter') {
    e.preventDefault();
    choose(items.value[cursor.value]);
  } else if (e.key === 'Escape') close();
}

/** Splits text around the first folded match so the template can wrap it in <mark> (no HTML strings). */
function parts(text: string): { pre: string; hit: string; post: string } {
  const q = query.value.trim().split(/\s+/)[0] ?? '';
  if (!q) return { pre: text, hit: '', post: '' };
  const i = searchFold(text).indexOf(searchFold(q));
  if (i < 0) return { pre: text, hit: '', post: '' };
  const start = Math.max(0, i - 30);
  return { pre: (start > 0 ? '…' : '') + text.slice(start, i), hit: text.slice(i, i + q.length), post: text.slice(i + q.length, i + q.length + 80) };
}
</script>

<template>
  <!-- design p03 -->
  <div class="ni-scrim" @click="close" />
  <div class="ni-dialog palette" role="dialog" aria-modal="true" aria-label="Search notes and commands" @keydown="onKey">
    <label class="field">
      <NiIcon name="search" :size="18" />
      <span class="sr-only">Search</span>
      <input ref="input" v-model="query" placeholder="Search notes and commands" role="combobox" aria-expanded="true" aria-controls="palette-list" />
      <kbd>esc</kbd>
    </label>
    <div id="palette-list" class="results" role="listbox">
      <template v-for="(item, i) in items" :key="i">
        <div v-if="i === 0 && item.kind === 'note'" class="group">Notes</div>
        <div v-else-if="item.kind === 'tag' && items[i - 1]?.kind !== 'tag'" class="group">Tags</div>
        <div v-else-if="item.kind === 'command' && items[i - 1]?.kind !== 'command'" class="group">Commands</div>
        <button type="button" role="option" class="item" :aria-selected="i === cursor" :class="{ on: i === cursor }" @mouseenter="cursor = i" @click="choose(item)">
          <template v-if="item.kind === 'note'">
            <span class="ic"><NiIcon name="notes" :size="16" /></span>
            <span class="txt">
              <span class="t">{{ item.note.title || 'Untitled' }}</span>
              <span v-if="item.note.preview" class="p">{{ parts(item.note.preview).pre }}<mark v-if="parts(item.note.preview).hit">{{ parts(item.note.preview).hit }}</mark>{{ parts(item.note.preview).post }}</span>
            </span>
            <span v-if="i === cursor" class="k">↵</span>
          </template>
          <template v-else-if="item.kind === 'tag'">
            <span class="ic"><NiIcon name="tag" :size="16" /></span>
            <span class="txt"><span class="t">#{{ item.tag }}</span></span>
            <span class="k">{{ item.count }} {{ item.count === 1 ? 'note' : 'notes' }}</span>
          </template>
          <template v-else>
            <span class="ic"><NiIcon name="bolt" :size="16" /></span>
            <span class="txt"><span class="t">{{ item.label }}</span></span>
            <span v-if="item.hint" class="k">{{ item.hint }}</span>
          </template>
        </button>
      </template>
    </div>
    <div class="foot">
      <span>↑ ↓ to move</span><span>↵ to open</span><span>Search runs on this device; nothing leaves it</span>
    </div>
  </div>
</template>

<style scoped>
.palette {
  top: 96px;
  width: min(640px, calc(100% - 32px));
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
.field {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 14px 16px;
  border-bottom: 1px solid var(--line);
  color: var(--ink2);
}
.field input {
  flex: 1;
  border: 0;
  background: transparent;
  font-size: 17px;
  color: var(--ink);
  outline: none;
  min-width: 0;
}
kbd {
  font: inherit;
  font-size: 12px;
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 2px 6px;
}
.results {
  max-height: min(420px, 60vh);
  overflow-y: auto;
  padding: 8px;
}
.group {
  font-size: 11px;
  font-weight: 600;
  color: var(--ink2);
  padding: 10px 10px 4px;
}
.item {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 8px 10px;
  border: 0;
  border-radius: 10px;
  background: transparent;
  text-align: left;
  cursor: pointer;
}
.item.on {
  background: var(--sel);
}
.ic {
  width: 30px;
  height: 30px;
  border-radius: 8px;
  background: var(--fill);
  display: grid;
  place-items: center;
  flex: none;
  color: var(--ink2);
}
.txt {
  display: flex;
  flex-direction: column;
  min-width: 0;
  flex: 1;
}
.t {
  font-size: 14px;
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.p {
  font-size: 12px;
  color: var(--ink2);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
mark {
  background: var(--mark);
  color: inherit;
  border-radius: 3px;
  padding: 0 1px;
}
.k {
  font-size: 12px;
  color: var(--ink2);
  flex: none;
}
.foot {
  display: flex;
  flex-wrap: wrap;
  gap: 16px;
  padding: 10px 16px;
  border-top: 1px solid var(--line);
  font-size: 12px;
  color: var(--ink2);
}
</style>
