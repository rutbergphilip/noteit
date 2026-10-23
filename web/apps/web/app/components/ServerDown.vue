<script setup lang="ts">
import { ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';

const { boot } = useNoteit();
const retrying = ref(false);
async function retry(): Promise<void> {
  retrying.value = true;
  await boot();
  retrying.value = false;
}
</script>

<template>
  <div class="grid min-h-dvh place-items-center bg-(--page) p-4">
    <UCard class="max-w-[420px] rounded-(--radius-2xl) shadow-(--shadow-card) ring-0" :ui="{ body: 'flex flex-col gap-3 p-8 sm:p-8' }">
      <UIcon name="i-lucide-cloud-off" class="size-7" />
      <h1 class="text-[22px] font-bold">Can't Reach the Server</h1>
      <p class="text-muted">NoteIt couldn't talk to this server. Check your connection, then try again.</p>
      <UButton size="lg" class="self-start" :loading="retrying" label="Try Again" @click="retry" />
    </UCard>
  </div>
</template>
