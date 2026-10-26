<script setup lang="ts">
import { computed, ref, shallowRef, watch } from 'vue';
import { CalendarDate, type DateValue, getLocalTimeZone, parseDate, today } from '@internationalized/date';
import { dailyNotebook, dayKey, findDailyNote } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

// Daily Note for Date… (native): a calendar with the days that have a note marked. ← → move a day, ↑ ↓ a week,
// PageUp/PageDown a month, Return opens.
const { state, openDaily } = useNoteit();
const value = shallowRef<DateValue>(today(getLocalTimeZone()));
// Remounts the modal (a fresh portal, above the sidebar drawer: see useOpeningKey) and the calendar per opening.
const opening = ref(0);
watch(
  () => state.dailyPicker,
  (o) => {
    if (!o) return;
    value.value = today(getLocalTimeZone());
    opening.value++;
  },
);
const toDate = (d: DateValue) => new Date(d.year, d.month - 1, d.day, 12);
const date = computed(() => toDate(value.value));
const notebook = computed(() => dailyNotebook(state.notebooks, state.notes));
const hasNote = (d: DateValue) => !!notebook.value && !!findDailyNote(state.notes, notebook.value, dayKey(toDate(d)));
const exists = computed(() => hasNote(value.value));

async function open(): Promise<void> {
  state.dailyPicker = false;
  await openDaily(date.value);
}
function select(d: DateValue | undefined): void {
  // Clicking the selected day again would clear it; keep a day picked.
  if (d) value.value = new CalendarDate(d.year, d.month, d.day);
}
// Return on a day opens that day (caught before the calendar's own handler, which only selects it).
function onKey(e: KeyboardEvent): void {
  const cell = e.key === 'Enter' && e.target instanceof HTMLElement ? e.target.closest<HTMLElement>('[data-reka-calendar-cell-trigger]') : null;
  const day = cell?.dataset.value ? parseDate(cell.dataset.value) : undefined;
  if (!day) return;
  e.preventDefault();
  e.stopPropagation();
  select(day);
  void open();
}
// The arrow keys move the focused day; the day shown below follows it, as the Mac's picker does.
function onPlaceholder(d: DateValue): void {
  select(d);
}
</script>

<template>
  <UModal :key="opening" v-model:open="state.dailyPicker" title="Daily Note for Date" :ui="{ content: 'sm:max-w-[360px]', footer: 'justify-end gap-2' }">
    <template #body>
      <div class="flex flex-col items-center gap-3" @keydown.capture="onKey">
        <UCalendar
          :model-value="value"
          initial-focus
          fixed-weeks
          :ui="{ root: 'w-full' }"
          aria-label="Day"
          @update:model-value="(d) => select(d as DateValue | undefined)"
          @update:placeholder="onPlaceholder"
          @dblclick="open"
        >
          <template #day="{ day }">
            <span class="relative">
              {{ day.day }}
              <span v-if="hasNote(day)" class="absolute -bottom-1 left-1/2 size-1 -translate-x-1/2 rounded-full bg-(--acc)" aria-hidden="true" />
            </span>
          </template>
        </UCalendar>
        <p class="self-start text-sm text-muted" aria-live="polite">{{ date.toLocaleDateString(undefined, { dateStyle: 'full' }) }} · {{ exists ? 'has a note' : 'a new note' }}</p>
      </div>
    </template>
    <template #footer>
      <UButton color="neutral" variant="soft" label="Cancel" @click="state.dailyPicker = false" />
      <UButton :label="exists ? 'Open' : 'Create'" @click="open" />
    </template>
  </UModal>
</template>
