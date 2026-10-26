<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { parseQuery } from '@noteit/doc';
import { useConfirm } from '~/lib/confirm';
import { useNoteit } from '~/composables/useNoteit';
import { useOpeningKey } from '~/utils/overlay';

// Native SmartFolder: a name and a saved search in the sidebar, synced to every device.
const { state, client, refresh, toast, setQuery } = useNoteit();
const confirm = useConfirm();

const open = computed({
  get: () => !!state.smartFolderDialog,
  set: (v) => {
    if (!v) state.smartFolderDialog = undefined;
  },
});
const existing = computed(() => {
  const m = state.smartFolderDialog;
  return m?.mode === 'edit' ? state.smartFolders.find((f) => f.id === m.id) : undefined;
});
const name = ref('');
const query = ref('');
const error = ref('');
const busy = ref(false);
const issues = computed(() => (query.value.trim() ? parseQuery(query.value).issues.map((i) => i.message) : []));

watch(
  () => state.smartFolderDialog,
  (m) => {
    if (!m) return;
    name.value = existing.value?.name ?? '';
    query.value = existing.value?.query ?? (m.mode === 'create' ? (m.query ?? '') : '');
    error.value = '';
  },
  { immediate: true },
);

async function submit(): Promise<void> {
  error.value = '';
  busy.value = true;
  try {
    const f = existing.value;
    if (f) await client().updateSmartFolder(f.id, { name: name.value, query: query.value });
    else {
      const id = await client().createSmartFolder({ name: name.value, query: query.value });
      await refresh();
      state.view = { kind: 'smartFolder', id };
      if (state.query) await setQuery('');
    }
    await refresh();
    open.value = false;
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e);
  } finally {
    busy.value = false;
  }
}

async function remove(): Promise<void> {
  const f = existing.value;
  if (!f) return;
  if (!(await confirm({ title: `Delete “${f.name}”?`, description: 'Only the smart folder is deleted; its notes stay where they are.', confirmLabel: 'Delete Smart Folder', danger: true }))) return;
  await client().deleteSmartFolder(f.id);
  if (state.view.kind === 'smartFolder' && state.view.id === f.id) state.view = { kind: 'all' };
  await refresh();
  open.value = false;
  toast('Smart folder deleted');
}
// A fresh portal per opening, so it shows above the sidebar drawer (see useOpeningKey).
const portalKey = useOpeningKey(() => open.value);
</script>

<template>
  <UModal :key="portalKey" v-model:open="open" :title="existing ? 'Edit Smart Folder' : 'New Smart Folder'" :ui="{ content: 'sm:max-w-[460px]', footer: 'justify-end gap-2' }">
    <template #body>
      <form id="smart-folder-form" class="flex flex-col gap-4" @submit.prevent="submit">
        <UFormField label="Name">
          <UInput v-model="name" size="lg" maxlength="60" autofocus class="w-full" />
        </UFormField>
        <UFormField label="Search" :help="issues[0] ?? 'The same search as the search field: words, tag:, notebook:, is:todo, due:today, OR, -word…'">
          <UInput v-model="query" maxlength="500" spellcheck="false" autocapitalize="none" class="w-full font-mono" />
        </UFormField>
        <UAlert v-if="error" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="error" />
      </form>
    </template>
    <template #footer>
      <UButton v-if="existing" color="error" variant="ghost" class="me-auto" label="Delete" @click="remove" />
      <UButton color="neutral" variant="soft" label="Cancel" @click="open = false" />
      <UButton type="submit" form="smart-folder-form" :loading="busy" :disabled="!name.trim() || !query.trim()" :label="existing ? 'Save' : 'Create Smart Folder'" />
    </template>
  </UModal>
</template>
