<script setup lang="ts">
import { computed } from 'vue';
import { ICONS } from '~/utils/icons';

const props = withDefaults(defineProps<{ name: string; size?: number; stroke?: number; color?: string }>(), { size: 18, stroke: 1.8, color: 'currentColor' });
// Icon bodies are compile-time constants from utils/icons.ts, never synced data.
const body = computed(() => ICONS[props.name] ?? ICONS.folder!);
</script>

<template>
  <svg
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    fill="none"
    :stroke="color"
    :stroke-width="stroke"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
    focusable="false"
    v-html="body"
  />
</template>
