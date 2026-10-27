<script setup lang="ts">
import { computed } from 'vue';
import type { ContextMenuItem } from '@nuxt/ui';
import { useNoteit, type View } from '~/composables/useNoteit';
import { useConfirm } from '~/lib/confirm';
import { exportFolder } from '~/utils/exporting';
import { relativeTime } from '~/utils/format';
import { notebookIcon, safeHex } from '~/utils/notebooks';
import type { NotebookRow } from '~/worker/types';

const { state, tags, createNote, openToday, client, refresh, toast } = useNoteit();
const confirm = useConfirm();

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

const library = computed(() => [
  { view: { kind: 'all' } as View, label: 'All Notes', icon: 'i-lucide-file-text', color: 'var(--acc)', count: counts.value.all },
  { view: { kind: 'tasks' } as View, label: 'Tasks', icon: 'i-lucide-list-checks', color: 'var(--acc)', count: undefined },
  { view: { kind: 'pinned' } as View, label: 'Pinned', icon: 'i-lucide-pin', color: 'var(--pinned)', count: counts.value.pinned },
  { view: { kind: 'recent' } as View, label: 'Recent', icon: 'i-lucide-clock', color: 'var(--recent)', count: counts.value.recent },
  { view: { kind: 'trash' } as View, label: 'Recently Deleted', icon: 'i-lucide-trash-2', color: 'var(--ink2)', count: counts.value.trash },
]);

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

const notebookMenu = (nb: NotebookRow): ContextMenuItem[][] => [
  [
    { label: 'New Note Here', icon: 'i-lucide-file-plus', onSelect: () => void createNote(undefined, nb.id) },
    { label: 'New Notebook Inside…', icon: 'i-lucide-folder-plus', onSelect: () => (state.notebookDialog = { mode: 'create', parent: nb.id }) },
  ],
  [{ label: 'Edit Notebook…', icon: 'i-lucide-pencil', onSelect: () => (state.notebookDialog = { mode: 'edit', id: nb.id }) }],
  [{ label: 'Export Notebook', icon: 'i-lucide-folder-down', children: exportFormats(nb.id) }],
];
/** Native Export Notebook… / Export All Notes…: a zip of folders, in Markdown or HTML. */
const exportFormats = (notebookID: string | undefined): ContextMenuItem[] => [
  { label: 'As Markdown', icon: 'i-lucide-file-down', onSelect: () => void exportFolder(notebookID, 'markdown') },
  { label: 'As HTML', icon: 'i-lucide-file-code', onSelect: () => void exportFolder(notebookID, 'html') },
];
const libraryMenu = (v: View): ContextMenuItem[][] => (v.kind === 'all' && counts.value.all ? [[{ label: 'Export All Notes', icon: 'i-lucide-folder-down', children: exportFormats(undefined) }]] : []);
const tagMenu = (tag: string): ContextMenuItem[][] => [
  [
    { label: 'Rename Tag…', icon: 'i-lucide-pencil', onSelect: () => (state.tagRename = tag) },
    { label: 'Delete Tag…', icon: 'i-lucide-trash-2', color: 'error' as const, onSelect: () => void deleteTag(tag) },
  ],
];
async function deleteTag(tag: string): Promise<void> {
  const ok = await confirm({ title: `Delete #${tag}?`, description: `Removes #${tag} and the tags inside it from every note. The notes stay.`, confirmLabel: 'Delete Tag', danger: true });
  if (!ok) return;
  try {
    const r = await client().editTag({ type: 'delete', tag });
    if (state.view.kind === 'tag' && (state.view.tag === tag || state.view.tag.startsWith(`${tag}/`))) state.view = { kind: 'all' };
    await refresh();
    toast(`Removed #${tag} from ${r.changed} note${r.changed === 1 ? '' : 's'}${r.skipped ? ` (${r.skipped} can't be edited here)` : ''}`);
  } catch (e) {
    toast(e instanceof Error ? e.message : String(e), 'error');
  }
}
const smartFolderMenu = (id: string): ContextMenuItem[][] => [[{ label: 'Edit Smart Folder…', icon: 'i-lucide-pencil', onSelect: () => (state.smartFolderDialog = { mode: 'edit', id }) }]];
const item = (active: boolean) => [
  'w-full justify-start gap-2.5 px-2.5 min-h-[34px] text-sm font-normal text-default',
  active ? 'bg-(--sel) hover:bg-(--sel) font-medium' : 'hover:bg-(--fill)',
];
</script>

<template>
  <UDashboardSidebar
    id="sidebar"
    v-model:open="state.drawerOpen"
    resizable
    :min-size="200"
    :default-size="240"
    :max-size="320"
    :toggle="false"
    :menu="{ side: 'left' }"
    :ui="{
      root: 'min-h-0 bg-(--side)',
      header: 'hidden',
      body: 'gap-0.5 px-2.5 py-3.5',
      footer: 'flex-col items-stretch gap-2 px-2.5 pb-3',
      content: 'bg-(--side) max-w-[85%] w-[280px]',
    }"
  >
    <nav aria-label="Library" class="flex flex-col gap-0.5">
      <div class="px-2.5 py-1.5 text-[11px] font-semibold text-muted">Library</div>
      <UButton color="neutral" variant="ghost" :class="item(false)" @click="(state.drawerOpen = false), openToday()">
        <UIcon name="i-lucide-calendar" class="size-[17px] shrink-0" style="color: var(--recent)" />
        <span class="truncate">Today</span>
      </UButton>
      <UContextMenu v-for="l in library" :key="l.label" :items="libraryMenu(l.view)" :disabled="!libraryMenu(l.view).length">
        <UButton
          color="neutral"
          variant="ghost"
          :class="item(isActive(l.view))"
          :aria-current="isActive(l.view) ? 'page' : undefined"
          @click="go(l.view)"
        >
          <UIcon :name="l.icon" class="size-[17px] shrink-0" :style="{ color: l.color }" />
          <span class="truncate">{{ l.label }}</span>
          <span class="ms-auto text-xs text-muted">{{ l.count }}</span>
        </UButton>
      </UContextMenu>

      <div class="px-2.5 pt-4 pb-1.5 text-[11px] font-semibold text-muted">Notebooks</div>
      <UContextMenu v-for="{ nb, depth } in tree" :key="nb.id" :items="notebookMenu(nb)">
        <UButton
          color="neutral"
          variant="ghost"
          :class="item(isActive({ kind: 'notebook', id: nb.id }))"
          :style="{ paddingInlineStart: `${10 + depth * 16}px` }"
          :aria-current="isActive({ kind: 'notebook', id: nb.id }) ? 'page' : undefined"
          @click="go({ kind: 'notebook', id: nb.id })"
          @dblclick.prevent="state.notebookDialog = { mode: 'edit', id: nb.id }"
        >
          <UIcon :name="notebookIcon(nb.symbol)" class="size-[17px] shrink-0" :style="{ color: safeHex(nb.colorHex) }" />
          <span class="truncate">{{ nb.name || 'Untitled' }}</span>
          <span class="ms-auto text-xs text-muted">{{ counts.byNotebook.get(nb.id) ?? 0 }}</span>
        </UButton>
      </UContextMenu>
      <p v-if="!tree.length" class="px-2.5 text-[13px] text-muted">No notebooks yet.</p>

      <template v-if="state.smartFolders.length">
        <div class="px-2.5 pt-4 pb-1.5 text-[11px] font-semibold text-muted">Smart Folders</div>
        <UContextMenu v-for="f in state.smartFolders" :key="f.id" :items="smartFolderMenu(f.id)">
          <UButton
            color="neutral"
            variant="ghost"
            :class="item(isActive({ kind: 'smartFolder', id: f.id }))"
            :aria-current="isActive({ kind: 'smartFolder', id: f.id }) ? 'page' : undefined"
            :title="f.query"
            @click="go({ kind: 'smartFolder', id: f.id })"
            @dblclick.prevent="state.smartFolderDialog = { mode: 'edit', id: f.id }"
          >
            <UIcon name="i-lucide-folder-search" class="size-[17px] shrink-0 text-(--acc)" />
            <span class="truncate">{{ f.name }}</span>
          </UButton>
        </UContextMenu>
      </template>

      <template v-if="tags.length">
        <div class="px-2.5 pt-4 pb-1.5 text-[11px] font-semibold text-muted">Tags</div>
        <div class="flex flex-wrap gap-1.5 px-2.5">
          <UContextMenu v-for="t in tags.slice(0, 30)" :key="t.tag" :items="tagMenu(t.tag)">
            <UButton
              size="xs"
              :color="isActive({ kind: 'tag', tag: t.tag }) ? 'primary' : 'neutral'"
              variant="soft"
              class="rounded-full px-2.5"
              :label="`#${t.tag}`"
              @click="go({ kind: 'tag', tag: t.tag })"
            />
          </UContextMenu>
        </div>
      </template>
    </nav>

    <template #footer>
      <UButton
        color="neutral"
        variant="ghost"
        icon="i-lucide-plus"
        label="New Notebook"
        class="justify-start px-2.5 font-normal text-muted"
        @click="state.notebookDialog = { mode: 'create' }"
      />
      <UButton color="neutral" variant="outline" class="justify-start gap-2 rounded-[10px] p-2.5 text-left text-xs/snug font-normal text-muted ring-(--line)" @click="state.settings = true">
        <UIcon name="i-lucide-server" class="size-[15px] shrink-0" />
        <span>{{ state.mode === 'direct' ? 'Your bucket' : 'This server' }} · encrypted<br /><span class="opacity-80">Last sync {{ state.status.lastSync ? relativeTime(state.status.lastSync).toLowerCase() : 'pending' }}</span></span>
      </UButton>
    </template>
  </UDashboardSidebar>
</template>
