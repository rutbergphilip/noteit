<script setup lang="ts">
import { ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';
import { useConfirm } from '~/lib/confirm';

/**
 * Unlock in direct mode (spec §6.4): one passphrase opens this browser's vault (the bucket key) and then the store.
 * After a passphrase change on another device the two differ; both recovery paths reseal the vault under the current
 * passphrase, and neither writes to the bucket.
 */
const { state, unlock, signOut } = useNoteit();
const confirmDialog = useConfirm();

type Mode = 'unlock' | 'current' | 'changed';
const mode = ref<Mode>('unlock');
const passphrase = ref('');
const previous = ref('');
const current = ref('');
/** The passphrase that opened the vault, kept in this tab only while asking for the current one. */
let vaultPassphrase = '';
const error = ref(state.status.detail && state.status.phase === 'locked' ? state.status.detail : '');
const busy = ref(false);

const messages: Record<string, string> = {
  wrongPassphrase: 'Wrong passphrase',
  wrongPreviousPassphrase: 'Wrong previous passphrase',
  unsupportedFormat: 'This library was made by a newer NoteIt. Use a newer copy of NoteIt web.',
  unsupportedFeature: 'This library uses a feature this version of NoteIt web does not support yet.',
  invalidManifest: "This library's settings file is damaged.",
  network: "Can't reach the bucket, and this browser has no offline copy yet.",
  unauthorized: 'The bucket refused the access key. If you replaced the key, set up this browser again.',
  clockSkew: "This device's clock is too far off for the bucket. Set the clock automatically and try again.",
  rekeyInProgress: 'Another device is changing the encryption key. Try again in a few minutes.',
};

function go(next: Mode): void {
  mode.value = next;
  error.value = '';
  previous.value = current.value = '';
}

async function attempt(pass: string, vault?: string): Promise<void> {
  error.value = '';
  busy.value = true;
  const result = await unlock(pass, false, true, vault);
  busy.value = false;
  if (result.status !== 'error') {
    passphrase.value = previous.value = current.value = vaultPassphrase = '';
    return;
  }
  if (result.kind === 'passphraseChanged') {
    vaultPassphrase = pass;
    mode.value = 'current';
    current.value = '';
    return;
  }
  error.value = messages[result.kind] ?? result.message;
}

const submit = () => {
  if (mode.value === 'unlock' && passphrase.value) void attempt(passphrase.value);
  else if (mode.value === 'current' && current.value) void attempt(current.value, vaultPassphrase);
  else if (mode.value === 'changed' && previous.value && current.value) void attempt(current.value, previous.value);
};

async function setUpAgain(): Promise<void> {
  // The old vault is replaced only when the new setup succeeds.
  state.phase = 'connectDirect';
}

async function forget(): Promise<void> {
  const ok = await confirmDialog({
    title: 'Forget this browser?',
    description: 'Deletes the bucket key and the encrypted copy of your notes from this browser. Notes in the bucket are kept.',
    confirmLabel: 'Forget',
    danger: true,
  });
  if (ok) await signOut(true);
}
</script>

<template>
  <div class="flex min-h-dvh flex-col items-center justify-center gap-6 bg-(--page) px-4 py-12">
    <div class="flex items-center gap-2.5 text-xl">
      <img src="/noteit-icon.png" alt="" width="32" height="32" />
      <span class="ni-wordmark">Note<span>It</span></span>
    </div>
    <UCard class="w-full max-w-[440px] rounded-(--radius-2xl) shadow-(--shadow-card) ring-0" :ui="{ body: 'flex flex-col gap-5 p-[clamp(20px,5vw,32px)] sm:p-[clamp(20px,5vw,32px)]' }">
      <span class="grid size-13 place-items-center rounded-[15px] bg-(--sel)"><UIcon name="i-lucide-lock" class="size-6 text-primary" /></span>
      <form class="flex flex-col gap-5" @submit.prevent="submit">
        <template v-if="mode === 'unlock'">
          <div>
            <h1 class="text-2xl font-bold">Unlock Your Notes</h1>
            <p class="mt-2 text-[15px]/normal text-muted">Enter your sync passphrase. It opens the bucket key kept in this browser, then your notes.</p>
          </div>
          <PassphraseField v-model="passphrase" label="Passphrase" autocomplete="current-password" autofocus />
        </template>
        <template v-else-if="mode === 'current'">
          <div>
            <h1 class="text-2xl font-bold">Enter the Current Passphrase</h1>
            <p class="mt-2 text-[15px]/normal text-muted">Your sync passphrase was changed on another device. Enter the current one.</p>
          </div>
          <PassphraseField v-model="current" label="Current passphrase" autocomplete="current-password" autofocus />
        </template>
        <template v-else>
          <div>
            <h1 class="text-2xl font-bold">Passphrase Changed?</h1>
            <p class="mt-2 text-[15px]/normal text-muted">This browser still knows the previous passphrase. Enter it to open the bucket key, and the current one to open your notes.</p>
          </div>
          <PassphraseField v-model="previous" label="Previous passphrase" autocomplete="off" autofocus :hint="false" />
          <PassphraseField v-model="current" label="Current passphrase" autocomplete="current-password" />
        </template>
        <UAlert v-if="error" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="error" />
        <UButton type="submit" size="xl" block :loading="busy" :label="busy ? 'Unlocking…' : 'Unlock'" />
        <div class="flex flex-wrap gap-x-4 gap-y-1">
          <UButton v-if="mode === 'unlock' && error === 'Wrong passphrase'" variant="link" class="p-0" label="Passphrase changed on another device?" @click="go('changed')" />
          <UButton v-if="mode !== 'unlock'" variant="link" class="p-0" label="Back" @click="go('unlock')" />
          <UButton v-if="mode !== 'unlock'" variant="link" class="p-0" label="Set up again" @click="setUpAgain" />
        </div>
        <p class="text-[13px] text-muted">NoteIt stays unlocked in this tab until you lock it. Reloading or closing the tab locks it again.</p>
      </form>
    </UCard>
    <p class="text-[13px] text-muted">
      Syncs straight to your bucket ·
      <UButton variant="link" class="p-0 text-[13px]" label="Forget This Browser" @click="forget" />
    </p>
  </div>
</template>
