<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';

const { client, state, signOut, refresh } = useNoteit();
const checking = ref(false);

/** Spec §3.4 item 8: re-check every 60 s (the worker does) and on focus; continue on our own once ready. */
async function recheck(): Promise<void> {
  checking.value = true;
  const result = await client().recheckLegacy();
  checking.value = false;
  if (result?.status === 'ok') {
    state.phase = 'ready';
    await refresh();
  }
}

const onFocus = () => void recheck();
let poll: ReturnType<typeof setInterval> | undefined;
onMounted(() => {
  window.addEventListener('focus', onFocus);
  poll = setInterval(() => {
    if (state.status.phase !== 'legacy') {
      state.phase = 'ready';
      void refresh();
    }
  }, 5000);
});
onBeforeUnmount(() => {
  window.removeEventListener('focus', onFocus);
  if (poll) clearInterval(poll);
});
</script>

<template>
  <div class="grid min-h-dvh place-items-center bg-(--page) px-4 py-12">
    <UCard class="max-w-[520px] rounded-(--radius-2xl) shadow-(--shadow-card) ring-0" :ui="{ body: 'flex flex-col gap-3.5 p-[clamp(20px,5vw,32px)] sm:p-[clamp(20px,5vw,32px)]' }" role="status">
      <span class="grid size-13 place-items-center rounded-[15px] bg-(--sel)"><UIcon name="i-lucide-monitor-smartphone" class="size-6 text-primary" /></span>
      <h1 class="text-[22px]/tight font-bold">Open NoteIt on your Mac once to finish setting up web access</h1>
      <p class="text-[15px]/normal text-muted">
        Your passphrase is right, but this library still stores notes in the Mac's older format, which a browser can't read. The next time NoteIt on your Mac syncs, it upgrades the library automatically
        (it checks first that every device can read the new format). Nothing is lost and nothing changes for your Mac.
      </p>
      <p class="text-[15px]/normal text-muted">This page checks again every minute and continues on its own.</p>
      <div class="flex flex-wrap gap-2">
        <UButton size="lg" :loading="checking" label="Check Again" @click="recheck" />
        <UButton size="lg" color="neutral" variant="ghost" label="Sign Out" @click="signOut()" />
      </div>
    </UCard>
  </div>
</template>
