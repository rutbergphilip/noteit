<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { useConfirm } from '~/lib/confirm';
import { useNoteit } from '~/composables/useNoteit';
import { NOTEBOOK_COLORS, NOTEBOOK_SYMBOLS, notebookIcon, safeHex } from '~/utils/notebooks';

const { state, client, refresh, toast, descendants } = useNoteit();
const confirm = useConfirm();

const open = computed({
  get: () => !!state.notebookDialog,
  set: (v) => {
    if (!v) state.notebookDialog = undefined;
  },
});
const existing = computed(() => {
  const m = state.notebookDialog;
  return m?.mode === 'edit' ? state.notebooks.find((n) => n.id === m.id) : undefined;
});
const name = ref('');
const color = ref(NOTEBOOK_COLORS[0]!.hex);
const symbol = ref('tray');
const TOP = 'top';
const parent = ref(TOP);
const busy = ref(false);

// Fields are filled when the dialog opens, so it can stay mounted and animate.
watch(
  () => state.notebookDialog,
  (m) => {
    if (!m) return;
    const nb = existing.value;
    name.value = nb?.name ?? '';
    color.value = nb?.colorHex?.toUpperCase() ?? NOTEBOOK_COLORS[0]!.hex;
    symbol.value = nb?.symbol ?? 'tray';
    parent.value = (m.mode === 'create' ? m.parent : nb?.parent) ?? TOP;
  },
  { immediate: true },
);

const parentChoices = computed(() => {
  const nb = existing.value;
  const banned = nb ? new Set([nb.id, ...descendants(nb.id)]) : new Set<string>();
  return [{ label: 'Top level', value: TOP, icon: 'i-lucide-library' }, ...state.notebooks.filter((n) => !banned.has(n.id)).map((n) => ({ label: n.name || 'Untitled', value: n.id, icon: notebookIcon(n.symbol) }))];
});

async function submit(): Promise<void> {
  const trimmed = name.value.trim();
  if (!trimmed) return;
  busy.value = true;
  try {
    const nb = existing.value;
    if (nb) await client().updateNotebook(nb.id, { name: trimmed, colorHex: color.value, symbol: symbol.value, parent: parent.value === TOP ? null : parent.value });
    else {
      const id = await client().createNotebook({ name: trimmed, colorHex: color.value, symbol: symbol.value, ...(parent.value !== TOP ? { parent: parent.value } : {}) });
      state.view = { kind: 'notebook', id };
    }
    await refresh();
    open.value = false;
  } finally {
    busy.value = false;
  }
}

async function remove(): Promise<void> {
  const nb = existing.value;
  if (!nb) return;
  const ok = await confirm({ title: `Delete “${nb.name}”?`, description: 'Its notes move to Recently Deleted.', confirmLabel: 'Delete Notebook', danger: true });
  if (!ok) return;
  await client().deleteNotebook(nb.id);
  state.view = { kind: 'all' };
  await refresh();
  open.value = false;
  toast('Notebook deleted');
}
</script>

<template>
  <!-- design p05 -->
  <UModal v-model:open="open" :title="existing ? 'Edit Notebook' : 'New Notebook'" :ui="{ content: 'sm:max-w-[460px]', footer: 'justify-end gap-2' }">
    <template #body>
      <form id="notebook-form" class="flex flex-col gap-5" @submit.prevent="submit">
        <div class="flex items-end gap-3">
          <span class="grid size-11 flex-none place-items-center rounded-xl transition-colors" :style="{ background: `color-mix(in srgb, ${safeHex(color)} 16%, transparent)` }">
            <UIcon :name="notebookIcon(symbol)" class="size-[22px]" :style="{ color: safeHex(color) }" />
          </span>
          <UFormField label="Name" class="flex-1">
            <UInput v-model="name" size="lg" maxlength="100" autofocus />
          </UFormField>
        </div>
        <fieldset>
          <legend class="mb-2 text-[13px] font-medium text-muted">Color</legend>
          <div class="flex flex-wrap gap-2.5">
            <button
              v-for="c in NOTEBOOK_COLORS"
              :key="c.hex"
              type="button"
              class="size-7 cursor-pointer rounded-full transition-shadow focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
              :class="c.hex === color && 'shadow-[0_0_0_2px_var(--bg),0_0_0_4px_var(--ink)]'"
              :aria-label="c.label"
              :aria-pressed="c.hex === color"
              :style="{ background: c.hex }"
              @click="color = c.hex"
            />
          </div>
        </fieldset>
        <fieldset>
          <legend class="mb-2 text-[13px] font-medium text-muted">Icon</legend>
          <div class="grid grid-cols-[repeat(auto-fill,minmax(40px,1fr))] gap-2">
            <UTooltip v-for="s in NOTEBOOK_SYMBOLS" :key="s.symbol" :text="s.label">
              <UButton
                color="neutral"
                variant="soft"
                square
                class="size-10 justify-center rounded-[10px] bg-(--fill)"
                :class="s.symbol === symbol && 'bg-(--sel) ring-2 ring-primary ring-inset'"
                :aria-label="s.label"
                :aria-pressed="s.symbol === symbol"
                @click="symbol = s.symbol"
              >
                <UIcon :name="notebookIcon(s.symbol)" class="size-5" :style="s.symbol === symbol ? { color: safeHex(color) } : {}" />
              </UButton>
            </UTooltip>
          </div>
        </fieldset>
        <UFormField label="Inside" :help="parent === TOP ? 'A top-level notebook in the sidebar.' : `Nested inside ${state.notebooks.find((n) => n.id === parent)?.name || 'Untitled'}.`">
          <USelect v-model="parent" :items="parentChoices" class="w-full" />
        </UFormField>
      </form>
    </template>
    <template #footer>
      <UButton v-if="existing" color="error" variant="ghost" class="me-auto" label="Delete" @click="remove" />
      <UButton color="neutral" variant="soft" label="Cancel" @click="open = false" />
      <UButton type="submit" form="notebook-form" :loading="busy" :disabled="!name.trim()" :label="existing ? 'Save' : 'Create Notebook'" />
    </template>
  </UModal>
</template>
