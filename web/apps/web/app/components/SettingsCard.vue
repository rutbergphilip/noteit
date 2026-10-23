<script setup lang="ts">
defineProps<{ title?: string; sub?: string }>();
</script>

<template>
  <section class="rounded-xl bg-default px-5 py-3 ring ring-default">
    <h3 v-if="title" class="pt-2 font-semibold">{{ title }}</h3>
    <p v-if="sub || $slots.sub" class="mt-1 text-sm/normal text-muted">
      <slot name="sub">{{ sub }}</slot>
    </p>
    <div class="flex flex-col divide-y divide-default">
      <slot />
    </div>
  </section>
</template>
