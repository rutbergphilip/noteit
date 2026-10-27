<script setup lang="ts">
import { useNoteit } from '~/composables/useNoteit';

const { state } = useNoteit();
</script>

<template>
  <div class="grid min-h-dvh place-items-center bg-(--page) p-4">
    <UCard class="max-w-[460px] rounded-(--radius-2xl) shadow-(--shadow-card) ring-0" :ui="{ body: 'flex flex-col gap-3 p-8 sm:p-8' }">
      <UIcon name="i-lucide-file-warning" class="size-7" />
      <h1 class="text-[22px] font-bold">NoteIt Isn't Set Up Right</h1>
      <p class="text-muted">This copy of NoteIt can't start, because its configuration file isn't right. Whoever hosts it needs to fix it.</p>
      <p class="text-sm text-muted"><code>{{ state.configError }}</code></p>
      <p class="text-sm text-muted">
        It must contain <code>{"mode": "direct"}</code> for a static copy (see the self-hosting guide).
      </p>
    </UCard>
  </div>
</template>
