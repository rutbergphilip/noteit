<script setup lang="ts">
import { computed, reactive, ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';
import { corsExamples } from '~/utils/corsExamples';
import type { CorsResult } from '~/worker/corsCheck';

/**
 * Direct mode's connect wizard (spec §6.4): the bucket and an access key, a CORS check before anything is saved,
 * then the sync passphrase. The vault is sealed (and any older one replaced) only once the store opened.
 */
const { state, client, refresh, boot } = useNoteit();
const origin = location.origin;

const creds = reactive({ endpoint: '', region: 'us-east-1', bucket: '', prefix: '', pathStyle: true, accessKeyId: '', secretAccessKey: '' });
const step = ref<'bucket' | 'passphrase'>('bucket');
const checking = ref(false);
const result = ref<CorsResult>();
const hasStore = ref(false);
const formError = ref('');

const examples = computed(() => corsExamples(origin, creds.bucket || 'my-notes'));
const helpItems = computed(() => examples.value.map((e) => ({ label: e.label, value: e.id, content: e.intro, code: e.code })));

async function check(): Promise<void> {
  formError.value = '';
  result.value = undefined;
  if (!/^https?:\/\/[^\s/]+/.test(creds.endpoint.trim())) return void (formError.value = 'Enter the endpoint URL, such as https://s3.eu-north-1.amazonaws.com.');
  if (!creds.bucket.trim() || !creds.accessKeyId.trim() || !creds.secretAccessKey.trim()) return void (formError.value = 'Enter the bucket, the access key ID and its secret.');
  checking.value = true;
  try {
    const answer = await client().checkDirect({ ...creds });
    result.value = answer.cors;
    hasStore.value = !!answer.hasStore;
  } finally {
    checking.value = false;
  }
}

const passphrase = ref('');
const confirm = ref('');
const connecting = ref(false);
const connectError = ref('');
const messages: Record<string, string> = {
  wrongPassphrase: "That passphrase doesn't open the notes in this bucket.",
  unsupportedFormat: 'The notes in this bucket were made by a newer NoteIt. Use a newer copy of NoteIt web.',
  unsupportedFeature: 'The notes in this bucket use a feature this version of NoteIt web does not support yet.',
  invalidManifest: "The library's settings file in this bucket is damaged.",
};

async function connect(): Promise<void> {
  connectError.value = '';
  if (!hasStore.value) {
    if (passphrase.value.length < 8) return void (connectError.value = 'Use at least 8 characters. A few random words work well.');
    if (passphrase.value !== confirm.value) return void (connectError.value = "The passphrases don't match.");
  } else if (!passphrase.value) return;
  connecting.value = true;
  const answer = await client().connectDirect({ creds: { ...creds }, passphrase: passphrase.value, create: !hasStore.value });
  connecting.value = false;
  if (answer.status === 'ok') {
    passphrase.value = confirm.value = '';
    creds.secretAccessKey = '';
    state.phase = 'ready';
    await refresh();
  } else if (answer.status === 'legacy') state.phase = 'legacy';
  else if (answer.status === 'error') connectError.value = messages[answer.kind] ?? answer.message;
}
</script>

<template>
  <div class="min-h-dvh bg-(--page) px-4 py-10">
    <div class="mx-auto flex max-w-[760px] flex-col gap-6">
      <div class="flex items-center gap-2.5 text-xl">
        <img src="/noteit-icon.png" alt="" width="32" height="32" />
        <span class="ni-wordmark">Note<span>It</span></span>
        <span class="ms-2 text-sm text-muted">Connect your bucket</span>
      </div>

      <UCard class="rounded-(--radius-2xl) shadow-(--shadow-card) ring-0" :ui="{ body: 'flex flex-col gap-6 p-5 sm:p-8' }">
        <template v-if="step === 'bucket'">
          <div>
            <h1 class="text-[26px] font-bold max-sm:text-[22px]">Sync with your own bucket</h1>
            <p class="mt-2 text-[15px]/normal text-muted">
              This copy of NoteIt has no server: it syncs straight from this browser to an S3-compatible bucket, the same one your Mac can use (Settings › Sync › S3-compatible). Notes are
              encrypted before they leave the browser.
            </p>
          </div>
          <form class="grid grid-cols-[repeat(auto-fit,minmax(240px,1fr))] gap-4" @submit.prevent="check">
            <UFormField label="Endpoint" help="For example https://s3.eu-north-1.amazonaws.com" class="sm:col-span-2">
              <UInput v-model="creds.endpoint" size="lg" placeholder="https://" autocomplete="off" spellcheck="false" class="w-full" />
            </UFormField>
            <UFormField label="Bucket"><UInput v-model="creds.bucket" size="lg" autocomplete="off" spellcheck="false" class="w-full" /></UFormField>
            <UFormField label="Region"><UInput v-model="creds.region" size="lg" autocomplete="off" spellcheck="false" class="w-full" /></UFormField>
            <UFormField label="Key prefix" hint="Optional" help="As on your Mac, if you set one there.">
              <UInput v-model="creds.prefix" size="lg" autocomplete="off" spellcheck="false" class="w-full" />
            </UFormField>
            <UFormField label="Path-style URLs" help="On for MinIO, Garage and most self-hosted servers.">
              <USwitch v-model="creds.pathStyle" aria-label="Path-style URLs" />
            </UFormField>
            <UFormField label="Access key ID"><UInput v-model="creds.accessKeyId" size="lg" autocomplete="off" spellcheck="false" class="w-full" /></UFormField>
            <UFormField label="Secret access key">
              <UInput v-model="creds.secretAccessKey" size="lg" type="password" autocomplete="off" class="w-full" />
            </UFormField>
            <UAlert
              class="sm:col-span-2"
              color="neutral"
              variant="subtle"
              icon="i-lucide-key-round"
              description="Use a key that can only read, write, delete and list this one bucket. It's kept in this browser, encrypted with your passphrase, and is only ever used to sign requests to the bucket."
            />
            <UAlert v-if="formError" class="sm:col-span-2" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="formError" />
            <div class="flex flex-wrap justify-end gap-2 sm:col-span-2">
              <UButton v-if="state.hasCache || state.directVault" color="neutral" variant="ghost" size="lg" label="Cancel" @click="boot()" />
              <UButton type="submit" size="lg" icon="i-lucide-plug-zap" :loading="checking" :label="checking ? 'Checking…' : 'Check Connection'" />
            </div>
          </form>

          <template v-if="result">
            <UAlert v-if="!result.ok" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="result.hint" :description="result.detail" />
            <template v-else>
              <UAlert color="success" variant="subtle" icon="i-lucide-check" :title="hasStore ? 'Connected. This bucket already has a NoteIt library.' : 'Connected. The bucket is empty.'" />
              <div class="flex flex-wrap gap-2">
                <UBadge v-if="!result.writes" color="warning" variant="soft" icon="i-lucide-triangle-alert" label="Conditional Writes: Not Supported" />
                <UBadge v-if="!result.deletes" color="warning" variant="soft" icon="i-lucide-triangle-alert" label="Conditional Deletes: Not Supported" />
              </div>
              <p v-if="!result.writes || !result.deletes" class="text-sm/normal text-muted">
                This provider doesn't honour every conditional request. Sync still works, checking each write, but two devices saving the same note at once can't always be told apart, and
                the bucket keeps earlier copies of notes.
              </p>
              <div class="flex justify-end"><UButton size="lg" trailing-icon="i-lucide-arrow-right" label="Continue" @click="step = 'passphrase'" /></div>
            </template>
          </template>

          <section v-if="result && !result.ok" class="flex flex-col gap-3">
            <h2 class="font-semibold">Bucket CORS rules</h2>
            <p class="text-sm/normal text-muted">
              The bucket must allow this site, <code>{{ origin }}</code>: methods GET, PUT, HEAD and DELETE, the request headers below, and expose the <code>ETag</code> header.
            </p>
            <UAccordion :items="helpItems" type="multiple">
              <template #body="{ item }">
                <p class="mb-2 text-sm/normal text-muted">{{ item.content }}</p>
                <pre class="overflow-x-auto rounded-lg bg-elevated p-3 text-xs"><code>{{ item.code }}</code></pre>
              </template>
            </UAccordion>
          </section>
        </template>

        <form v-else class="flex flex-col gap-5" @submit.prevent="connect">
          <div>
            <h1 class="text-[26px] font-bold max-sm:text-[22px]">{{ hasStore ? 'Unlock your notes' : 'Encrypt your notes' }}</h1>
            <p class="mt-2 text-[15px]/normal text-muted">
              {{
                hasStore
                  ? 'Enter the sync passphrase you use on your other devices. It also protects the bucket key in this browser.'
                  : 'Choose the passphrase that encrypts your library. Use the same one on your Mac. It also protects the bucket key in this browser.'
              }}
            </p>
          </div>
          <PassphraseField v-model="passphrase" :label="hasStore ? 'Sync passphrase' : 'Encryption passphrase'" :autocomplete="hasStore ? 'current-password' : 'new-password'" autofocus />
          <PassphraseField v-if="!hasStore" v-model="confirm" label="Type it again" autocomplete="new-password" :hint="false" />
          <UAlert v-if="connectError" color="error" variant="subtle" icon="i-lucide-circle-alert" :title="connectError" />
          <UAlert
            color="warning"
            variant="subtle"
            icon="i-lucide-triangle-alert"
            description="Lost passphrases can't be recovered. Keep a copy in your password manager. Whoever hosts this copy of NoteIt serves the code that runs it: use one you run or trust."
          />
          <div class="flex flex-wrap justify-between gap-2">
            <UButton color="neutral" variant="ghost" size="lg" icon="i-lucide-arrow-left" label="Back" @click="step = 'bucket'" />
            <UButton type="submit" size="lg" :loading="connecting" :label="connecting ? 'Connecting…' : hasStore ? 'Unlock' : 'Create Encrypted Library'" />
          </div>
        </form>
      </UCard>
    </div>
  </div>
</template>
