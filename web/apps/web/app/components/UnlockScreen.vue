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
  <div class="page">
    <div class="brand">
      <img src="/noteit-icon.png" alt="" width="32" height="32" />
      <span class="ni-wordmark">Note<span>It</span></span>
    </div>
    <div class="card">
      <span class="badge"><NiIcon name="lock" :size="24" color="var(--acc)" /></span>
      <template v-if="creating">
        <div>
          <h1>Encrypt Your Notes</h1>
          <p>Choose the passphrase that encrypts your library. It never leaves this browser; the server only ever sees encrypted notes.</p>
        </div>
        <CreateStoreForm />
      </template>
      <form v-else @submit.prevent="submit">
        <div>
          <h1>Unlock Your Notes</h1>
          <p>Enter your encryption passphrase. It never leaves this browser, and the server only ever sees encrypted notes.</p>
        </div>
        <PassphraseField v-model="passphrase" label="Passphrase" autocomplete="current-password" autofocus />
        <div v-if="error" class="ni-alert error" role="alert">{{ error }}</div>
        <button class="ni-btn" type="submit" :disabled="busy || !passphrase">{{ busy ? 'Unlocking…' : 'Unlock' }}</button>
        <p class="fine">NoteIt stays unlocked until you close this tab or lock it from the menu.</p>
        <div class="ni-alert warn">
          <NiIcon name="alert" />
          <span>Lost passphrases can't be recovered, not even by your server admin. Keep a copy in your password manager.</span>
        </div>
      </form>
    </div>
    <p class="foot">
      Signed in as <strong>{{ state.session?.user.username }}</strong> · <a href="#" @click.prevent="signOut()">Sign Out</a>
    </p>
  </div>
</template>

<style scoped>
.page {
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 24px;
  padding: 48px 16px;
  background: var(--page);
}
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 20px;
}
.card {
  width: 100%;
  max-width: 440px;
  background: var(--bg);
  border-radius: var(--radius-2xl);
  box-shadow: var(--shadow-card);
  padding: clamp(20px, 5vw, 32px);
  display: flex;
  flex-direction: column;
  gap: 18px;
}
.card form {
  display: flex;
  flex-direction: column;
  gap: 18px;
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
  font-size: 24px;
  font-weight: 700;
}
p {
  margin: 8px 0 0;
  font-size: 15px;
  line-height: 1.5;
  color: var(--ink2);
}
.fine {
  margin: 0;
  font-size: 13px;
}
.foot {
  margin: 0;
  font-size: 13px;
  color: var(--ink2);
}
.foot strong {
  color: var(--ink);
}
</style>
