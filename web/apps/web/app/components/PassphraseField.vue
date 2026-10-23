<script setup lang="ts">
import { ref, useTemplateRef } from 'vue';
import { PASSPHRASE_HINT } from '@noteit/doc';
import { useFocusWhenShown } from '~/utils/focus';

const props = withDefaults(defineProps<{ label: string; autocomplete: string; autofocus?: boolean; name?: string; hint?: boolean }>(), { hint: true });
const model = defineModel<string>({ required: true });
const shown = ref(false);
useFocusWhenShown(useTemplateRef<HTMLElement>('field'), () => props.autofocus);
</script>

<template>
  <UFormField :label="label" :name="name" :help="hint ? PASSPHRASE_HINT : undefined">
    <div ref="field">
    <UInput
      v-model="model"
      size="xl"
      :type="shown ? 'text' : 'password'"
      :autocomplete="autocomplete"
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
    </div>
  </UFormField>
</template>
