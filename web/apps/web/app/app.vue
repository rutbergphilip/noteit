<script setup lang="ts">
import { onBeforeUnmount, onMounted, watchEffect } from 'vue';
import { useNoteit } from '~/composables/useNoteit';

const { state, boot, client, createNote } = useNoteit();

let media: MediaQueryList | undefined;
const applyTheme = () => {
  const dark = state.theme === 'dark' || (state.theme === 'system' && !!media?.matches);
  document.documentElement.classList.toggle('dark', dark);
};

function onKey(e: KeyboardEvent): void {
  if (state.phase !== 'ready') return;
  const mod = e.metaKey || e.ctrlKey;
  if (mod && !e.altKey && e.key.toLowerCase() === 'k') {
    e.preventDefault();
    state.palette = !state.palette;
  } else if (mod && e.altKey && (e.code === 'KeyN' || e.key.toLowerCase() === 'n')) {
    e.preventDefault();
    void createNote();
  } else if (mod && e.altKey && (e.code === 'KeyC' || e.key.toLowerCase() === 'c')) {
    e.preventDefault();
    state.capture = true;
  } else if (e.key === 'Escape') {
    state.palette = false;
    state.drawerOpen = false;
  }
}

const onVisibility = () => {
  if (state.phase === 'ready') void client().setVisible(document.visibilityState === 'visible');
};
const onOnline = () => {
  if (state.phase === 'ready') void client().syncNow();
};

onMounted(() => {
  media = window.matchMedia('(prefers-color-scheme: dark)');
  media.addEventListener('change', applyTheme);
  window.addEventListener('keydown', onKey);
  document.addEventListener('visibilitychange', onVisibility);
  window.addEventListener('online', onOnline);
  window.addEventListener('focus', onOnline);
  void boot();
});
onBeforeUnmount(() => {
  media?.removeEventListener('change', applyTheme);
  window.removeEventListener('keydown', onKey);
  document.removeEventListener('visibilitychange', onVisibility);
  window.removeEventListener('online', onOnline);
  window.removeEventListener('focus', onOnline);
});
watchEffect(() => {
  void state.theme;
  if (import.meta.client) applyTheme();
});
</script>

<template>
  <div class="ni-root">
    <div v-if="state.phase === 'loading'" class="ni-boot" aria-busy="true">
      <img src="/noteit-icon.png" alt="" width="44" height="44" />
    </div>
    <ServerDown v-else-if="state.phase === 'serverDown'" />
    <SetupWizard v-else-if="state.phase === 'setup'" />
    <SignIn v-else-if="state.phase === 'signin'" />
    <ChangePassword v-else-if="state.phase === 'changePassword'" />
    <UnlockScreen v-else-if="state.phase === 'unlock' || state.phase === 'createStore'" />
    <LegacyStore v-else-if="state.phase === 'legacy'" />
    <template v-else-if="state.phase === 'ready'">
      <SettingsView v-if="state.settings" />
      <AppShell v-else />
      <CommandPalette v-if="state.palette" />
      <QuickCapture v-if="state.capture" />
      <NotebookDialog v-if="state.notebookDialog" />
    </template>
    <div v-if="state.toast" class="ni-toast" role="status">{{ state.toast }}</div>
  </div>
</template>

<style>
.ni-root {
  min-height: 100vh;
  background: var(--bg);
}
.ni-boot {
  min-height: 100vh;
  display: grid;
  place-items: center;
  background: var(--page);
}
.ni-toast {
  position: fixed;
  left: 50%;
  bottom: 24px;
  transform: translateX(-50%);
  z-index: 60;
  background: var(--ink);
  color: var(--bg);
  padding: 10px 16px;
  border-radius: 12px;
  font-size: 14px;
  box-shadow: var(--shadow-dialog);
  max-width: calc(100% - 32px);
}
</style>
