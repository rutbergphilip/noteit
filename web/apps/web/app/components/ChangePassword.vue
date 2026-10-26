<script setup lang="ts">
import { computed, useTemplateRef } from 'vue';
import { accountChangePassword } from '#safe-action/actions';
import { changePasswordInput } from '#shared/schemas';
import { useNoteit } from '~/composables/useNoteit';
import { failureOf } from '~/utils/actions';
import { useFocusWhenShown } from '~/utils/focus';

const { boot, state } = useNoteit();
// Straight after signing in with the temporary password it's already known; only a reload asks for it again.
const known = !!state.temporaryPassword;
const { values, submit, fieldErrors, serverError, isExecuting } = useFormAction(accountChangePassword, {
  initialValues: { current: state.temporaryPassword ?? '', next: '' },
  clientSchema: changePasswordInput,
  onSuccess: () => {
    state.temporaryPassword = undefined;
    return boot();
  },
});
useActionFormErrors(useTemplateRef('form'), fieldErrors);
// The first password field showing: the temporary one after a reload, else the new one.
useFocusWhenShown(useTemplateRef<HTMLElement>('fields'));
// A wrong current password arrives as a business error with a field error attached, so only transport and
// middleware failures need an alert.
const error = computed(() => (serverError.value ? failureOf({ serverError: serverError.value })?.message : undefined));
</script>

<template>
  <AuthLayout>
    <div>
      <h1 class="text-[28px] font-bold">Choose a New Password</h1>
      <p class="mt-2 text-sm text-muted">Your admin gave {{ state.session?.user.username }} a temporary password. Pick your own to continue.</p>
    </div>
    <div ref="fields" class="contents">
      <UForm ref="form" :state="values" :validate-on="[]" class="flex flex-col gap-4" @submit="submit()">
        <UFormField v-if="!known" label="Temporary password" name="current">
          <UInput v-model="values.current" size="xl" type="password" autocomplete="current-password" />
        </UFormField>
        <UFormField label="New password" name="next" help="At least 10 characters.">
          <UInput v-model="values.next" size="xl" type="password" autocomplete="new-password" />
        </UFormField>
        <UAlert v-if="error" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="error" />
        <UButton type="submit" size="xl" block label="Save Password" :loading="isExecuting" />
      </UForm>
    </div>
  </AuthLayout>
</template>
