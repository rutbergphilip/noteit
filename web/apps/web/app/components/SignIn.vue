<script setup lang="ts">
import { computed, ref } from 'vue';
import { redeemInvite, signIn } from '#safe-action/actions';
import { redeemInviteInput, signInInput } from '#shared/schemas';
import { useNoteit } from '~/composables/useNoteit';
import { failureOf } from '~/utils/actions';

const { enter } = useNoteit();
const hashInvite = new URLSearchParams(location.hash.replace(/^#/, '')).get('invite') ?? '';
const mode = ref<'signin' | 'invite'>(hashInvite ? 'invite' : 'signin');
const host = computed(() => location.host);

const login = useFormAction(signIn, {
  initialValues: { username: '', password: '' },
  clientSchema: signInInput,
  onSuccess: ({ data }) => enter(data),
});
const invite = useFormAction(redeemInvite, {
  initialValues: { token: hashInvite, username: '', password: '' },
  clientSchema: redeemInviteInput,
  onSuccess: ({ data }) => {
    history.replaceState(null, '', location.pathname);
    return enter(data);
  },
});
const loginValues = login.values;
const inviteValues = invite.values;
const busy = computed(() => login.isExecuting.value || invite.isExecuting.value);
const error = computed(() => {
  const f = mode.value === 'invite' ? invite : login;
  if (f.businessError.value || f.serverError.value) return failureOf({ businessError: f.businessError.value, serverError: f.serverError.value })?.message;
  return undefined;
});
const errs = computed(() => (mode.value === 'invite' ? invite.fieldErrors.value : login.fieldErrors.value));
const submit = () => (mode.value === 'invite' ? invite.submit() : login.submit());
</script>

<template>
  <AuthLayout>
    <form novalidate @submit.prevent="submit">
      <div>
        <h1>{{ mode === 'invite' ? 'Create Your Account' : 'Sign In' }}</h1>
        <p class="lead">
          to <strong>{{ host }}</strong>
        </p>
      </div>
      <template v-if="mode === 'invite'">
        <label class="ni-field">Invite code
          <input v-model="inviteValues.token" autocomplete="off" :aria-invalid="!!errs.token" />
          <span v-for="m in errs.token" :key="m" class="ni-hint error">{{ m }}</span>
        </label>
        <label class="ni-field">Username
          <input v-model="inviteValues.username" autocomplete="username" autocapitalize="none" spellcheck="false" :aria-invalid="!!errs.username" />
          <span v-for="m in errs.username" :key="m" class="ni-hint error">{{ m }}</span>
        </label>
        <label class="ni-field">Password
          <input v-model="inviteValues.password" type="password" autocomplete="new-password" :aria-invalid="!!errs.password" />
          <span v-for="m in errs.password" :key="m" class="ni-hint error">{{ m }}</span>
        </label>
      </template>
      <template v-else>
        <label class="ni-field">Username
          <input v-model="loginValues.username" autocomplete="username" autocapitalize="none" spellcheck="false" :aria-invalid="!!errs.username" />
          <span v-for="m in errs.username" :key="m" class="ni-hint error">{{ m }}</span>
        </label>
        <label class="ni-field">Password
          <input v-model="loginValues.password" type="password" autocomplete="current-password" :aria-invalid="!!errs.password" />
          <span v-for="m in errs.password" :key="m" class="ni-hint error">{{ m }}</span>
        </label>
      </template>
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
