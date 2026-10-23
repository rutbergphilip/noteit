<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue';
import type { Editor } from '@tiptap/core';
import { findKey, findMatches, findPattern, type FindMatch, replaceMatches } from '@noteit/doc/tiptap';
import { useNoteit } from '~/composables/useNoteit';

// The find bar (native FindReplaceBar): ⌥⌘F find, ⇧⌘F with replace, ↩/⇧↩ or ⌘G/⇧⌘G between matches, ⌘E uses the
// selection, Esc goes back to the text with the match selected. Replacing is off in Recently Deleted.
const props = defineProps<{ editor?: Editor; canReplace: boolean }>();
const { state } = useNoteit();

const query = ref('');
const replacement = ref('');
const matchCase = ref(false);
const wholeWord = ref(false);
const regex = ref(false);
const current = ref(0);
const matches = ref<FindMatch[]>([]);
const findInput = ref<{ inputRef?: HTMLInputElement }>();
const pattern = computed(() => findPattern(query.value, { matchCase: matchCase.value, wholeWord: wholeWord.value, regex: regex.value }));
const error = computed(() => (typeof pattern.value === 'string' ? pattern.value : undefined));

function recompute(keep = true): void {
  const ed = props.editor;
  if (!ed) return;
  matches.value = pattern.value instanceof RegExp ? findMatches(ed.state.doc, pattern.value) : [];
  if (!keep || current.value >= matches.value.length) {
    // Start at the first match after the caret.
    const at = ed.state.selection.from;
    const i = matches.value.findIndex((m) => m.from >= at);
    current.value = i < 0 ? 0 : i;
  }
  paint();
}
function paint(): void {
  const ed = props.editor;
  if (!ed) return;
  ed.view.dispatch(ed.state.tr.setMeta(findKey, { matches: state.find.open ? matches.value : [], current: current.value }));
  const m = matches.value[current.value];
  if (m && state.find.open) (ed.view.domAtPos(m.from).node as HTMLElement).parentElement?.scrollIntoView?.({ block: 'nearest' });
}
function step(by: number): void {
  if (!matches.value.length) return;
  current.value = (current.value + by + matches.value.length) % matches.value.length;
  paint();
}
function replaceOne(): void {
  const ed = props.editor;
  const m = matches.value[current.value];
  if (!ed || !m || !props.canReplace) return;
  ed.view.dispatch(replaceMatches(ed.state.tr, [m], replacement.value, regex.value));
  recompute();
}
function replaceAll(): void {
  const ed = props.editor;
  if (!ed || !matches.value.length || !props.canReplace) return;
  ed.view.dispatch(replaceMatches(ed.state.tr, matches.value, replacement.value, regex.value));
  recompute(false);
}
function close(): void {
  state.find.open = false;
  const ed = props.editor;
  const m = matches.value[current.value];
  paint();
  if (ed) {
    ed.commands.focus();
    if (m) ed.commands.setTextSelection({ from: m.from, to: m.to });
  }
}
function useSelection(): void {
  const ed = props.editor;
  if (!ed) return;
  const { from, to } = ed.state.selection;
  if (from !== to) query.value = ed.state.doc.textBetween(from, to, ' ');
}

watch([query, matchCase, wholeWord, regex], () => recompute(false));
watch(
  () => [state.find.open, state.find.seq] as const,
  async ([open]) => {
    if (!open) return paint();
    useSelection();
    recompute(false);
    await nextTick();
    findInput.value?.inputRef?.focus();
    findInput.value?.inputRef?.select();
  },
);
// Edits move matches along; recount after each change while the bar is open.
watch(
  () => props.editor,
  (ed, old) => {
    old?.off('update', onDocChange);
    ed?.on('update', onDocChange);
  },
  { immediate: true },
);
function onDocChange(): void {
  if (state.find.open) recompute();
}

/** ⌘G / ⇧⌘G and ⌘E work from the text too. */
function onKey(e: KeyboardEvent): void {
  if (!props.editor || !(e.metaKey || e.ctrlKey) || e.altKey) return;
  if (e.code === 'KeyG' && state.find.open) {
    e.preventDefault();
    step(e.shiftKey ? -1 : 1);
  } else if (e.code === 'KeyE' && !e.shiftKey && props.editor.isFocused) {
    e.preventDefault();
    useSelection();
  }
}
window.addEventListener('keydown', onKey);
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKey);
  props.editor?.off('update', onDocChange);
});

function findKeys(e: KeyboardEvent): void {
  if (e.key === 'Enter') {
    e.preventDefault();
    if (e.altKey && (e.metaKey || e.ctrlKey)) return replaceAll();
    step(e.shiftKey ? -1 : 1);
  } else if (e.key === 'Escape') {
    e.preventDefault();
    close();
  }
}
function replaceKeys(e: KeyboardEvent): void {
  if (e.key === 'Enter') {
    e.preventDefault();
    if (e.altKey && (e.metaKey || e.ctrlKey)) replaceAll();
    else replaceOne();
  } else if (e.key === 'Escape') {
    e.preventDefault();
    close();
  } else if (e.code === 'Digit1' && e.shiftKey && (e.metaKey || e.ctrlKey)) {
    e.preventDefault();
    replaceOne();
  }
}
const toggles = computed(() => [
  { model: matchCase, label: 'Match Case', text: 'Aa' },
  { model: wholeWord, label: 'Whole Word', text: 'ab' },
  { model: regex, label: 'Regular Expression', text: '.*' },
]);
</script>

<template>
  <div v-if="state.find.open" class="flex flex-col gap-1.5 border-b border-default bg-(--side) px-5 py-2 max-md:px-2" role="search" aria-label="Find in note">
    <div class="flex items-center gap-1.5">
      <UInput
        ref="findInput"
        v-model="query"
        size="sm"
        placeholder="Find"
        aria-label="Find"
        icon="i-lucide-search"
        spellcheck="false"
        class="min-w-0 flex-1"
        :color="error ? 'error' : undefined"
        :highlight="!!error"
        @keydown="findKeys"
      >
        <template #trailing>
          <span class="text-xs text-muted tabular-nums">{{ query ? (matches.length ? `${current + 1} of ${matches.length}` : 'No matches') : '' }}</span>
        </template>
      </UInput>
      <UTooltip v-for="t in toggles" :key="t.label" :text="t.label">
        <UButton color="neutral" :variant="t.model.value ? 'soft' : 'ghost'" size="xs" class="font-mono" :label="t.text" :aria-label="t.label" :aria-pressed="t.model.value" @click="t.model.value = !t.model.value" />
      </UTooltip>
      <UButton color="neutral" variant="ghost" size="xs" icon="i-lucide-chevron-up" aria-label="Previous match" @click="step(-1)" />
      <UButton color="neutral" variant="ghost" size="xs" icon="i-lucide-chevron-down" aria-label="Next match" @click="step(1)" />
      <UButton color="neutral" variant="ghost" size="xs" :label="state.find.replace ? 'Hide Replace' : 'Replace'" :disabled="!canReplace" @click="state.find.replace = !state.find.replace" />
      <UButton color="neutral" variant="ghost" size="xs" icon="i-lucide-x" aria-label="Close find" @click="close" />
    </div>
    <p v-if="error" class="text-xs text-error">{{ error }}</p>
    <div v-if="state.find.replace && canReplace" class="flex items-center gap-1.5">
      <UInput v-model="replacement" size="sm" placeholder="Replace" aria-label="Replace" icon="i-lucide-replace" spellcheck="false" class="min-w-0 flex-1" @keydown="replaceKeys" />
      <UButton color="neutral" variant="outline" size="xs" label="Replace" :disabled="!matches.length" @click="replaceOne" />
      <UButton color="neutral" variant="outline" size="xs" label="All" :disabled="!matches.length" @click="replaceAll" />
    </div>
  </div>
</template>
