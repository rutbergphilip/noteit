<script setup lang="ts">
import { computed } from 'vue';
import type { ContextMenuItem } from '@nuxt/ui';
import { useConfirm } from '~/lib/confirm';
import { useNoteit } from '~/composables/useNoteit';
import { relativeTime } from '~/utils/format';
import { notebookIcon, safeHex } from '~/utils/notebooks';
import type { NoteRow } from '~/worker/types';

const { state, visibleNotes, client, createNote, refresh, toast } = useNoteit();
const confirm = useConfirm();

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

const sortOptions = [
  { value: 'edited', label: 'Recently edited' },
  { value: 'created', label: 'Recently created' },
  { value: 'title', label: 'Title' },
];

const notebookOf = (id?: string) => (id ? state.notebooks.find((n) => n.id === id) : undefined);
function open(id: string): void {
  state.selectedId = id;
  state.pane = 'editor';
}

async function emptyTrash(): Promise<void> {
  const ok = await confirm({
    title: 'Empty Recently Deleted?',
    description: 'Every note here is deleted for good, on all your devices.',
    confirmLabel: 'Delete for Good',
    danger: true,
  });
  if (!ok) return;
  for (const n of visibleNotes.value) await client().deleteForever(n.id);
}

async function setMeta(n: NoteRow, meta: Parameters<ReturnType<typeof client>['updateNoteMeta']>[1], done?: string): Promise<void> {
  await client().updateNoteMeta(n.id, meta);
  await refresh();
  if (done) toast(done);
}

/** Right-click (or long-press) on a note: the actions from the editor bar, without opening it. */
function rowMenu(n: NoteRow): ContextMenuItem[][] {
  if (n.deletedAt) {
    return [
      [{ label: 'Recover', icon: 'i-lucide-rotate-ccw', onSelect: () => void setMeta(n, { trashed: false }, 'Note recovered') }],
      [
        {
          label: 'Delete for Good…',
          icon: 'i-lucide-trash-2',
          color: 'error',
          onSelect: async () => {
            if (await confirm({ title: 'Delete this note for good?', description: 'It is removed from all your devices.', confirmLabel: 'Delete', danger: true })) await client().deleteForever(n.id);
          },
        },
      ],
    ];
  }
  return [
    [
      { label: 'Open', icon: 'i-lucide-square-arrow-out-up-right', onSelect: () => open(n.id) },
      { label: n.isPinned ? 'Unpin' : 'Pin', icon: n.isPinned ? 'i-lucide-pin-off' : 'i-lucide-pin', onSelect: () => void setMeta(n, { isPinned: !n.isPinned }) },
      {
        label: 'Move to',
        icon: 'i-lucide-folder-input',
        children: [
          { label: 'No Notebook', icon: 'i-lucide-circle-dashed', type: 'checkbox' as const, checked: !n.notebookID, onSelect: () => void setMeta(n, { notebookID: null }) },
          ...state.notebooks.map((nb) => ({
            label: nb.name || 'Untitled',
            icon: notebookIcon(nb.symbol),
            type: 'checkbox' as const,
            checked: n.notebookID === nb.id,
            onSelect: () => void setMeta(n, { notebookID: nb.id }),
          })),
        ],
      },
    ],
    [{ label: 'Move to Recently Deleted', icon: 'i-lucide-trash-2', color: 'error', onSelect: () => void setMeta(n, { trashed: true }, 'Moved to Recently Deleted') }],
  ];
}
</script>

<template>
  <UDashboardPanel
    id="notes"
    resizable
    :min-size="260"
    :default-size="340"
    :max-size="480"
    :class="['min-h-0 bg-(--list) max-lg:border-e max-lg:border-default', state.pane === 'editor' && 'max-md:hidden']"
    :ui="{ root: 'max-md:w-full md:max-lg:w-80' }"
  >
    <section class="flex h-full min-h-0 flex-col gap-1 px-2.5 py-4" aria-label="Notes">
      <div class="flex items-baseline justify-between gap-2 px-2.5 pb-2.5">
        <div class="min-w-0">
          <h1 class="text-xl font-bold [overflow-wrap:anywhere]">{{ heading }}</h1>
          <div class="mt-0.5 text-xs text-muted">{{ visibleNotes.length }} {{ visibleNotes.length === 1 ? 'note' : 'notes' }}</div>
        </div>
        <USelect
          v-model="state.sort"
          :items="sortOptions"
          variant="ghost"
          size="sm"
          aria-label="Sort notes"
          class="w-auto text-muted"
          :content="{ align: 'end' }"
          :ui="{ base: 'text-[13px] text-muted', content: 'min-w-44' }"
        />
      </div>
      <div v-if="state.view.kind === 'trash' && visibleNotes.length" class="mx-2.5 mb-1.5 flex items-center gap-1 text-xs text-muted">
        Notes here are deleted for good after 30 days.
        <UButton variant="link" size="xs" class="p-0" label="Empty" @click="emptyTrash" />
      </div>

      <div class="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto" role="list">
        <UContextMenu v-for="n in visibleNotes" :key="n.id" :items="rowMenu(n)">
          <a
            href="#"
            role="listitem"
            class="block rounded-xl p-3 text-default no-underline transition-colors duration-100 hover:bg-(--fill) focus-visible:outline-2 focus-visible:outline-primary"
            :class="{ 'bg-(--sel) hover:bg-(--sel)': n.id === state.selectedId }"
            :aria-current="n.id === state.selectedId ? 'true' : undefined"
            @click.prevent="open(n.id)"
          >
            <div class="flex items-center gap-1.5 text-sm font-semibold">
              <UIcon v-if="n.kind === 'locked'" name="i-lucide-lock" class="size-[13px] shrink-0" />
              <span class="truncate">{{ n.title || 'Untitled' }}</span>
              <UIcon v-if="n.isPinned" name="i-lucide-pin" class="ms-auto size-3.5 shrink-0 text-(--pinned)" />
            </div>
            <div v-if="n.preview" class="mt-1 line-clamp-2 text-[13px]/[18px] text-muted">{{ n.preview }}</div>
            <div class="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs text-muted">
              {{ relativeTime(n.updatedAt) }}
              <template v-if="notebookOf(n.notebookID)">
                <span class="size-[7px] rounded-full" :style="{ background: safeHex(notebookOf(n.notebookID)!.colorHex) }" />{{ notebookOf(n.notebookID)!.name }}
              </template>
              <UBadge v-if="n.conflictSource" color="warning" variant="soft" size="sm" class="rounded-full" label="Conflict copy" />
              <UBadge v-if="n.kind === 'legacy'" color="warning" variant="soft" size="sm" class="rounded-full" label="Older Mac format" />
            </div>
          </a>
        </UContextMenu>
        <div v-if="!visibleNotes.length" class="flex flex-col items-center gap-3 px-2.5 py-6 text-center text-sm text-muted">
          <template v-if="state.query">No notes match “{{ state.query }}”.</template>
          <template v-else-if="state.view.kind === 'trash'">Nothing in Recently Deleted.</template>
          <template v-else>
            <p>No notes here yet.</p>
            <UButton icon="i-lucide-plus" label="New Note" @click="createNote()" />
          </template>
        </div>
      </div>
    </section>
  </UDashboardPanel>
</template>
