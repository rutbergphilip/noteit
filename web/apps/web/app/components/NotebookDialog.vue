<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';
import { NOTEBOOK_COLORS, NOTEBOOK_SYMBOLS, safeHex, SYMBOL_ICONS } from '~/utils/icons';

const { state, client, refresh, toast, descendants } = useNoteit();
const mode = state.notebookDialog!;
const existing = mode.mode === 'edit' ? state.notebooks.find((n) => n.id === mode.id) : undefined;
const name = ref(existing?.name ?? '');
const color = ref(existing?.colorHex?.toUpperCase() ?? NOTEBOOK_COLORS[0]!.hex);
const symbol = ref(existing?.symbol ?? 'tray');
const parent = ref(mode.mode === 'create' ? (mode.parent ?? '') : (existing?.parent ?? ''));
const nameInput = ref<HTMLInputElement>();
onMounted(() => nameInput.value?.focus());

const parentChoices = computed(() => {
  const banned = existing ? new Set([existing.id, ...descendants(existing.id)]) : new Set<string>();
  return state.notebooks.filter((n) => !banned.has(n.id));
});

const close = () => (state.notebookDialog = undefined);

async function submit(): Promise<void> {
  const trimmed = name.value.trim();
  if (!trimmed) return;
  if (existing) await client().updateNotebook(existing.id, { name: trimmed, colorHex: color.value, symbol: symbol.value });
  else {
    const id = await client().createNotebook({ name: trimmed, colorHex: color.value, symbol: symbol.value, ...(parent.value ? { parent: parent.value } : {}) });
    state.view = { kind: 'notebook', id };
  }
  await refresh();
  close();
}

async function remove(): Promise<void> {
  if (!existing) return;
  if (!confirm(`Delete “${existing.name}”? Its notes move to Recently Deleted.`)) return;
  await client().deleteNotebook(existing.id);
  state.view = { kind: 'all' };
  await refresh();
  close();
  toast('Notebook deleted');
}
</script>

<template>
  <!-- design p05 -->
  <div class="ni-scrim" @click="close" />
  <form class="ni-dialog nb" role="dialog" aria-modal="true" aria-labelledby="nbh" @submit.prevent="submit" @keydown.esc="close">
    <h2 id="nbh">{{ existing ? 'Edit Notebook' : 'New Notebook' }}</h2>
    <div class="name-row">
      <span class="preview" :style="{ background: `color-mix(in srgb, ${safeHex(color)} 16%, transparent)` }">
        <NiIcon :name="SYMBOL_ICONS[symbol] ?? 'folder'" :size="22" :color="safeHex(color)" />
      </span>
      <label class="ni-field grow">Name<input ref="nameInput" v-model="name" maxlength="100" required /></label>
    </div>
    <fieldset>
      <legend>Color</legend>
      <div class="swatches">
        <button
          v-for="c in NOTEBOOK_COLORS"
          :key="c.hex"
          type="button"
          class="sw"
          :aria-label="c.hex === color ? `${c.label}, selected` : c.label"
          :aria-pressed="c.hex === color"
          :style="{ background: c.hex }"
          @click="color = c.hex"
        />
      </div>
    </fieldset>
    <fieldset>
      <legend>Icon</legend>
      <div class="icons">
        <button
          v-for="s in NOTEBOOK_SYMBOLS"
          :key="s.symbol"
          type="button"
          class="ic"
          :aria-label="s.symbol === symbol ? `${s.label}, selected` : s.label"
          :aria-pressed="s.symbol === symbol"
          @click="symbol = s.symbol"
        >
          <NiIcon :name="SYMBOL_ICONS[s.symbol]!" :size="20" :color="s.symbol === symbol ? safeHex(color) : 'currentColor'" />
        </button>
      </div>
    </fieldset>
    <label v-if="!existing" class="ni-field">Inside
      <select v-model="parent">
        <option value="">Top level</option>
        <option v-for="nb in parentChoices" :key="nb.id" :value="nb.id">{{ nb.name }}</option>
      </select>
    </label>
    <div class="actions">
      <button v-if="existing" type="button" class="ni-btn ghost small danger-text" @click="remove">Delete</button>
      <button type="button" class="ni-btn secondary small" @click="close">Cancel</button>
      <button type="submit" class="ni-btn small" :disabled="!name.trim()">{{ existing ? 'Save' : 'Create Notebook' }}</button>
    </div>
  </form>
</template>

<style scoped>
.nb {
  top: 110px;
  padding: 24px;
  display: flex;
  flex-direction: column;
  gap: 18px;
}
h2 {
  margin: 0;
  font-size: 20px;
}
.name-row {
  display: flex;
  align-items: flex-end;
  gap: 12px;
}
.grow {
  flex: 1;
}
.preview {
  width: 44px;
  height: 44px;
  border-radius: 12px;
  display: grid;
  place-items: center;
  flex: none;
}
fieldset {
  border: 0;
  margin: 0;
  padding: 0;
}
legend {
  font-size: 13px;
  font-weight: 500;
  color: var(--ink2);
  margin-bottom: 8px;
}
.swatches {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
}
.sw {
  width: 28px;
  height: 28px;
  border-radius: 50%;
  border: 0;
  cursor: pointer;
  padding: 0;
}
.sw[aria-pressed='true'] {
  box-shadow: 0 0 0 2px var(--bg), 0 0 0 4px var(--ink);
}
.icons {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(40px, 1fr));
  gap: 8px;
}
.ic {
  width: 40px;
  height: 40px;
  border: 0;
  border-radius: 10px;
  background: var(--fill);
  display: grid;
  place-items: center;
  cursor: pointer;
  color: var(--ink2);
}
.ic[aria-pressed='true'] {
  background: var(--sel);
  box-shadow: inset 0 0 0 2px var(--acc);
}
.actions {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
}
.danger-text {
  color: var(--danger);
  margin-right: auto;
}
</style>
