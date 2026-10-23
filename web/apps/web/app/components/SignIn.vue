<script setup lang="ts">
import { computed, ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';
import { api, ApiError } from '~/utils/api';

const { boot } = useNoteit();
const username = ref('');
const password = ref('');
const error = ref('');
const busy = ref(false);
const inviteToken = ref(new URLSearchParams(location.hash.replace(/^#/, '')).get('invite') ?? '');
const mode = ref<'signin' | 'invite'>(inviteToken.value ? 'invite' : 'signin');
const host = computed(() => location.host);

async function submit(): Promise<void> {
  error.value = '';
  busy.value = true;
  try {
    if (mode.value === 'invite') {
      await api('/invites/redeem', { method: 'POST', body: { token: inviteToken.value.trim(), username: username.value, password: password.value } });
      history.replaceState(null, '', location.pathname);
    } else {
      await api('/login', { method: 'POST', body: { username: username.value, password: password.value } });
    }
    password.value = '';
    await boot();
  } catch (e) {
    error.value = e instanceof ApiError ? e.message : 'Could not reach the server.';
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <AuthLayout>
    <form @submit.prevent="submit">
      <div>
        <h1>{{ mode === 'invite' ? 'Create Your Account' : 'Sign In' }}</h1>
        <p class="lead">
          to <strong>{{ host }}</strong>
        </p>
      </div>
      <label v-if="mode === 'invite'" class="ni-field">Invite code
        <input v-model="inviteToken" autocomplete="off" required />
      </label>
      <label class="ni-field">Username
        <input v-model="username" autocomplete="username" autocapitalize="none" spellcheck="false" required />
      </label>
      <label class="ni-field">Password
        <input v-model="password" type="password" :autocomplete="mode === 'invite' ? 'new-password' : 'current-password'" required :minlength="mode === 'invite' ? 10 : undefined" />
      </label>
      <div v-if="error" class="ni-alert error" role="alert">{{ error }}</div>
      <button class="ni-btn" type="submit" :disabled="busy">{{ mode === 'invite' ? 'Create Account' : 'Sign In' }}</button>
      <p class="fine">Signing in only opens your account. Your notes stay encrypted until you unlock them with your passphrase on the next step.</p>
      <p class="fine">
        <a v-if="mode === 'signin'" href="#" @click.prevent="mode = 'invite'">I have an invite</a>
        <a v-else href="#" @click.prevent="mode = 'signin'">I already have an account</a>
      </p>
    </form>
  </AuthLayout>
</template>
