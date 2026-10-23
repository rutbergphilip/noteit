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
  <div class="page">
    <div class="card" role="status">
      <span class="badge"><NiIcon name="devices" :size="24" color="var(--acc)" /></span>
      <h1>Open NoteIt on your Mac once to finish setting up web access</h1>
      <p>
        Your passphrase is right, but this library still stores notes in the Mac's older format, which a browser can't read. The next time NoteIt on your Mac syncs, it upgrades the library automatically
        (it checks first that every device can read the new format). Nothing is lost and nothing changes for your Mac.
      </p>
      <p>This page checks again every minute and continues on its own.</p>
      <div class="row">
        <button class="ni-btn" type="button" :disabled="checking" @click="recheck">{{ checking ? 'Checking…' : 'Check Again' }}</button>
        <button class="ni-btn ghost" type="button" @click="signOut()">Sign Out</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.page {
  min-height: 100vh;
  display: grid;
  place-items: center;
  padding: 48px 16px;
  background: var(--page);
}
.card {
  max-width: 520px;
  background: var(--bg);
  border-radius: var(--radius-2xl);
  box-shadow: var(--shadow-card);
  padding: clamp(20px, 5vw, 32px);
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.badge {
  width: 52px;
  height: 52px;
  border-radius: 15px;
  background: var(--sel);
  display: grid;
  place-items: center;
}
h1 {
  margin: 0;
  font-size: 22px;
  line-height: 1.25;
}
p {
  margin: 0;
  color: var(--ink2);
  line-height: 1.5;
  font-size: 15px;
}
.row {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}
</style>
