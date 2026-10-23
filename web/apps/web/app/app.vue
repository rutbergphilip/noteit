<script setup lang="ts">
import { onBeforeUnmount, onMounted, watch } from 'vue';
import { setNotifier, type Theme, useNoteit } from '~/composables/useNoteit';
import { PALETTE_KEYS, webCommands } from '~/utils/commands';
import { matchesCombo } from '~/utils/shortcuts';
import { startReminders, stopReminders } from '~/utils/reminders';

const { state, boot, client } = useNoteit();

// Toasts: the composable's toast() lands here, in Nuxt UI's toaster.
const toaster = useToast();
const TONES = { info: { color: 'neutral', icon: 'i-lucide-info' }, success: { color: 'success', icon: 'i-lucide-circle-check' }, error: { color: 'error', icon: 'i-lucide-circle-alert' } } as const;
setNotifier(({ title, description, tone = 'info', action }) =>
  toaster.add({
    title,
    description,
    ...TONES[tone],
    duration: action ? 6000 : tone === 'error' ? 6000 : 3500,
    ...(action ? { actions: [{ label: action.label, color: 'neutral', variant: 'outline', size: 'xs', onClick: () => void action.run() }] } : {}),
  }),
);

// Theme: Nuxt UI's color mode owns the <html> class and persistence; the app state mirrors it.
const colorMode = useColorMode();
state.theme = colorMode.preference as Theme;
watch(
  () => state.theme,
  (t) => (colorMode.preference = t),
);

// Global shortcuts: native's menu shortcuts (utils/commands.ts), matched on e.code so ⌥ combinations work on a Mac.
function onKey(e: KeyboardEvent): void {
  if (state.phase !== 'ready' || e.repeat) return;
  if (PALETTE_KEYS.some((k) => matchesCombo(e, k))) {
    e.preventDefault();
    state.palette = !state.palette;
    return;
  }
  const target = e.target as HTMLElement | null;
  const typing = !!target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
  for (const c of webCommands()) {
    if (!c.keys?.some((k) => matchesCombo(e, k))) continue;
    if ((typing && c.inText === false) || !c.available()) return;
    e.preventDefault();
    void c.run();
    return;
  }
}

const onVisibility = () => {
  if (state.phase === 'ready') void client().setVisible(document.visibilityState === 'visible');
};
const onOnline = () => {
  if (state.phase === 'ready') void client().syncNow();
};

// Closing IndexedDB as the page goes away lets a reload open it at once. The open editor saves a pending edit
// first (noteit:flush), so that save is queued in the worker ahead of the close.
// Reminders ring while the library is open (utils/reminders.ts).
watch(
  () => state.phase,
  (phase) => (phase === 'ready' ? startReminders() : stopReminders()),
);

const onPageHide = (e: PageTransitionEvent) => {
  window.dispatchEvent(new Event('noteit:flush'));
  if (state.phase !== 'loading' && !e.persisted) void client().close();
};

onMounted(() => {
  window.addEventListener('pagehide', onPageHide);
  window.addEventListener('keydown', onKey);
  document.addEventListener('visibilitychange', onVisibility);
  window.addEventListener('online', onOnline);
  window.addEventListener('focus', onOnline);
  void boot();
});
onBeforeUnmount(() => {
  window.removeEventListener('pagehide', onPageHide);
  window.removeEventListener('keydown', onKey);
  document.removeEventListener('visibilitychange', onVisibility);
  window.removeEventListener('online', onOnline);
  window.removeEventListener('focus', onOnline);
});
</script>

<template>
  <UApp :toaster="{ position: 'bottom-center', expand: false }" :tooltip="{ delayDuration: 350 }">
    <div class="min-h-dvh bg-default">
      <Transition name="fade" mode="out-in">
        <div v-if="state.phase === 'loading'" key="loading" class="grid min-h-dvh place-items-center bg-(--page)" aria-busy="true">
          <img src="/noteit-icon.png" alt="" width="44" height="44" class="animate-pulse" />
        </div>
        <ServerDown v-else-if="state.phase === 'serverDown'" key="down" />
        <SetupWizard v-else-if="state.phase === 'setup'" key="setup" />
        <SignIn v-else-if="state.phase === 'signin'" key="signin" />
        <ChangePassword v-else-if="state.phase === 'changePassword'" key="password" />
        <UnlockScreen v-else-if="state.phase === 'unlock' || state.phase === 'createStore'" key="unlock" />
        <LegacyStore v-else-if="state.phase === 'legacy'" key="legacy" />
        <AppShell v-else-if="state.phase === 'ready'" key="ready" />
      </Transition>
      <template v-if="state.phase === 'ready'">
        <SettingsView />
        <CommandPalette />
        <QuickCapture />
        <NotebookDialog />
        <SmartFolderDialog />
        <TagRenameDialog />
        <DailyPicker />
        <TemplatePicker />
      </template>
    </div>
  </UApp>
</template>

<style>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 150ms ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}
</style>
