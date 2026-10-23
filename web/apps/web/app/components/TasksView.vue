<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { compareLocal, type LocalDateTime, localDateTimeToken, localToDate } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

// Native's Tasks (⇧⌘T): every checklist item from every note, grouped Overdue, Today, Upcoming, Later and No Date.
type Task = Awaited<ReturnType<ReturnType<ReturnType<typeof useNoteit>['client']>['tasks']>>[number];
const { state, client, openNote, toast } = useNoteit();
const tasks = ref<Task[]>([]);
const showCompleted = ref(false);

async function load(): Promise<void> {
  tasks.value = await client().tasks();
}
watch(() => state.notes, () => void load(), { immediate: true });

const UPCOMING_DAYS = 7;
function group(t: Task, now: Date): string {
  if (!t.due) return 'No Date';
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const due = localToDate(t.due);
  const overdue = t.due.hour !== undefined ? due < now : due < today;
  if (overdue && !t.checked) return 'Overdue';
  const day = new Date(t.due.year, t.due.month - 1, t.due.day);
  if (day.getTime() === today.getTime()) return 'Today';
  if (day.getTime() - today.getTime() <= UPCOMING_DAYS * 86_400_000) return 'Upcoming';
  return 'Later';
}

const ORDER = ['Overdue', 'Today', 'Upcoming', 'Later', 'No Date'];
const groups = computed(() => {
  const now = new Date();
  const by = new Map<string, Task[]>();
  for (const t of tasks.value) {
    if (t.checked && !showCompleted.value) continue;
    const g = group(t, now);
    by.set(g, [...(by.get(g) ?? []), t]);
  }
  return ORDER.filter((g) => by.has(g)).map((g) => ({
    label: g,
    items: by.get(g)!.sort((a, b) => (a.due && b.due ? compareLocal(a.due, b.due) : 0) || a.noteTitle.localeCompare(b.noteTitle)),
  }));
});

async function toggle(t: Task): Promise<void> {
  try {
    await client().setTaskChecked(t.noteId, t.block, !t.checked);
  } catch (e) {
    toast(e instanceof Error ? e.message : "Couldn't change the task", 'error');
  }
}

const dueText = (d: LocalDateTime) =>
  localToDate(d).toLocaleString(undefined, d.hour !== undefined ? { dateStyle: 'medium', timeStyle: 'short' } : { dateStyle: 'medium' });
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
    <div class="flex h-full min-h-0 flex-col">
      <div class="flex items-center gap-2 border-b border-default px-4 py-3">
        <UIcon name="i-lucide-list-checks" class="size-[18px] text-(--acc)" />
        <h2 class="flex-1 text-[15px] font-semibold">Tasks</h2>
        <USwitch v-model="showCompleted" size="sm" label="Completed" />
      </div>
      <div class="flex-1 overflow-y-auto px-2 py-2">
        <p v-if="!groups.length" class="px-3 py-8 text-center text-sm text-muted">
          No tasks. Checklist items (⇧⌘L) from all your notes show here; give one a date with <code>@due(2026-10-24)</code>.
        </p>
        <section v-for="g in groups" :key="g.label" class="mb-3">
          <h3 class="px-2 pb-1 text-[11px] font-semibold text-muted" :class="g.label === 'Overdue' && 'text-error'">{{ g.label }}</h3>
          <ul>
            <li v-for="t in g.items" :key="`${t.noteId}:${t.block}`" class="flex items-start gap-2.5 rounded-md px-2 py-1.5 hover:bg-(--fill)">
              <UCheckbox :model-value="t.checked" class="mt-0.5" :aria-label="t.checked ? 'Mark not done' : 'Mark done'" @update:model-value="toggle(t)" />
              <button type="button" class="min-w-0 flex-1 cursor-pointer text-left" @click="openNote(t.noteId)">
                <span class="block text-sm" :class="t.checked && 'text-muted line-through'">{{ t.text || 'Untitled task' }}</span>
                <span class="block truncate text-xs text-muted">
                  {{ t.noteTitle || 'Untitled' }}<template v-if="t.due"> · {{ dueText(t.due) }}</template><template v-if="t.remind"> · <UIcon name="i-lucide-bell" class="size-3 align-[-1px]" /> {{ localDateTimeToken(t.remind) }}</template>
                </span>
              </button>
            </li>
          </ul>
        </section>
      </div>
    </div>
  </UDashboardPanel>
</template>
