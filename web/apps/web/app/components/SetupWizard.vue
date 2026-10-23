<script setup lang="ts">
import { computed, ref, useTemplateRef } from 'vue';
import { accountCreateS3Key, adminCreateInvite, setup } from '#safe-action/actions';
import { setupInput } from '#shared/schemas';
import { useNoteit } from '~/composables/useNoteit';
import { failureOf } from '~/utils/actions';

const { state, client, refresh, toast } = useNoteit();
const step = ref(0);
const steps = [
  { title: 'Admin account', icon: 'i-lucide-user-round' },
  { title: 'Storage', icon: 'i-lucide-hard-drive' },
  { title: 'Encryption', icon: 'i-lucide-lock' },
  { title: 'Users & finish', icon: 'i-lucide-users' },
];
const origin = location.origin;

const admin = useFormAction(setup, {
  initialValues: { token: '', username: 'admin', password: '' },
  clientSchema: setupInput,
  async onSuccess({ data }) {
    state.session = data;
    const init = await client().init({ userId: data.user.id, baseUrl: location.origin });
    state.deviceName = init.deviceName;
    step.value = 1;
  },
});
const { values, fieldErrors } = admin;
useActionFormErrors(useTemplateRef('adminForm'), fieldErrors);
const adminError = computed(() => {
  const f = failureOf({ businessError: admin.businessError.value, serverError: admin.serverError.value });
  // A wrong token is shown under its field already.
  return f && !Object.keys(fieldErrors.value).length ? f.message : undefined;
});

const storage = ref('disk');
const storageChoices = [
  { value: 'disk', label: 'Server disk', description: 'The data volume of this server, /data in Docker. Back it up like any folder.' },
  { value: 's3', label: 'S3-compatible bucket', description: 'MinIO, R2, B2 or AWS S3 behind the server. Coming soon.', disabled: true },
  { value: 'webdav', label: 'WebDAV', description: 'Nextcloud, a Synology share or any WebDAV server. Coming soon.', disabled: true },
];

const reportError = ({ error }: { error: Parameters<typeof failureOf>[0] }) => toast(failureOf(error)?.message ?? 'Something went wrong.', 'error');
const invite = useAction(adminCreateInvite, { onError: reportError });
const inviteLink = computed(() => invite.data.value && `${origin}/#invite=${invite.data.value.token}`);
const s3Key = useAction(accountCreateS3Key, { onError: reportError });

async function finish(): Promise<void> {
  if (state.server) state.server.needsSetup = false;
  state.phase = 'ready';
  await refresh();
}
</script>

<template>
  <!-- design p08 -->
  <div class="min-h-dvh bg-(--page) px-4 py-10">
    <div class="mx-auto flex max-w-[880px] flex-col gap-6">
      <div class="flex items-center gap-2.5 text-xl">
        <img src="/noteit-icon.png" alt="" width="32" height="32" />
        <span class="ni-wordmark">Note<span>It</span></span>
        <span class="ms-2 text-sm text-muted">Server setup</span>
      </div>

      <UStepper v-model="step" :items="steps" disabled size="sm" class="w-full" />

      <UCard class="rounded-(--radius-2xl) shadow-(--shadow-card) ring-0" :ui="{ body: 'flex flex-col gap-6 p-5 sm:p-8' }">
        <Transition name="step" mode="out-in">
          <UForm v-if="step === 0" key="0" ref="adminForm" :state="values" :validate-on="[]" class="flex flex-col gap-6" @submit="admin.submit()">
            <div>
              <h1 class="text-[26px] font-bold max-sm:text-[22px]">Create the admin account</h1>
              <p class="mt-2 text-[15px]/normal text-muted">
                Paste the setup token from the server's log (or the <code>setup-token</code> file in its data folder). It works once.
              </p>
            </div>
            <div class="grid grid-cols-[repeat(auto-fit,minmax(240px,1fr))] gap-4">
              <UFormField label="Setup token" name="token" help=" ">
                <UInput v-model="values.token" size="lg" autocomplete="off" spellcheck="false" autofocus />
              </UFormField>
              <UFormField label="Username" name="username" help=" ">
                <UInput v-model="values.username" size="lg" autocomplete="username" autocapitalize="none" />
              </UFormField>
              <UFormField label="Password" name="password" help="This signs you in to the server. Your notes get their own passphrase in step 3.">
                <UInput v-model="values.password" size="lg" type="password" autocomplete="new-password" />
              </UFormField>
            </div>
            <UAlert v-if="adminError" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="adminError" />
            <div class="flex justify-end"><UButton type="submit" size="lg" trailing-icon="i-lucide-arrow-right" label="Continue" :loading="admin.isExecuting.value" /></div>
          </UForm>

          <section v-else-if="step === 1" key="1" class="flex flex-col gap-6">
            <div>
              <h1 class="text-[26px] font-bold max-sm:text-[22px]">Where should notes be stored?</h1>
              <p class="mt-2 text-[15px]/normal text-muted">NoteIt stores encrypted note files only. Each person gets their own private folder.</p>
            </div>
            <URadioGroup v-model="storage" :items="storageChoices" variant="card" orientation="horizontal" legend="Storage" :ui="{ fieldset: 'grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3', item: 'items-start' }" />
            <UAlert color="success" variant="subtle" icon="i-lucide-check" title="Ready." description="Your Mac can sync with this server too: it speaks S3 at /s3." />
            <div class="flex justify-end"><UButton size="lg" trailing-icon="i-lucide-arrow-right" label="Continue" @click="step = 2" /></div>
          </section>

          <section v-else-if="step === 2" key="2" class="flex flex-col gap-6">
            <div>
              <h1 class="text-[26px] font-bold max-sm:text-[22px]">Encrypt your notes</h1>
              <p class="mt-2 text-[15px]/normal text-muted">Everything is encrypted in your browser before it's uploaded. If your Mac already syncs a library to this account, use its passphrase.</p>
            </div>
            <CreateStoreForm stay @done="step = 3" />
          </section>

          <section v-else key="3" class="flex flex-col gap-2">
            <div class="mb-4">
              <h1 class="text-[26px] font-bold max-sm:text-[22px]">Users &amp; finish</h1>
              <p class="mt-2 text-[15px]/normal text-muted">Invite family members (each gets their own encrypted library), and connect your Mac.</p>
            </div>
            <div class="flex flex-wrap items-center justify-between gap-4 border-t border-default py-4">
              <div>
                <strong>Invite someone</strong>
                <div class="text-xs text-muted">The link works once and expires in 3 days.</div>
              </div>
              <UButton color="neutral" variant="outline" icon="i-lucide-link" label="Create Invite Link" :loading="invite.isExecuting.value" @click="invite.execute({ role: 'user' })" />
            </div>
            <SecretValue v-if="inviteLink" :value="inviteLink" label="Invite link" />
            <div class="flex flex-wrap items-center justify-between gap-4 border-t border-default py-4">
              <div class="max-w-xl">
                <strong>Sync your Mac</strong>
                <div class="text-xs/normal text-muted">
                  In NoteIt on your Mac: Settings → Sync → S3-compatible, endpoint <code>{{ origin }}/s3</code>, bucket <code>noteit</code>, region <code>us-east-1</code>, path-style on.
                </div>
              </div>
              <UButton color="neutral" variant="outline" icon="i-lucide-key-round" label="Create Access Key" :loading="s3Key.isExecuting.value" @click="s3Key.execute({ label: 'Mac' })" />
            </div>
            <template v-if="s3Key.data.value">
              <SecretValue :value="s3Key.data.value.accessKeyId" label="Access key ID" />
              <SecretValue :value="s3Key.data.value.secretAccessKey" label="Secret" hint="Copy the secret now; it isn't shown again." />
            </template>
            <div class="mt-4 flex justify-end"><UButton size="lg" label="Open NoteIt" trailing-icon="i-lucide-arrow-right" @click="finish" /></div>
          </section>
        </Transition>
      </UCard>
    </div>
  </div>
</template>

<style scoped>
.step-enter-active,
.step-leave-active {
  transition:
    opacity 160ms ease,
    transform 160ms ease;
}
.step-enter-from {
  opacity: 0;
  transform: translateX(12px);
}
.step-leave-to {
  opacity: 0;
  transform: translateX(-12px);
}
</style>
