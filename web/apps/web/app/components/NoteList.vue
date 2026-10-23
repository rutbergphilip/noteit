<script setup lang="ts">
import { computed } from 'vue';
import { useNoteit } from '~/composables/useNoteit';
import { relativeTime } from '~/utils/api';
import { safeHex } from '~/utils/icons';

const { state, visibleNotes, client, createNote } = useNoteit();

const heading = computed(() => {
  const v = state.view;
  if (state.query) return `Results for “${state.query}”`;
  switch (v.kind) {
    case 'all':
      return 'All Notes';
    case 'pinned':
      return 'Pinned';
    case 'recent':
      return 'Recent';
    case 'trash':
      return 'Recently Deleted';
    case 'tag':
      return `#${v.tag}`;
    case 'notebook':
      return state.notebooks.find((n) => n.id === v.id)?.name || 'Notebook';
  }
  return '';
});

const notebookOf = (id?: string) => (id ? state.notebooks.find((n) => n.id === id) : undefined);

function open(id: string): void {
  state.selectedId = id;
  state.pane = 'editor';
}

async function emptyTrash(): Promise<void> {
  if (!confirm('Delete every note in Recently Deleted for good? This removes them from all your devices.')) return;
  for (const n of visibleNotes.value) await client().deleteForever(n.id);
}
</script>

<template>
  <section class="list" aria-label="Notes">
    <div class="head">
      <div>
        <h1>{{ heading }}</h1>
        <div class="sub">{{ visibleNotes.length }} {{ visibleNotes.length === 1 ? 'note' : 'notes' }}</div>
      </div>
      <label class="sort">
        <span class="sr-only">Sort notes</span>
        <select v-model="state.sort">
          <option value="edited">Recently edited</option>
          <option value="created">Recently created</option>
          <option value="title">Title</option>
        </select>
      </label>
    </div>
    <div v-if="state.view.kind === 'trash' && visibleNotes.length" class="trash-bar">
      Notes here are deleted for good after 30 days.
      <button type="button" class="link" @click="emptyTrash">Empty</button>
    </div>
    <div class="rows" role="list">
      <a
        v-for="n in visibleNotes"
        :key="n.id"
        href="#"
        role="listitem"
        class="row"
        :class="{ selected: n.id === state.selectedId }"
        :aria-current="n.id === state.selectedId ? 'true' : undefined"
        @click.prevent="open(n.id)"
      >
        <div class="title">
          <NiIcon v-if="n.kind === 'locked'" name="lock" :size="13" />
          <span class="t">{{ n.title || 'Untitled' }}</span>
          <NiIcon v-if="n.isPinned" class="pin" name="pin" :size="14" :stroke="2" color="var(--pinned)" />
        </div>
        <div v-if="n.preview" class="preview">{{ n.preview }}</div>
        <div class="meta">
          {{ relativeTime(n.updatedAt) }}
          <template v-if="notebookOf(n.notebookID)">
            <span class="dot" :style="{ background: safeHex(notebookOf(n.notebookID)!.colorHex) }" />{{ notebookOf(n.notebookID)!.name }}
          </template>
          <span v-if="n.conflictSource" class="conflict">Conflict copy</span>
          <span v-if="n.kind === 'legacy'" class="conflict">Older Mac format</span>
        </div>
      </a>
      <div v-if="!visibleNotes.length" class="empty">
        <template v-if="state.query">No notes match “{{ state.query }}”.</template>
        <template v-else-if="state.view.kind === 'trash'">Nothing in Recently Deleted.</template>
        <template v-else>
          <p>No notes here yet.</p>
          <button class="ni-btn small" type="button" @click="createNote()">New Note</button>
        </template>
      </div>
    </div>
  </section>
</template>

<style scoped>
.list {
  background: var(--list);
  border-right: 1px solid var(--line);
  padding: 16px 10px;
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
  height: 100%;
  overflow: hidden;
}
.head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 8px;
  padding: 0 10px 10px;
}
h1 {
  margin: 0;
  font-size: 20px;
  font-weight: 700;
  overflow-wrap: anywhere;
}
.sub {
  font-size: 12px;
  color: var(--ink2);
  margin-top: 2px;
}
.sort select {
  border: 0;
  background: transparent;
  font-size: 13px;
  color: var(--ink2);
  cursor: pointer;
}
.trash-bar {
  margin: 0 10px 6px;
  font-size: 12px;
  color: var(--ink2);
}
.link {
  border: 0;
  background: none;
  color: var(--acct);
  cursor: pointer;
  padding: 0 4px;
}
.rows {
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 4px;
  flex: 1;
}
.row {
  display: block;
  text-decoration: none;
  color: var(--ink);
  padding: 12px;
  border-radius: 12px;
}
.row:hover {
  color: var(--ink);
  background: var(--fill);
}
.row.selected {
  background: var(--sel);
}
.title {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 14px;
  font-weight: 600;
}
.t {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.pin {
  margin-left: auto;
  flex: none;
}
.preview {
  font-size: 13px;
  line-height: 18px;
  color: var(--ink2);
  margin-top: 4px;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.meta {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: var(--ink2);
  margin-top: 6px;
  flex-wrap: wrap;
}
.dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
}
.conflict {
  padding: 1px 6px;
  border-radius: 999px;
  background: var(--warn-bg);
  color: var(--warn-ink);
}
.empty {
  padding: 24px 10px;
  color: var(--ink2);
  font-size: 14px;
  text-align: center;
}
</style>
