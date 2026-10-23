<script setup lang="ts">
import { ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';

const props = defineProps<{ stay?: boolean }>();
const emit = defineEmits<{ done: [] }>();
const { unlock } = useNoteit();
const passphrase = ref('');
const confirm = ref('');
const error = ref('');
const busy = ref(false);

async function submit(): Promise<void> {
  error.value = '';
  if (passphrase.value.length < 8) {
    error.value = 'Use at least 8 characters. A few random words work well.';
    return;
  }
  if (passphrase.value !== confirm.value) {
    error.value = "The passphrases don't match.";
    return;
  }
  busy.value = true;
  const result = await unlock(passphrase.value, true, !props.stay);
  busy.value = false;
  if (result.status === 'ok') {
    passphrase.value = confirm.value = '';
    emit('done');
  } else if (result.status === 'error') error.value = result.message;
}
</script>

<template>
  <form class="create" @submit.prevent="submit">
    <PassphraseField v-model="passphrase" label="Encryption passphrase" autocomplete="new-password" autofocus />
    <PassphraseField v-model="confirm" label="Type it again" autocomplete="new-password" />
    <div v-if="error" class="ni-alert error" role="alert">{{ error }}</div>
    <div class="ni-alert warn">
      <NiIcon name="alert" />
      <span>Lost passphrases can't be recovered, not even by your server admin. Keep a copy in your password manager. Use the same passphrase on your Mac.</span>
    </div>
    <button class="ni-btn" type="submit" :disabled="busy">{{ busy ? 'Creating…' : 'Create Encrypted Library' }}</button>
  </form>
</template>

<style scoped>
.create {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
</style>
