<script setup lang="ts">
import { ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';
import { api, ApiError } from '~/utils/api';

const { boot, state } = useNoteit();
const current = ref('');
const next = ref('');
const error = ref('');

async function submit(): Promise<void> {
  error.value = '';
  try {
    await api('/account/password', { method: 'POST', body: { current: current.value, next: next.value } });
    await boot();
  } catch (e) {
    error.value = e instanceof ApiError ? e.message : 'Could not reach the server.';
  }
}
</script>

<template>
  <AuthLayout>
    <form @submit.prevent="submit">
      <div>
        <h1>Choose a New Password</h1>
        <p class="lead">Your admin gave {{ state.session?.user.username }} a temporary password. Pick your own to continue.</p>
      </div>
      <label class="ni-field">Temporary password <input v-model="current" type="password" autocomplete="current-password" required /></label>
      <label class="ni-field">New password <input v-model="next" type="password" autocomplete="new-password" minlength="10" required /><span class="ni-hint">At least 10 characters.</span></label>
      <div v-if="error" class="ni-alert error" role="alert">{{ error }}</div>
      <button class="ni-btn" type="submit">Save Password</button>
    </form>
  </AuthLayout>
</template>
