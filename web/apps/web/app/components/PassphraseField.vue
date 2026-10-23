<script setup lang="ts">
import { ref } from 'vue';
import { PASSPHRASE_HINT } from '@noteit/doc';

defineProps<{ label: string; autocomplete: string; autofocus?: boolean }>();
const model = defineModel<string>({ required: true });
const shown = ref(false);
</script>

<template>
  <label class="ni-field">
    {{ label }}
    <span class="pp">
      <input v-model="model" :type="shown ? 'text' : 'password'" :autocomplete="autocomplete" :autofocus="autofocus" spellcheck="false" autocapitalize="none" required />
      <button type="button" :aria-label="shown ? 'Hide passphrase' : 'Show passphrase'" @click="shown = !shown">
        <NiIcon :name="shown ? 'eyeOff' : 'eye'" />
      </button>
    </span>
    <span class="ni-hint">{{ PASSPHRASE_HINT }}</span>
  </label>
</template>

<style scoped>
.pp {
  display: flex;
  align-items: center;
  height: 46px;
  border: 1.5px solid var(--line-strong);
  border-radius: 11px;
  padding: 0 6px 0 14px;
  background: var(--bg);
}
.pp:focus-within {
  border-color: var(--acc);
}
.pp input {
  flex: 1;
  min-width: 0;
  border: 0;
  outline: none;
  background: transparent;
  font-size: 16px;
  color: var(--ink);
  height: auto;
  padding: 0;
}
.pp button {
  width: 36px;
  height: 36px;
  display: grid;
  place-items: center;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: var(--ink2);
  cursor: pointer;
}
</style>
