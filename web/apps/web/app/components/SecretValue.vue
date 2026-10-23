<script setup lang="ts">
import { ref } from 'vue';

/** A one-time value (secret, temporary password, invite link) with a copy button. */
const props = defineProps<{ value: string; label: string; hint?: string }>();
const copied = ref(false);
async function copy(): Promise<void> {
  await navigator.clipboard.writeText(props.value);
  copied.value = true;
  setTimeout(() => (copied.value = false), 1500);
}
</script>

<template>
  <div class="flex flex-col gap-1">
    <div class="flex items-center gap-2 rounded-md bg-(--code) py-1.5 ps-3 pe-1.5">
      <div class="min-w-0 flex-1">
        <div class="text-[11px] font-semibold text-muted">{{ label }}</div>
        <code class="block font-mono text-[13px] break-all">{{ value }}</code>
      </div>
      <UTooltip :text="copied ? 'Copied' : 'Copy'">
        <UButton color="neutral" variant="ghost" size="sm" :icon="copied ? 'i-lucide-check' : 'i-lucide-copy'" :aria-label="`Copy ${label}`" @click="copy" />
      </UTooltip>
    </div>
    <div v-if="hint" class="text-xs text-muted">{{ hint }}</div>
  </div>
</template>
