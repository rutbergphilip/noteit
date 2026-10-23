<script setup lang="ts">
import { computed } from 'vue';
import { accountChangePassword } from '#safe-action/actions';
import { changePasswordInput } from '#shared/schemas';
import { useNoteit } from '~/composables/useNoteit';
import { failureOf } from '~/utils/actions';

const { boot, state } = useNoteit();
const { values, submit, fieldErrors, businessError, serverError, isExecuting } = useFormAction(accountChangePassword, {
  initialValues: { current: '', next: '' },
  clientSchema: changePasswordInput,
  onSuccess: () => boot(),
});
const error = computed(() => (serverError.value ? failureOf({ serverError: serverError.value })?.message : undefined) ?? (businessError.value && !fieldErrors.value.current ? businessError.value.message : undefined));
</script>

<template>
  <AuthLayout>
    <form novalidate @submit.prevent="submit">
      <div>
        <h1>Choose a New Password</h1>
        <p class="lead">Your admin gave {{ state.session?.user.username }} a temporary password. Pick your own to continue.</p>
      </div>
      <label class="ni-field">Temporary password <input v-model="values.current" type="password" autocomplete="current-password" :aria-invalid="!!fieldErrors.current" />
        <span v-for="m in fieldErrors.current" :key="m" class="ni-hint error">{{ m }}</span>
      </label>
      <label class="ni-field">New password <input v-model="values.next" type="password" autocomplete="new-password" :aria-invalid="!!fieldErrors.next" />
        <span v-for="m in fieldErrors.next ?? ['At least 10 characters.']" :key="m" class="ni-hint" :class="{ error: fieldErrors.next }">{{ m }}</span>
      </label>
      <div v-if="error" class="ni-alert error" role="alert">{{ error }}</div>
      <button class="ni-btn" type="submit" :disabled="isExecuting">Save Password</button>
    </form>
  </AuthLayout>
</template>
