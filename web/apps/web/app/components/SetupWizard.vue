<script setup lang="ts">
import { computed, ref } from 'vue';
import { accountCreateS3Key, adminCreateInvite, setup } from '#safe-action/actions';
import { setupInput } from '#shared/schemas';
import { useNoteit } from '~/composables/useNoteit';
import { failureOf } from '~/utils/actions';

const { state, client, refresh, toast } = useNoteit();
const step = ref(1);

const admin = useFormAction(setup, {
  initialValues: { token: '', username: 'admin', password: '' },
  clientSchema: setupInput,
  async onSuccess({ data }) {
    state.session = data;
    const init = await client().init({ userId: data.user.id, baseUrl: location.origin });
    state.deviceName = init.deviceName;
    step.value = 2;
  },
});
const { values, fieldErrors } = admin;
const adminError = computed(() => {
  const f = failureOf({ businessError: admin.businessError.value, serverError: admin.serverError.value });
  // A wrong token is also shown under its field; don't repeat it.
  return f && !fieldErrors.value.token ? f.message : undefined;
});

const invite = useAction(adminCreateInvite, { onError: ({ error }) => toast(failureOf(error)!.message) });
const inviteLink = computed(() => invite.data.value && `${location.origin}/#invite=${invite.data.value.token}`);
const s3Key = useAction(accountCreateS3Key, { onError: ({ error }) => toast(failureOf(error)!.message) });

const steps = ['Admin account', 'Storage', 'Encryption', 'Users & finish'];
const origin = location.origin;

async function finish(): Promise<void> {
  if (state.server) state.server.needsSetup = false;
  state.phase = 'ready';
  await refresh();
}
</script>

<template>
  <!-- design p08 -->
  <div class="page">
    <div class="wrap">
      <div class="top">
        <img src="/noteit-icon.png" alt="" width="32" height="32" />
        <span class="ni-wordmark">Note<span>It</span></span>
        <span class="muted">Server setup</span>
      </div>
      <ol class="steps" aria-label="Setup steps">
        <li v-for="(label, i) in steps" :key="label" :aria-current="step === i + 1 ? 'step' : undefined" :class="{ current: step === i + 1, done: step > i + 1 }">
          <span class="dot"><NiIcon v-if="step > i + 1" name="check" :size="14" :stroke="2.4" /><template v-else>{{ i + 1 }}</template></span>{{ label }}
        </li>
      </ol>

      <form v-if="step === 1" class="card" novalidate @submit.prevent="admin.submit()">
        <div>
          <h1>Create the admin account</h1>
          <p>Paste the setup token from the server's log (or the <code>setup-token</code> file in its data folder). It works once.</p>
        </div>
        <div class="grid">
          <label class="ni-field">Setup token <input v-model="values.token" autocomplete="off" spellcheck="false" :aria-invalid="!!fieldErrors.token" />
            <span v-for="m in fieldErrors.token" :key="m" class="ni-hint error">{{ m }}</span>
          </label>
          <label class="ni-field">Username <input v-model="values.username" autocomplete="username" autocapitalize="none" :aria-invalid="!!fieldErrors.username" />
            <span v-for="m in fieldErrors.username" :key="m" class="ni-hint error">{{ m }}</span>
          </label>
          <label class="ni-field">Password <input v-model="values.password" type="password" autocomplete="new-password" :aria-invalid="!!fieldErrors.password" />
            <span v-for="m in fieldErrors.password ?? ['This signs you in to the server. Your notes get their own passphrase in step 3.']" :key="m" class="ni-hint" :class="{ error: fieldErrors.password }">{{ m }}</span>
          </label>
        </div>
        <div v-if="adminError" class="ni-alert error" role="alert">{{ adminError }}</div>
        <div class="actions"><button class="ni-btn" type="submit" :disabled="admin.isExecuting.value">Continue</button></div>
      </form>

      <section v-else-if="step === 2" class="card">
        <div>
          <h1>Where should notes be stored?</h1>
          <p>NoteIt stores encrypted note files only. Each person gets their own private folder.</p>
        </div>
        <div class="choices">
          <label class="choice selected">
            <span class="title"><input type="radio" name="st" checked />Server disk</span>
            <span class="desc">The data volume of this server, <code>/data</code> in Docker. Back it up like any folder.</span>
          </label>
          <label class="choice disabled">
            <span class="title"><input type="radio" name="st" disabled />S3-compatible bucket</span>
            <span class="desc">MinIO, R2, B2 or AWS S3 behind the server. <span class="soon">Coming soon.</span></span>
          </label>
          <label class="choice disabled">
            <span class="title"><input type="radio" name="st" disabled />WebDAV</span>
            <span class="desc">Nextcloud, a Synology share or any WebDAV server. <span class="soon">Coming soon.</span></span>
          </label>
        </div>
        <div class="ni-alert ok"><NiIcon name="check" /><span><strong>Ready.</strong> Your Mac can sync with this server too: it speaks S3 at <code>/s3</code>.</span></div>
        <div class="actions"><button class="ni-btn" type="button" @click="step = 3">Continue</button></div>
      </section>

      <section v-else-if="step === 3" class="card">
        <div>
          <h1>Encrypt your notes</h1>
          <p>Everything is encrypted in your browser before it's uploaded. If your Mac already syncs a library to this account, use its passphrase.</p>
        </div>
        <CreateStoreForm stay @done="step = 4" />
      </section>

      <section v-else class="card">
        <div>
          <h1>Users &amp; finish</h1>
          <p>Invite family members (each gets their own encrypted library), and connect your Mac.</p>
        </div>
        <div class="row">
          <div>
            <strong>Invite someone</strong>
            <div class="ni-hint">The link works once and expires in 3 days.</div>
          </div>
          <button class="ni-btn secondary small" type="button" @click="invite.execute({ role: 'user' })">Create Invite Link</button>
        </div>
        <code v-if="inviteLink" class="secret">{{ inviteLink }}</code>
        <div class="row">
          <div>
            <strong>Sync your Mac</strong>
            <div class="ni-hint">In NoteIt on your Mac: Settings → Sync → S3-compatible, endpoint <code>{{ origin }}/s3</code>, bucket <code>noteit</code>, region <code>us-east-1</code>, path-style on.</div>
          </div>
          <button class="ni-btn secondary small" type="button" @click="s3Key.execute({ label: 'Mac' })">Create Access Key</button>
        </div>
        <div v-if="s3Key.data.value" class="secret">
          Access key ID: <code>{{ s3Key.data.value.accessKeyId }}</code><br />Secret: <code>{{ s3Key.data.value.secretAccessKey }}</code>
          <div class="ni-hint">Copy the secret now; it isn't shown again.</div>
        </div>
        <div class="actions"><button class="ni-btn" type="button" @click="finish">Open NoteIt</button></div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.page {
  min-height: 100vh;
  background: var(--page);
  padding: 40px 16px;
  container-type: inline-size;
}
.wrap {
  max-width: 880px;
  margin: 0 auto;
  display: flex;
  flex-direction: column;
  gap: 24px;
}
.top {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 20px;
}
.muted {
  margin-left: 8px;
  font-size: 14px;
  color: var(--ink2);
}
.steps {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.steps li {
  flex: 1 1 160px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 12px 14px;
  border-radius: var(--radius-lg);
  background: var(--bg);
  font-size: 14px;
  color: var(--ink2);
}
.steps li.current {
  box-shadow: inset 0 0 0 2px var(--acc);
  font-weight: 600;
  color: var(--ink);
}
.dot {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  border: 1.5px solid var(--line-strong);
  display: grid;
  place-items: center;
  font-size: 12px;
}
.current .dot {
  background: var(--acc);
  border-color: var(--acc);
  color: var(--onacc);
}
.done .dot {
  background: var(--success);
  border-color: var(--success);
  color: #fff;
}
.card {
  background: var(--bg);
  border-radius: var(--radius-2xl);
  box-shadow: var(--shadow-card);
  padding: 32px;
  display: flex;
  flex-direction: column;
  gap: 22px;
}
h1 {
  margin: 0;
  font-size: 26px;
  font-weight: 700;
}
.card p {
  margin: 8px 0 0;
  font-size: 15px;
  line-height: 1.5;
  color: var(--ink2);
}
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
  gap: 16px;
}
.choices {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
  gap: 12px;
}
.choice {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 16px;
  border-radius: 14px;
  border: 1px solid var(--line-strong);
}
.choice.selected {
  border: 2px solid var(--acc);
  background: var(--sel);
}
.choice.disabled {
  opacity: 0.7;
}
.choice .title {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 15px;
  font-weight: 600;
  color: var(--ink);
}
.choice input {
  margin: 0;
  accent-color: var(--acc);
}
.desc {
  font-size: 13px;
  line-height: 1.45;
  color: var(--ink2);
}
.soon {
  color: var(--ink);
}
.actions {
  display: flex;
  justify-content: flex-end;
}
.row {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 14px 0;
  border-top: 1px solid var(--line);
  flex-wrap: wrap;
  justify-content: space-between;
}
.secret {
  display: block;
  padding: 12px 14px;
  border-radius: var(--radius-md);
  background: var(--code);
  font-size: 13px;
  word-break: break-all;
}
@container (max-width: 719px) {
  .card {
    padding: 20px;
  }
  h1 {
    font-size: 22px;
  }
}
</style>
