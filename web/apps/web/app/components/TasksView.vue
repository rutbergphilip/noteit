<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue';
import { compareLocal, type LocalDateTime, localDateTimeToken, localToDate } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

// Native's Tasks (⇧⌘T): every checklist item from every note, grouped Overdue, Today, Upcoming, Later and No Date.
type Task = Awaited<ReturnType<ReturnType<ReturnType<typeof useNoteit>['client']>['tasks']>>[number];
const { state, client, openNote, toast } = useNoteit();
const tasks = ref<Task[]>([]);
const showCompleted = ref(false);

// The search box filters tasks, as native's "Search Tasks" does.
async function load(): Promise<void> {
  tasks.value = await client().tasks(state.query);
}
watch([() => state.notes, () => state.query], () => void load(), { immediate: true });

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

// Rows are one listbox: ↑/↓ select, Space checks, ↩ or double-click opens the note in All Notes (native TaskListView).
const keyOf = (t: Task) => `${t.noteId}:${t.block}`;
const flat = computed(() => groups.value.flatMap((g) => g.items));
const selected = ref<string>();
const list = ref<HTMLElement>();
const optionId = (t: Task) => `task-${keyOf(t).replace(/[^\w-]/g, '_')}`;

function select(t: Task | undefined): void {
  if (!t) return;
  selected.value = keyOf(t);
  // Selecting shows the note beside the list without leaving Tasks.
  state.selectedId = t.noteId;
  void nextTick(() => document.getElementById(optionId(t))?.scrollIntoView({ block: 'nearest' }));
}

function onKey(e: KeyboardEvent): void {
  const items = flat.value;
  if (!items.length) return;
  const i = items.findIndex((t) => keyOf(t) === selected.value);
  const current = i >= 0 ? items[i] : undefined;
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    select(items[i < 0 ? 0 : Math.min(items.length - 1, Math.max(0, i + (e.key === 'ArrowDown' ? 1 : -1)))]);
  } else if (e.key === 'Home' || e.key === 'End') {
    e.preventDefault();
    select(items[e.key === 'Home' ? 0 : items.length - 1]);
  } else if (e.key === ' ' && current) {
    e.preventDefault();
    void toggle(current);
  } else if (e.key === 'Enter' && current) {
    e.preventDefault();
    openNote(current.noteId);
  }
}

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
        <p v-if="!groups.length && state.query.trim()" class="px-3 py-8 text-center text-sm text-muted">No tasks match “{{ state.query }}”.</p>
        <p v-else-if="!groups.length" class="px-3 py-8 text-center text-sm text-muted">
          No tasks. Checklist items (⇧⌘L) from all your notes show here; give one a date with <code>@due(2026-10-24)</code>.
        </p>
        <div
          v-else
          ref="list"
          role="listbox"
          tabindex="0"
          aria-label="Tasks"
          :aria-activedescendant="flat.find((t) => keyOf(t) === selected) ? optionId(flat.find((t) => keyOf(t) === selected)!) : undefined"
          class="rounded-md outline-none focus-visible:ring-2 focus-visible:ring-(--acc)"
          @keydown="onKey"
          @focus="!selected && select(flat[0])"
        >
          <section v-for="g in groups" :key="g.label" class="mb-3" role="group" :aria-label="g.label">
            <h3 class="px-2 pb-1 text-[11px] font-semibold text-muted" :class="g.label === 'Overdue' && 'text-error'" aria-hidden="true">{{ g.label }}</h3>
            <div
              v-for="t in g.items"
              :id="optionId(t)"
              :key="keyOf(t)"
              role="option"
              :aria-selected="selected === keyOf(t)"
              :aria-checked="t.checked"
              class="flex cursor-default items-start gap-2.5 rounded-md px-2 py-1.5"
              :class="selected === keyOf(t) ? 'bg-(--sel)' : 'hover:bg-(--fill)'"
              @click="select(t)"
              @dblclick="openNote(t.noteId)"
            >
              <UCheckbox :model-value="t.checked" class="mt-0.5" tabindex="-1" :aria-label="t.checked ? 'Mark not done' : 'Mark done'" @click.stop @update:model-value="toggle(t)" />
              <div class="min-w-0 flex-1 select-none text-left">
                <span class="block text-sm" :class="t.checked && 'text-muted line-through'">{{ t.text || 'Untitled task' }}</span>
                <span class="block truncate text-xs text-muted">
                  {{ t.noteTitle || 'Untitled' }}<template v-if="t.due"> · {{ dueText(t.due) }}</template><template v-if="t.remind"> · <UIcon name="i-lucide-bell" class="size-3 align-[-1px]" /> {{ localDateTimeToken(t.remind) }}</template>
                </span>
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
  </UDashboardPanel>
</template>
