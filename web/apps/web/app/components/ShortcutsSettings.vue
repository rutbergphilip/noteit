<script setup lang="ts">
// Settings › Shortcuts › In NoteIt (native ShortcutsSettingsView / MenuShortcutRecorder). Kept in this browser only,
// as native keeps them on each Mac.
import { computed, onBeforeUnmount, ref } from 'vue';
import {
  MENU_SHORTCUT_COMMANDS,
  clearShortcut,
  comboFromEvent,
  comboKbdList,
  comboLabel,
  currentCombos,
  evaluateShortcut,
  hasCustomizations,
  isCustomized,
  menuOverrides,
  resetAllShortcuts,
  resetBlocker,
  resetShortcut,
  setShortcut,
} from '~/utils/menuShortcuts';

const recording = ref<string>();
/** A rejection, or a heads-up about the shortcut just set, shown under its row. */
const message = ref<{ id: string; text: string; tone: 'error' | 'warning'; combo?: string }>();
const shake = ref<string>();

const rows = computed(() => {
  void menuOverrides.value;
  return MENU_SHORTCUT_COMMANDS.map((c) => {
    const combos = currentCombos(c.id);
    const blocker = resetBlocker(c.id);
    const def = c.defaults[0];
    const visible = message.value?.id === c.id && (!message.value.combo || combos[0] === message.value.combo) ? message.value : undefined;
    return {
      ...c,
      combo: combos[0],
      alternative: combos[1],
      customized: isCustomized(c.id),
      resetHelp: !def ? 'Remove the shortcut' : blocker ? `${comboLabel(def)} is used for “${blocker.title}”.` : `Restore ${comboLabel(def)}`,
      blocked: !!blocker,
      message: visible,
    };
  });
});
const anyCustom = computed(() => hasCustomizations(menuOverrides.value));

function start(id: string): void {
  message.value = undefined;
  recording.value = recording.value === id ? undefined : id;
}
function stop(): void {
  recording.value = undefined;
}

function reject(id: string, text: string): void {
  message.value = { id, text, tone: 'error' };
  shake.value = id;
  setTimeout(() => shake.value === id && (shake.value = undefined), 300);
}

function onKeydown(e: KeyboardEvent, id: string): void {
  if (recording.value !== id) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      start(id);
    } else if ((e.key === 'Backspace' || e.key === 'Delete') && currentCombos(id).length) {
      e.preventDefault();
      clearShortcut(id);
    }
    return;
  }
  // While recording, every key is the shortcut: nothing else (the app's shortcuts, Esc closing Settings) sees it.
  e.preventDefault();
  e.stopPropagation();
  if (['Shift', 'Control', 'Alt', 'Meta', 'CapsLock', 'Fn'].includes(e.key)) return;
  const plain = !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey;
  if (plain && e.code === 'Escape') return stop();
  if (plain && (e.code === 'Backspace' || e.code === 'Delete')) {
    clearShortcut(id);
    return stop();
  }
  const combo = comboFromEvent(e);
  if (!combo) return reject(id, "That key can't be used in a shortcut.");
  const verdict = evaluateShortcut(combo, id);
  if (!verdict.accept) return reject(id, verdict.message);
  stop();
  setShortcut(id, combo);
  if (verdict.warning) message.value = { id, text: verdict.warning, tone: 'warning', combo: currentCombos(id)[0] };
}

const onWindowDown = (e: MouseEvent) => {
  if (recording.value && !(e.target as HTMLElement | null)?.closest?.('[data-recorder]')) stop();
};
window.addEventListener('mousedown', onWindowDown, true);
onBeforeUnmount(() => window.removeEventListener('mousedown', onWindowDown, true));
</script>

<template>
  <SettingsCard title="In NoteIt" sub="Menu shortcuts work while NoteIt is open in this tab. They're kept in this browser, as the Mac keeps its own.">
    <div v-for="r in rows" :key="r.id" class="flex flex-col gap-1 py-2.5">
      <div class="flex items-center gap-2">
        <span class="min-w-0 flex-1 text-sm">{{ r.title }}</span>
        <UTooltip v-if="r.customized" :text="r.resetHelp">
          <UButton
            color="neutral"
            variant="ghost"
            size="xs"
            icon="i-lucide-undo-2"
            class="text-muted"
            :disabled="r.blocked"
            :aria-label="`Restore default shortcut for ${r.title}`"
            @click="resetShortcut(r.id)"
          />
        </UTooltip>
        <button
          type="button"
          data-recorder
          class="flex h-7 min-w-32 items-center justify-center gap-1 rounded-md px-2 text-xs ring transition-colors"
          :class="[recording === r.id ? 'bg-(--sel) ring-(--acct)' : 'bg-(--fill) ring-default hover:ring-accented', shake === r.id && 'ni-shake']"
          :aria-label="`${r.title} shortcut`"
          :aria-description="recording === r.id ? 'Type the new shortcut. Esc cancels, Delete removes it.' : r.combo ? comboLabel(r.combo) : 'None'"
          :aria-pressed="recording === r.id"
          @click="start(r.id)"
          @keydown="onKeydown($event, r.id)"
          @blur="recording === r.id && stop()"
        >
          <span v-if="recording === r.id" class="text-muted">Type shortcut…</span>
          <template v-else-if="r.combo">
            <UKbd v-for="(k, i) in comboKbdList(r.combo)" :key="i" :value="k" size="sm" />
            <span v-if="r.alternative" class="ms-1 text-muted" :title="`Also ${comboLabel(r.alternative)}, where the browser keeps the first`">+1</span>
          </template>
          <span v-else class="text-muted">None</span>
        </button>
      </div>
      <p v-if="r.message" class="self-end text-xs" :class="r.message.tone === 'error' ? 'text-error' : 'text-warning'" role="status">{{ r.message.text }}</p>
    </div>
    <div class="flex items-center gap-3 py-3">
      <p class="flex-1 text-xs/normal text-muted">Click a shortcut and type the new one. Esc cancels; Delete leaves the command without a shortcut.</p>
      <UButton v-if="anyCustom" color="neutral" variant="outline" size="sm" label="Restore Defaults" @click="(resetAllShortcuts(), (message = undefined))" />
    </div>
  </SettingsCard>
</template>

<style scoped>
.ni-shake {
  animation: ni-shake 0.3s linear;
}
@keyframes ni-shake {
  20%,
  60% {
    transform: translateX(-4px);
  }
  40%,
  80% {
    transform: translateX(4px);
  }
}
</style>
