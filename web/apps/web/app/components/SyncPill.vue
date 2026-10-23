<script setup lang="ts">
import { computed, ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';
import { relativeTime } from '~/utils/format';

const { state, client } = useNoteit();
const open = ref(false);
const syncing = computed(() => state.status.phase === 'syncing');

const view = computed(() => {
  const s = state.status;
  switch (s.phase) {
    case 'syncing':
      return { icon: 'i-lucide-refresh-cw', label: 'Syncing…', color: 'neutral' as const };
    case 'offline':
      return { icon: 'i-lucide-cloud-off', label: 'Offline', color: 'warning' as const };
    case 'error':
      return { icon: 'i-lucide-triangle-alert', label: 'Sync Issue', color: 'error' as const };
    case 'legacy':
      return { icon: 'i-lucide-triangle-alert', label: 'Needs your Mac', color: 'warning' as const };
    case 'locked':
      return { icon: 'i-lucide-lock', label: 'Locked', color: 'neutral' as const };
    default:
      return s.pending > 0 ? { icon: 'i-lucide-cloud-upload', label: `${s.pending} to sync`, color: 'neutral' as const } : { icon: 'i-lucide-lock', label: 'Synced · encrypted', color: 'neutral' as const };
  }
});

const failed = computed(() => state.status.recordErrors.map((e) => ({ ...e, title: e.id ? state.notes.find((n) => n.id === e.id)?.title || 'Untitled' : undefined })));
function openNote(id: string): void {
  state.selectedId = id;
  state.pane = 'editor';
  open.value = false;
}
</script>

<template>
  <UPopover v-model:open="open" :content="{ align: 'end', sideOffset: 8 }">
    <UButton
      :color="view.color"
      variant="soft"
      size="sm"
      class="rounded-full px-3 font-normal"
      :class="view.color === 'neutral' && 'bg-(--fill) text-muted hover:bg-(--fill)'"
      :icon="view.icon"
      :ui="{ leadingIcon: ['size-3.5', syncing && 'animate-spin'], label: 'max-lg:hidden' }"
      :label="view.label"
      :aria-label="view.label"
      role="status"
    />
    <template #content>
      <div class="flex w-[min(320px,calc(100vw-32px))] flex-col gap-2 p-3.5 text-[13px]" aria-label="Sync details">
        <strong class="text-sm">{{ view.label }}</strong>
        <p class="leading-normal text-muted">Last synced {{ state.status.lastSync ? relativeTime(state.status.lastSync) : 'not yet' }}. Notes are encrypted in this browser before they're uploaded.</p>
        <p v-if="state.status.detail && state.status.phase !== 'idle'" class="text-muted">{{ state.status.detail }}</p>
        <template v-if="failed.length">
          <div>{{ failed.length }} {{ failed.length === 1 ? 'item' : 'items' }} will be retried on the next sync</div>
          <ul class="flex flex-col gap-1 ps-1">
            <li v-for="(f, i) in failed" :key="i" class="flex flex-col">
              <UButton v-if="f.id" variant="link" size="xs" class="p-0" :label="f.title" @click="openNote(f.id)" />
              <span class="text-muted">{{ f.message }}</span>
            </li>
          </ul>
        </template>
        <UButton size="sm" class="self-start" icon="i-lucide-refresh-cw" :loading="syncing" label="Sync Now" @click="client().syncNow()" />
      </div>
    </template>
  </UPopover>
</template>
