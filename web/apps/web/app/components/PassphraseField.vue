<script setup lang="ts">
import { ref } from 'vue';
import { PASSPHRASE_HINT } from '@noteit/doc';

defineProps<{ label: string; autocomplete: string; autofocus?: boolean; name?: string }>();
const model = defineModel<string>({ required: true });
const shown = ref(false);
</script>

<template>
  <UFormField :label="label" :name="name" :help="PASSPHRASE_HINT">
    <UInput
      v-model="model"
      size="xl"
      :type="shown ? 'text' : 'password'"
      :autocomplete="autocomplete"
      :autofocus="autofocus"
      spellcheck="false"
      autocapitalize="none"
      :ui="{ trailing: 'pe-1' }"
    >
      <template #trailing>
        <UTooltip :text="shown ? 'Hide passphrase' : 'Show passphrase'">
          <UButton
            color="neutral"
            variant="ghost"
            size="sm"
            :icon="shown ? 'i-lucide-eye-off' : 'i-lucide-eye'"
            :aria-label="shown ? 'Hide passphrase' : 'Show passphrase'"
            :aria-pressed="shown"
            @click="shown = !shown"
          />
        </UTooltip>
      </template>
    </UInput>
  </UFormField>
</template>
