<script setup lang="ts">
import { computed, ref, useTemplateRef, watch } from 'vue';
import { redeemInvite, signIn } from '#safe-action/actions';
import { redeemInviteInput, signInInput } from '#shared/schemas';
import { useNoteit } from '~/composables/useNoteit';
import { failureOf } from '~/utils/actions';
import { useFocusWhenShown } from '~/utils/focus';

const { enter, state } = useNoteit();
const hashInvite = state.inviteToken;
const mode = ref<'signin' | 'invite'>(hashInvite ? 'invite' : 'signin');
const host = location.host;

// useFormAction owns values, validation and the request; UForm renders the field errors.
const login = useFormAction(signIn, {
  initialValues: { username: '', password: '' },
  clientSchema: signInInput,
  onSuccess: ({ data }) => {
    if (data?.user.mustChangePassword) state.temporaryPassword = login.values.value.password;
    return enter(data);
  },
});
const invite = useFormAction(redeemInvite, {
  initialValues: { token: hashInvite, username: '', password: '' },
  clientSchema: redeemInviteInput,
  onSuccess: ({ data }) => {
    history.replaceState(null, '', location.pathname);
    state.inviteToken = '';
    return enter(data);
  },
});
useActionFormErrors(useTemplateRef('loginForm'), login.fieldErrors);
useActionFormErrors(useTemplateRef('inviteForm'), invite.fieldErrors);
const loginValues = login.values;
const inviteValues = invite.values;
// An invite link opened while this screen is showing (the hash changed, the page didn't reload).
watch(
  () => state.inviteToken,
  (token) => {
    if (!token) return;
    inviteValues.value.token = token;
    mode.value = 'invite';
  },
);

// The first field of whichever form is showing; the plain `autofocus` attribute misses after sign-out and on reload.
useFocusWhenShown(useTemplateRef<HTMLElement>('firstField'));

const active = computed(() => (mode.value === 'invite' ? invite : login));
/** Failures that aren't about one field: wrong credentials, rate limits, an unreachable server. */
const error = computed(() => {
  const f = active.value;
  const failure = failureOf({ businessError: f.businessError.value, serverError: f.serverError.value });
  return failure && !Object.keys(f.fieldErrors.value).length ? failure.message : undefined;
});
</script>

<template>
  <AuthLayout>
    <div>
      <h1 class="text-[28px] font-bold">{{ mode === 'invite' ? 'Create Your Account' : 'Sign In' }}</h1>
      <p class="mt-2 text-sm text-muted">
        to <strong class="text-default">{{ host }}</strong>
      </p>
    </div>

    <UForm v-if="mode === 'invite'" ref="inviteForm" :state="inviteValues" :validate-on="[]" class="flex flex-col gap-1.5" @submit="invite.submit()">
      <UFormField label="Invite code" name="token" help=" ">
        <div ref="firstField"><UInput v-model="inviteValues.token" size="xl" autocomplete="off" spellcheck="false" /></div>
      </UFormField>
      <UFormField label="Username" name="username" help=" ">
        <UInput v-model="inviteValues.username" size="xl" autocomplete="username" autocapitalize="none" spellcheck="false" />
      </UFormField>
      <UFormField label="Password" name="password" hint="10+ characters" help=" ">
        <UInput v-model="inviteValues.password" size="xl" type="password" autocomplete="new-password" />
      </UFormField>
      <UAlert v-if="error" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="error" />
      <UButton type="submit" size="xl" block label="Create Account" :loading="invite.isExecuting.value" />
    </UForm>

    <UForm v-else ref="loginForm" :state="loginValues" :validate-on="[]" class="flex flex-col gap-1.5" @submit="login.submit()">
      <UFormField label="Username" name="username" help=" ">
        <div ref="firstField"><UInput v-model="loginValues.username" size="xl" autocomplete="username" autocapitalize="none" spellcheck="false" /></div>
      </UFormField>
      <UFormField label="Password" name="password" help=" ">
        <UInput v-model="loginValues.password" size="xl" type="password" autocomplete="current-password" />
      </UFormField>
      <UAlert v-if="error" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="error" />
      <UButton type="submit" size="xl" block label="Sign In" :loading="login.isExecuting.value" />
    </UForm>

    <p class="text-[13px]/normal text-muted">Signing in only opens your account. Your notes stay encrypted until you unlock them with your passphrase on the next step.</p>
    <UButton
      variant="link"
      class="self-start p-0"
      :label="mode === 'signin' ? 'I have an invite' : 'I already have an account'"
      @click="mode = mode === 'signin' ? 'invite' : 'signin'"
    />
  </AuthLayout>
</template>
