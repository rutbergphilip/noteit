<script setup lang="ts">
import { computed, ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';

const { state, unlock, signOut } = useNoteit();
const passphrase = ref('');
const error = ref(state.status.detail && state.status.phase === 'locked' ? state.status.detail : '');
const busy = ref(false);
const creating = computed(() => state.phase === 'createStore');

const messages: Record<string, string> = {
  wrongPassphrase: "That passphrase doesn't open this library.",
  unsupportedFormat: 'This library was made by a newer NoteIt. Update this server to open it.',
  unsupportedFeature: 'This library uses a feature this version of NoteIt web does not support yet.',
  invalidManifest: "This library's settings file is damaged.",
  network: "Can't reach the server, and this browser has no offline copy yet.",
  rekeyInProgress: 'Another device is changing the encryption key. Try again in a few minutes.',
};

async function submit(): Promise<void> {
  if (!passphrase.value) return;
  error.value = '';
  busy.value = true;
  const result = await unlock(passphrase.value);
  busy.value = false;
  if (result.status === 'ok') passphrase.value = '';
  else if (result.status === 'error') error.value = messages[result.kind] ?? result.message;
}
</script>

<template>
  <!-- design p07 -->
  <div class="flex min-h-dvh flex-col items-center justify-center gap-6 bg-(--page) px-4 py-12">
    <div class="flex items-center gap-2.5 text-xl">
      <img src="/noteit-icon.png" alt="" width="32" height="32" />
      <span class="ni-wordmark">Note<span>It</span></span>
    </div>
    <UCard class="w-full max-w-[440px] rounded-(--radius-2xl) shadow-(--shadow-card) ring-0" :ui="{ body: 'flex flex-col gap-5 p-[clamp(20px,5vw,32px)] sm:p-[clamp(20px,5vw,32px)]' }">
      <span class="grid size-13 place-items-center rounded-[15px] bg-(--sel)"><UIcon name="i-lucide-lock" class="size-6 text-primary" /></span>
      <template v-if="creating">
        <div>
          <h1 class="text-2xl font-bold">Encrypt Your Notes</h1>
          <p class="mt-2 text-[15px]/normal text-muted">Choose the passphrase that encrypts your library. It never leaves this browser; the server only ever sees encrypted notes.</p>
        </div>
        <CreateStoreForm />
      </template>
      <form v-else class="flex flex-col gap-5" @submit.prevent="submit">
        <div>
          <h1 class="text-2xl font-bold">Unlock Your Notes</h1>
          <p class="mt-2 text-[15px]/normal text-muted">Enter your encryption passphrase. It never leaves this browser, and the server only ever sees encrypted notes.</p>
        </div>
        <PassphraseField v-model="passphrase" label="Passphrase" autocomplete="current-password" autofocus />
        <UAlert v-if="error" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="error" />
        <UButton type="submit" size="xl" block :loading="busy" :disabled="!passphrase" :label="busy ? 'Unlocking…' : 'Unlock'" />
        <p class="text-[13px] text-muted">NoteIt stays unlocked in this tab until you lock it. Reloading or closing the tab locks it again.</p>
        <UAlert color="warning" variant="subtle" icon="i-lucide-triangle-alert" description="Lost passphrases can't be recovered, not even by your server admin. Keep a copy in your password manager." />
      </form>
    </UCard>
    <p class="text-[13px] text-muted">
      Signed in as <strong class="text-default">{{ state.session?.user.username }}</strong> ·
      <UButton variant="link" class="p-0 text-[13px]" label="Sign Out" @click="signOut()" />
    </p>
  </div>
</template>
