<script setup lang="ts">
import { computed, ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';
import { relativeTime } from '~/utils/api';

const { state, client } = useNoteit();
const open = ref(false);

const view = computed(() => {
  const s = state.status;
  switch (s.phase) {
    case 'syncing':
      return { icon: 'cloud', label: 'Syncing…', tone: '' };
    case 'offline':
      return { icon: 'cloudOff', label: 'Offline', tone: 'warn' };
    case 'error':
      return { icon: 'alert', label: 'Sync Issue', tone: 'error' };
    case 'legacy':
      return { icon: 'alert', label: 'Needs your Mac', tone: 'warn' };
    case 'locked':
      return { icon: 'lock', label: 'Locked', tone: '' };
    default:
      return s.pending > 0 ? { icon: 'cloud', label: `${s.pending} to sync`, tone: '' } : { icon: 'lock', label: 'Synced · encrypted', tone: '' };
  }
});

const failed = computed(() =>
  state.status.recordErrors.map((e) => ({ ...e, title: e.id ? (state.notes.find((n) => n.id === e.id)?.title || 'Untitled') : undefined })),
);

function openNote(id: string): void {
  state.selectedId = id;
  state.pane = 'editor';
  open.value = false;
}
</script>

<template>
  <div class="wrap">
    <button type="button" class="sync-pill" :class="view.tone" role="status" :aria-label="view.label" :aria-expanded="open" @click="open = !open">
      <NiIcon :name="view.icon" :size="14" :stroke="2" />
      <span class="sync-label">{{ view.label }}</span>
    </button>
    <div v-if="open" class="pop" role="dialog" aria-label="Sync details">
      <div class="line"><strong>{{ view.label }}</strong></div>
      <div class="muted">Last synced {{ state.status.lastSync ? relativeTime(state.status.lastSync) : 'not yet' }}. Notes are encrypted in this browser before they're uploaded.</div>
      <div v-if="state.status.detail && state.status.phase !== 'idle'" class="muted">{{ state.status.detail }}</div>
      <template v-if="failed.length">
        <div class="line">{{ failed.length }} {{ failed.length === 1 ? 'item' : 'items' }} will be retried on the next sync</div>
        <ul>
          <li v-for="(f, i) in failed" :key="i">
            <a v-if="f.id" href="#" @click.prevent="openNote(f.id)">{{ f.title }}</a>
            <span class="muted">{{ f.message }}</span>
          </li>
        </ul>
      </template>
      <button class="ni-btn small" type="button" @click="client().syncNow()">Sync Now</button>
    </div>
  </div>
</template>

<style scoped>
.wrap {
  position: relative;
}
.sync-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 30px;
  padding: 0 12px;
  border: 0;
  border-radius: 999px;
  background: var(--fill);
  font-size: 13px;
  color: var(--ink2);
  cursor: pointer;
}
.sync-pill.warn {
  background: var(--warn-bg);
  color: var(--warn-ink);
}
.sync-pill.error {
  background: var(--danger-bg);
  color: var(--danger-ink);
}
.pop {
  position: absolute;
  right: 0;
  top: 38px;
  z-index: 40;
  width: min(320px, calc(100vw - 32px));
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-dialog);
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  font-size: 13px;
}
.muted {
  color: var(--ink2);
  line-height: 1.45;
}
ul {
  margin: 0;
  padding-left: 18px;
}
li {
  display: flex;
  flex-direction: column;
}
</style>
