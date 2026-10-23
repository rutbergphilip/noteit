<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { tagRenameProblem } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

// Rename Tag… (native TagEditSheets): every note's #tag and the tags inside it; a name already in use merges them.
const { state, client, refresh, toast, tags } = useNoteit();
const open = computed({
  get: () => !!state.tagRename,
  set: (v) => {
    if (!v) state.tagRename = undefined;
  },
});
const name = ref('');
const busy = ref(false);
watch(
  () => state.tagRename,
  (t) => t && (name.value = t),
);
const target = computed(() => name.value.trim().replace(/^#/, ''));
const problem = computed(() => (state.tagRename && target.value ? tagRenameProblem(state.tagRename, target.value, tags.value.map((t) => t.tag)) : undefined));
const merges = computed(() => !!target.value && target.value.toLowerCase() !== state.tagRename && tags.value.some((t) => t.tag === target.value.toLowerCase()));

async function submit(): Promise<void> {
  const from = state.tagRename;
  if (!from || !target.value || problem.value) return;
  busy.value = true;
  try {
    const r = await client().editTag({ type: 'rename', from, to: target.value });
    const v = state.view;
    if (v.kind === 'tag' && (v.tag === from || v.tag.startsWith(`${from}/`))) state.view = { kind: 'tag', tag: (target.value + v.tag.slice(from.length)).toLowerCase() };
    await refresh();
    open.value = false;
    toast(`Renamed in ${r.changed} note${r.changed === 1 ? '' : 's'}${r.skipped ? ` (${r.skipped} can't be edited here)` : ''}`, 'success');
  } catch (e) {
    toast(e instanceof Error ? e.message : String(e), 'error');
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <UModal v-model:open="open" :title="`Rename #${state.tagRename ?? ''}`" :ui="{ content: 'sm:max-w-[420px]', footer: 'justify-end gap-2' }">
    <template #body>
      <form id="tag-rename-form" @submit.prevent="submit">
        <UFormField label="New name" :error="problem" :help="merges ? `#${target} is already in use: the two tags are merged.` : 'Tags inside it are renamed too.'">
          <UInput v-model="name" autofocus spellcheck="false" autocapitalize="none" class="w-full">
            <template #leading><span class="text-muted">#</span></template>
          </UInput>
        </UFormField>
      </form>
    </template>
    <template #footer>
      <UButton color="neutral" variant="soft" label="Cancel" @click="open = false" />
      <UButton type="submit" form="tag-rename-form" :loading="busy" :disabled="!target || !!problem" :label="merges ? 'Merge' : 'Rename'" />
    </template>
  </UModal>
</template>
