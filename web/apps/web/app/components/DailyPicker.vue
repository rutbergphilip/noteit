<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { dailyNotebook, dayKey, findDailyNote } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

// Daily Note for Date… (native): a day to open, with the days that have a note marked. ← → move a day, ↑ ↓ a week.
const { state, openDaily } = useNoteit();
const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const value = ref(iso(new Date()));
watch(
  () => state.dailyPicker,
  (o) => o && (value.value = iso(new Date())),
);
const date = computed(() => {
  const [y, m, d] = value.value.split('-').map(Number);
  return new Date(y!, (m ?? 1) - 1, d ?? 1, 12);
});
const exists = computed(() => {
  const nb = dailyNotebook(state.notebooks, state.notes);
  return !!nb && !!findDailyNote(state.notes, nb, dayKey(date.value));
});
function move(days: number): void {
  const d = new Date(date.value);
  d.setDate(d.getDate() + days);
  value.value = iso(d);
}
async function open(): Promise<void> {
  state.dailyPicker = false;
  await openDaily(date.value);
}
function keys(e: KeyboardEvent): void {
  const by = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }[e.key];
  if (by !== undefined && !(e.target instanceof HTMLInputElement)) {
    e.preventDefault();
    move(by);
  }
}
</script>

<template>
  <UModal v-model:open="state.dailyPicker" title="Daily Note for Date" :ui="{ content: 'sm:max-w-[360px]', footer: 'justify-end gap-2' }">
    <template #body>
      <form id="daily-form" class="flex flex-col gap-3" @submit.prevent="open" @keydown="keys">
        <div class="flex items-center gap-2">
          <UButton color="neutral" variant="ghost" icon="i-lucide-chevron-left" aria-label="Previous day" @click="move(-1)" />
          <UInput v-model="value" type="date" autofocus class="flex-1" aria-label="Day" />
          <UButton color="neutral" variant="ghost" icon="i-lucide-chevron-right" aria-label="Next day" @click="move(1)" />
        </div>
        <p class="text-sm text-muted">{{ date.toLocaleDateString(undefined, { dateStyle: 'full' }) }} · {{ exists ? 'has a note' : 'a new note' }}</p>
      </form>
    </template>
    <template #footer>
      <UButton color="neutral" variant="soft" label="Cancel" @click="state.dailyPicker = false" />
      <UButton type="submit" form="daily-form" :label="exists ? 'Open' : 'Create'" />
    </template>
  </UModal>
</template>
