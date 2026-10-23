<script setup lang="ts">
import { useNoteit } from '~/composables/useNoteit';

const { boot } = useNoteit();
</script>

<template>
  <div class="center">
    <div class="card">
      <NiIcon name="cloudOff" :size="28" />
      <h1>Can't Reach the Server</h1>
      <p>NoteIt couldn't talk to this server. Check your connection, then try again.</p>
      <button class="ni-btn" type="button" @click="boot()">Try Again</button>
    </div>
  </div>
</template>

<style scoped>
.center {
  min-height: 100vh;
  display: grid;
  place-items: center;
  background: var(--page);
  padding: 16px;
}
.card {
  max-width: 420px;
  background: var(--bg);
  border-radius: var(--radius-2xl);
  box-shadow: var(--shadow-card);
  padding: 32px;
  display: flex;
  flex-direction: column;
  gap: 12px;
  color: var(--ink);
}
h1 {
  margin: 0;
  font-size: 22px;
}
p {
  margin: 0;
  color: var(--ink2);
  line-height: 1.5;
}
</style>
