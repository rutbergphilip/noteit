<script setup lang="ts">
import { computed, ref } from 'vue';
import type { DropdownMenuItem } from '@nuxt/ui';
import { useNoteit } from '~/composables/useNoteit';

const { state, createNote, setQuery, lock, signOut, setTheme } = useNoteit();

const initials = computed(() => {
  const name = state.session?.user.displayName || state.session?.user.username || '?';
  return name
    .split(/\s+/)
    .map((p) => p[0])
    .join('')
    .slice(0, 2)
    .toUpperCase();
});

let searchTimer: ReturnType<typeof setTimeout> | undefined;
const search = ref(state.query);
function onSearch(): void {
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = setTimeout(() => void setQuery(search.value), 120);
}

const accountItems = computed<DropdownMenuItem[][]>(() => [
  [{ type: 'label', label: state.session?.user.displayName, description: `@${state.session?.user.username}`, avatar: { text: initials.value, class: 'bg-(--avatar) text-white' } }],
  [
    {
      label: 'Appearance',
      icon: state.theme === 'dark' ? 'i-lucide-moon' : state.theme === 'light' ? 'i-lucide-sun' : 'i-lucide-sun-moon',
      children: (['system', 'light', 'dark'] as const).map((t) => ({
        label: t === 'system' ? 'System' : t === 'light' ? 'Light' : 'Dark',
        type: 'checkbox' as const,
        checked: state.theme === t,
        onSelect: (e: Event) => {
          e.preventDefault();
          setTheme(t);
        },
      })),
    },
    { label: 'Quick Capture', icon: 'i-lucide-pen-line', kbds: ['alt', 'meta', 'C'], onSelect: () => (state.capture = true) },
    { label: 'Settings', icon: 'i-lucide-sliders-horizontal', kbds: ['meta', ','], onSelect: () => (state.settings = true) },
  ],
  [
    { label: 'Lock', icon: 'i-lucide-lock', onSelect: () => void lock() },
    { label: 'Sign Out', icon: 'i-lucide-log-out', onSelect: () => void signOut() },
  ],
]);

function home(): void {
  state.view = { kind: 'all' };
  state.pane = 'list';
}
</script>

<template>
  <!-- design p01 (desktop), p13 (tablet: sidebar as a drawer), p14 (phone: one pane at a time) -->
  <div class="flex h-dvh flex-col bg-default">
    <header class="flex h-(--header-h) flex-none items-center gap-2 border-b border-default bg-(--top) px-2 sm:gap-4 sm:px-4">
      <UButton class="lg:hidden" color="neutral" variant="ghost" size="lg" icon="i-lucide-menu" aria-label="Show notebooks and tags" @click="state.drawerOpen = true" />
      <a href="#" class="flex flex-none items-center gap-2.5 text-[19px] no-underline lg:w-[220px]" aria-label="NoteIt home" @click.prevent="home">
        <img src="/noteit-icon.png" alt="" width="30" height="30" />
        <span class="ni-wordmark max-md:hidden">Note<span>It</span></span>
      </a>

      <UInput
        v-model="search"
        type="search"
        icon="i-lucide-search"
        placeholder="Search notes and commands"
        variant="soft"
        aria-label="Search notes"
        class="max-w-[520px] flex-[1_1_280px] max-md:hidden"
        :ui="{ base: 'bg-(--fill) hover:bg-(--fill) focus-visible:bg-(--fill)', trailing: 'pe-2' }"
        @update:model-value="onSearch"
        @keydown.enter.prevent="state.palette = true"
      >
        <template #trailing>
          <UTooltip v-if="state.searchIssues.length" :text="state.searchIssues.join(' ')">
            <UIcon name="i-lucide-triangle-alert" class="size-4 text-warning" aria-label="Search problem" />
          </UTooltip>
          <UKbd value="meta" variant="outline" /><UKbd value="K" variant="outline" />
        </template>
      </UInput>

      <div class="ms-auto flex flex-none items-center gap-1.5 sm:gap-2">
        <UButton class="md:hidden" color="neutral" variant="soft" size="lg" icon="i-lucide-search" aria-label="Search notes and commands" @click="state.palette = true" />
        <SyncPill />
        <UTooltip text="New note" :kbds="['alt', 'meta', 'N']">
          <UButton size="lg" icon="i-lucide-plus" aria-label="New note" :ui="{ label: 'max-md:hidden' }" label="New Note" @click="createNote()" />
        </UTooltip>
        <UTooltip text="Settings" :kbds="['meta', ',']">
          <UButton class="max-md:hidden" color="neutral" variant="ghost" size="lg" icon="i-lucide-sliders-horizontal" aria-label="Settings" @click="state.settings = true" />
        </UTooltip>
        <UDropdownMenu :items="accountItems" :content="{ align: 'end', sideOffset: 8 }" :ui="{ content: 'w-60' }">
          <UButton color="neutral" variant="ghost" square class="rounded-full p-0.5" aria-label="Account">
            <UAvatar :text="initials" size="md" class="bg-(--avatar) text-xs font-bold text-white" :ui="{ fallback: 'text-white' }" />
          </UButton>
        </UDropdownMenu>
      </div>
    </header>

    <UDashboardGroup storage="local" storage-key="noteit-panes" unit="px" class="relative inset-auto min-h-0 flex-1">
      <AppSidebar />
      <TasksView v-if="state.view.kind === 'tasks'" />
      <NoteList v-else />
      <UDashboardPanel id="editor" :class="['min-h-0', state.pane === 'list' && 'max-md:hidden']">
        <NoteEditor v-if="state.selectedId" :key="state.selectedId" :note-id="state.selectedId" />
        <div v-else class="flex flex-1 flex-col items-center justify-center gap-3 text-muted opacity-85">
          <img src="/noteit-icon.png" alt="" width="64" height="64" />
          <p class="flex items-center gap-1">Select a note, or press <UKbd value="alt" /><UKbd value="meta" /><UKbd value="N" /> for a new one.</p>
        </div>
      </UDashboardPanel>
    </UDashboardGroup>
  </div>
</template>
