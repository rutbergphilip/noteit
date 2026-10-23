<script setup lang="ts">
defineProps<{ label?: string; sub?: string }>();
</script>

<template>
  <div class="flex flex-wrap items-center gap-3 py-3">
    <div class="min-w-0 flex-1">
      <div class="text-sm">
        <slot name="label">{{ label }}</slot>
      </div>
      <div v-if="sub" class="text-xs/normal text-muted">{{ sub }}</div>
    </div>
    <slot />
  </div>
</template>
