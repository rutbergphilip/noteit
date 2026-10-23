<script setup lang="ts">
import { computed } from 'vue';
import { useNoteit, type View } from '~/composables/useNoteit';
import { relativeTime } from '~/utils/api';
import { safeHex, SYMBOL_ICONS } from '~/utils/icons';
import type { NotebookRow } from '~/worker/types';

const { state, tags } = useNoteit();

const live = computed(() => state.notes.filter((n) => !n.deletedAt));
const counts = computed(() => {
  const byNotebook = new Map<string, number>();
  for (const n of live.value) if (n.notebookID) byNotebook.set(n.notebookID, (byNotebook.get(n.notebookID) ?? 0) + 1);
  return {
    all: live.value.length,
    pinned: live.value.filter((n) => n.isPinned).length,
    recent: live.value.filter((n) => Date.now() - Date.parse(n.updatedAt) < 7 * 86_400_000).length,
    trash: state.notes.length - live.value.length,
    byNotebook,
  };
});

/** Notebooks as a tree (organise's `parent`), depth-first, siblings by sortIndex. */
const tree = computed(() => {
  const out: { nb: NotebookRow; depth: number }[] = [];
  const ids = new Set(state.notebooks.map((n) => n.id));
  const walk = (parent: string | undefined, depth: number) => {
    for (const nb of state.notebooks.filter((n) => (n.parent && ids.has(n.parent) ? n.parent : undefined) === parent)) {
      out.push({ nb, depth });
      if (depth < 6) walk(nb.id, depth + 1);
    }
  };
  walk(undefined, 0);
  return out;
});

const isActive = (v: View) => JSON.stringify(v) === JSON.stringify(state.view);

function go(v: View): void {
  state.view = v;
  state.drawerOpen = false;
  state.pane = 'list';
}
</script>

<template>
  <nav class="side" aria-label="Library">
    <div class="label">Library</div>
    <a href="#" :class="{ active: isActive({ kind: 'all' }) }" @click.prevent="go({ kind: 'all' })">
      <NiIcon name="notes" :size="17" color="var(--acc)" />All Notes<span class="count">{{ counts.all }}</span>
    </a>
    <a href="#" :class="{ active: isActive({ kind: 'pinned' }) }" @click.prevent="go({ kind: 'pinned' })">
      <NiIcon name="pin" :size="17" color="var(--pinned)" />Pinned<span class="count">{{ counts.pinned }}</span>
    </a>
    <a href="#" :class="{ active: isActive({ kind: 'recent' }) }" @click.prevent="go({ kind: 'recent' })">
      <NiIcon name="clock" :size="17" color="var(--recent)" />Recent<span class="count">{{ counts.recent }}</span>
    </a>
    <a href="#" :class="{ active: isActive({ kind: 'trash' }) }" @click.prevent="go({ kind: 'trash' })">
      <NiIcon name="trash" :size="17" color="var(--ink2)" />Recently Deleted<span class="count">{{ counts.trash }}</span>
    </a>

    <div class="label spaced">Notebooks</div>
    <a
      v-for="{ nb, depth } in tree"
      :key="nb.id"
      href="#"
      :class="{ active: isActive({ kind: 'notebook', id: nb.id }) }"
      :style="{ paddingLeft: `${10 + depth * 16}px` }"
      @click.prevent="go({ kind: 'notebook', id: nb.id })"
      @dblclick.prevent="state.notebookDialog = { mode: 'edit', id: nb.id }"
    >
      <NiIcon :name="SYMBOL_ICONS[nb.symbol] ?? 'folder'" :size="17" :color="safeHex(nb.colorHex)" />
      <span class="name">{{ nb.name || 'Untitled' }}</span><span class="count">{{ counts.byNotebook.get(nb.id) ?? 0 }}</span>
    </a>
    <p v-if="!tree.length" class="empty">No notebooks yet.</p>

    <template v-if="tags.length">
      <div class="label spaced">Tags</div>
      <div class="tags">
        <a v-for="t in tags.slice(0, 30)" :key="t.tag" href="#" class="tag" :class="{ active: isActive({ kind: 'tag', tag: t.tag }) }" @click.prevent="go({ kind: 'tag', tag: t.tag })">#{{ t.tag }}</a>
      </div>
    </template>

    <div class="bottom">
      <button type="button" class="new-nb" @click="state.notebookDialog = { mode: 'create', ...(state.view.kind === 'notebook' ? { parent: state.view.id } : {}) }">
        <NiIcon name="plus" :size="16" :stroke="2" />New Notebook
      </button>
      <button type="button" class="store" @click="state.settings = true">
        <NiIcon name="server" :size="15" />
        <span>This server · encrypted<br /><span class="muted">Last sync {{ state.status.lastSync ? relativeTime(state.status.lastSync).toLowerCase() : 'pending' }}</span></span>
      </button>
    </div>
  </nav>
</template>

<style scoped>
.side {
  background: var(--side);
  border-right: 1px solid var(--line);
  padding: 14px 10px;
  display: flex;
  flex-direction: column;
  gap: 2px;
  overflow-y: auto;
  height: 100%;
}
.label {
  font-size: 11px;
  font-weight: 600;
  color: var(--ink2);
  padding: 6px 10px;
}
.label.spaced {
  padding-top: 16px;
}
a {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 34px;
  padding: 0 10px;
  border-radius: 8px;
  color: var(--ink);
  text-decoration: none;
  font-size: 14px;
}
a:hover {
  color: var(--ink);
  background: var(--fill);
}
a.active {
  background: var(--sel);
  font-weight: 500;
}
.name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.count {
  margin-left: auto;
  font-size: 12px;
  color: var(--ink2);
}
.empty {
  margin: 0;
  padding: 0 10px;
  font-size: 13px;
  color: var(--ink2);
}
.tags {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  padding: 0 10px;
}
a.tag {
  min-height: 0;
  font-size: 12px;
  font-weight: 500;
  color: var(--ink2);
  background: var(--fill);
  border-radius: 999px;
  padding: 4px 10px;
}
a.tag.active {
  background: var(--sel);
  color: var(--acct);
}
.bottom {
  margin-top: auto;
  padding-top: 20px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.new-nb {
  display: flex;
  align-items: center;
  gap: 8px;
  height: 34px;
  padding: 0 10px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  font-size: 14px;
  color: var(--ink2);
  cursor: pointer;
  text-align: left;
}
.store {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px;
  border-radius: 10px;
  border: 1px solid var(--line);
  background: transparent;
  font-size: 12px;
  color: var(--ink2);
  text-align: left;
  cursor: pointer;
  line-height: 1.4;
}
</style>
