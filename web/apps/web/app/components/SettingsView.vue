<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import {
  accountChangePassword,
  accountCreateS3Key,
  accountRevokeS3Key,
  accountRotateS3Key,
  accountS3Keys,
  accountSignOutEverywhere,
  accountUpdateProfile,
  adminCreateInvite,
  adminCreateUser,
  adminDeleteUser,
  adminInvites,
  adminResetPassword,
  adminRevokeInvite,
  adminUpdateUser,
  adminUsers,
  session,
} from '#safe-action/actions';
import { changePasswordInput, createUserInput } from '#shared/schemas';
import { useNoteit } from '~/composables/useNoteit';
import { failureOf, unwrap } from '~/utils/actions';
import { formatBytes, relativeTime } from '~/utils/format';
import type { DeviceView } from '~/worker/types';

const { state, client, setTheme, lock, signOut, toast, boot } = useNoteit();
type Section = 'general' | 'sync' | 'security' | 'account' | 'users' | 'about';
const section = ref<Section>('sync');
const isAdmin = computed(() => state.session?.user.role === 'admin');
const origin = location.origin;
const noteCount = computed(() => state.notes.filter((n) => !n.deletedAt).length);

/** Every failed call surfaces as a toast; an expired session goes back through boot to the sign-in screen. */
function report(error: Parameters<typeof failureOf>[0]): void {
  const f = failureOf(error);
  if (!f) return;
  if (f.code === 'unauthorized') void boot();
  toast(f.message);
}

// MARK: queries. GET actions read through Nuxt's useAsyncData; each key is tagged so a mutation can name
// what it changed (`invalidate: { tags }`) instead of every caller refetching by hand.

const queries = {
  session: useAction(session),
  keys: useAction(accountS3Keys),
  users: useAction(adminUsers),
  invites: useAction(adminInvites),
};
const { data: keys } = useAsyncData('settings:s3-keys', async () => unwrap(await queries.keys.executeAsync(undefined)), { default: () => [] });
useActionQueryTags('settings:s3-keys', ['s3-keys']);
const { data: users } = useAsyncData('settings:users', async () => (isAdmin.value ? unwrap(await queries.users.executeAsync(undefined)).users : []), { default: () => [] });
useActionQueryTags('settings:users', ['users']);
const { data: invites } = useAsyncData('settings:invites', async () => (isAdmin.value ? unwrap(await queries.invites.executeAsync(undefined)) : []), { default: () => [] });
useActionQueryTags('settings:invites', ['invites']);

const devices = ref<DeviceView[]>([]);
async function loadSync(): Promise<void> {
  devices.value = await client().devices();
  const s = await queries.session.executeAsync(undefined);
  if (s.data) state.session = s.data;
  else report(s);
}
watch(section, (s) => s === 'sync' && loadSync());
onMounted(loadSync);

// MARK: this browser

const deviceName = ref(state.deviceName);
async function saveDeviceName(): Promise<void> {
  state.deviceName = await client().setDeviceName(deviceName.value);
  toast('Device name saved');
}
async function forget(): Promise<void> {
  if (!confirm('Sign out and delete the encrypted copy of your notes from this browser? Notes on the server are kept.')) return;
  await signOut(true);
}

// MARK: account

const profile = useFormAction(accountUpdateProfile, {
  initialValues: { displayName: state.session?.user.displayName ?? '' },
  onSuccess: ({ data }) => {
    state.session = data;
    toast('Name saved');
  },
  onError: ({ error }) => report(error),
});
const password = useFormAction(accountChangePassword, {
  initialValues: { current: '', next: '' },
  clientSchema: changePasswordInput,
  onSuccess: () => {
    password.reset();
    toast('Password changed. Other browsers are signed out.');
  },
  onError: ({ error }) => error.serverError && report(error),
});
const signOutEverywhere = useAction(accountSignOutEverywhere, { onSuccess: () => signOut(), onError: ({ error }) => report(error) });

const keyLabel = ref('Mac');
const newKey = ref<{ accessKeyId: string; secretAccessKey: string }>();
const keyMutation = { invalidate: { tags: ['s3-keys'] }, onError: ({ error }: { error: Parameters<typeof failureOf>[0] }) => report(error) };
const createKey = useAction(accountCreateS3Key, { ...keyMutation, onSuccess: ({ data }) => (newKey.value = data) });
const rotateKey = useAction(accountRotateS3Key, { ...keyMutation, onSuccess: ({ data }) => (newKey.value = data) });
const revokeKey = useAction(accountRevokeS3Key, { ...keyMutation, onSuccess: () => toast('Key revoked') });

// MARK: admin

const created = ref<string>();
const inviteLink = ref<string>();
const userMutation = { invalidate: { tags: ['users'] }, onError: ({ error }: { error: Parameters<typeof failureOf>[0] }) => report(error) };
const addUser = useFormAction(adminCreateUser, {
  initialValues: { username: '', role: 'user' as 'user' | 'admin' },
  clientSchema: createUserInput,
  invalidate: { tags: ['users'] },
  onSuccess: ({ data }) => {
    created.value = `${data.user.username}: temporary password ${data.temporaryPassword}`;
    addUser.reset();
  },
  onError: ({ error }) => error.serverError && report(error),
});
const updateUser = useAction(adminUpdateUser, userMutation);
const resetPassword = useAction(adminResetPassword, {
  ...userMutation,
  onSuccess: ({ data, input }) => (created.value = `${users.value.find((u) => u.id === input.id)?.username}: temporary password ${data.temporaryPassword}`),
});
const removeUser = useAction(adminDeleteUser, { ...userMutation, onSuccess: () => toast('User deleted') });
function deleteUser(id: string, username: string): void {
  const typed = prompt(`This deletes ${username} and all of their encrypted notes on this server. Type the username to confirm.`);
  if (typed === username) removeUser.execute({ id, confirmUsername: typed });
}
const inviteMutation = { invalidate: { tags: ['invites'] }, onError: ({ error }: { error: Parameters<typeof failureOf>[0] }) => report(error) };
const createInvite = useAction(adminCreateInvite, { ...inviteMutation, onSuccess: ({ data }) => (inviteLink.value = `${origin}/#invite=${data.token}`) });
const revokeInvite = useAction(adminRevokeInvite, inviteMutation);
</script>

<template>
  <!-- design p09 / p15 -->
  <div class="settings">
    <header>
      <button type="button" class="ni-btn ghost small" @click="state.settings = false"><NiIcon name="back" :size="16" />Back to notes</button>
      <h1>Settings</h1>
    </header>
    <div class="wrap">
      <nav class="nav" aria-label="Settings sections">
        <a href="#" :aria-current="section === 'general' ? 'page' : undefined" @click.prevent="section = 'general'">General</a>
        <a href="#" :aria-current="section === 'sync' ? 'page' : undefined" @click.prevent="section = 'sync'">Sync &amp; storage</a>
        <a href="#" :aria-current="section === 'security' ? 'page' : undefined" @click.prevent="section = 'security'">Security &amp; devices</a>
        <a href="#" :aria-current="section === 'account' ? 'page' : undefined" @click.prevent="section = 'account'">Account</a>
        <template v-if="isAdmin">
          <div class="grp">Server admin</div>
          <a href="#" :aria-current="section === 'users' ? 'page' : undefined" @click.prevent="section = 'users'">Users</a>
        </template>
        <a href="#" :aria-current="section === 'about' ? 'page' : undefined" @click.prevent="section = 'about'">About NoteIt</a>
      </nav>

      <main>
        <template v-if="section === 'general'">
          <div><h2>General</h2></div>
          <section class="card">
            <h3>Appearance</h3>
            <div class="row">
              <div><div>Theme</div><div class="sub">Follows your system unless you pick one.</div></div>
              <select v-model="state.theme" class="sel" @change="setTheme(state.theme)">
                <option value="system">System</option>
                <option value="light">Light</option>
                <option value="dark">Dark</option>
              </select>
            </div>
          </section>
          <section class="card">
            <h3>This browser</h3>
            <div class="row">
              <div class="grow"><div>Device name</div><div class="sub">Shown in conflict copies on your other devices.</div></div>
              <input v-model="deviceName" class="ni-input short" maxlength="64" />
              <button type="button" class="ni-btn small secondary" @click="saveDeviceName()">Save</button>
            </div>
          </section>
        </template>

        <template v-else-if="section === 'sync'">
          <div>
            <h2>Sync &amp; storage</h2>
            <p class="sub">Everything is encrypted in this browser before it's uploaded.</p>
          </div>
          <section class="card status">
            <span class="badge"><NiIcon name="server" :size="22" color="var(--acc)" /></span>
            <div class="grow">
              <h3>Connected to this server</h3>
              <div class="sub">{{ origin }} · last synced {{ state.status.lastSync ? relativeTime(state.status.lastSync).toLowerCase() : 'not yet' }}</div>
            </div>
            <div class="stats">
              <div><strong>{{ noteCount }}</strong>notes</div>
              <div v-if="state.session"><strong>{{ formatBytes(state.session.quota.usedBytes) }}</strong>of {{ formatBytes(state.session.quota.limitBytes) }}</div>
            </div>
            <button type="button" class="ni-btn small" @click="client().syncNow()">Sync Now</button>
          </section>
          <section v-if="state.status.recordErrors.length" class="card">
            <h3>{{ state.status.recordErrors.length }} items will be retried on the next sync</h3>
            <div v-for="(e, i) in state.status.recordErrors" :key="i" class="row sub">{{ e.message }}</div>
          </section>
          <section class="card">
            <h3>Devices using this library</h3>
            <div v-for="d in devices" :key="d.deviceID" class="row">
              <div>
                <div>{{ d.name }} <span v-if="d.current" class="pill">This browser</span></div>
                <div class="sub">{{ d.platform === 'web' ? 'NoteIt web' : d.platform === 'mac' ? 'NoteIt for Mac' : 'NoteIt' }} · last synced {{ relativeTime(d.lastSync).toLowerCase() }}</div>
              </div>
            </div>
            <div v-if="!devices.length" class="row sub">No devices have synced yet.</div>
          </section>
        </template>

        <template v-else-if="section === 'security'">
          <div><h2>Security &amp; devices</h2></div>
          <section class="card">
            <h3>This browser</h3>
            <div class="row">
              <div class="grow"><div>Lock NoteIt</div><div class="sub">Forgets the key in memory. You'll need your passphrase to open your notes again.</div></div>
              <button type="button" class="ni-btn small secondary" @click="lock()">Lock</button>
            </div>
            <div class="row">
              <div class="grow"><div>Sign out &amp; forget this device</div><div class="sub">Deletes the encrypted offline copy from this browser.</div></div>
              <button type="button" class="ni-btn small danger" @click="forget">Forget</button>
            </div>
          </section>
          <section class="card">
            <h3>Password</h3>
            <p class="sub">Your password opens your account. Your notes use your separate encryption passphrase, which never reaches the server.</p>
            <form class="form" novalidate @submit.prevent="password.submit()">
              <label class="ni-field">Current password <input v-model="password.values.value.current" type="password" autocomplete="current-password" :aria-invalid="!!password.fieldErrors.value.current" />
                <span v-for="m in password.fieldErrors.value.current" :key="m" class="ni-hint error">{{ m }}</span>
              </label>
              <label class="ni-field">New password <input v-model="password.values.value.next" type="password" autocomplete="new-password" :aria-invalid="!!password.fieldErrors.value.next" />
                <span v-for="m in password.fieldErrors.value.next" :key="m" class="ni-hint error">{{ m }}</span>
              </label>
              <button type="submit" class="ni-btn small" :disabled="password.isExecuting.value">Change Password</button>
            </form>
            <div class="row">
              <div class="grow"><div>Sign out everywhere</div><div class="sub">Ends every session of this account, including this one.</div></div>
              <button type="button" class="ni-btn small secondary" @click="signOutEverywhere.execute(undefined)">Sign Out Everywhere</button>
            </div>
          </section>
        </template>

        <template v-else-if="section === 'account'">
          <div><h2>Account</h2></div>
          <section class="card">
            <div class="row first">
              <div class="grow"><div>Name</div><div class="sub">Signed in as {{ state.session?.user.username }}</div></div>
              <input v-model="profile.values.value.displayName" class="ni-input short" maxlength="64" aria-label="Name" />
              <button type="button" class="ni-btn small secondary" :disabled="profile.isExecuting.value" @click="profile.submit()">Save</button>
            </div>
          </section>
          <section class="card">
            <h3>S3 access keys</h3>
            <p class="sub">
              For NoteIt on your Mac (Settings → Sync → S3-compatible) or backup tools like rclone. Endpoint <code>{{ origin }}/s3</code>, bucket <code>noteit</code>, region <code>us-east-1</code>, path-style. A key opens
              only your own encrypted store.
            </p>
            <div v-for="k in keys" :key="k.accessKeyId" class="row">
              <div class="grow">
                <div>{{ k.label }} <code>{{ k.accessKeyId }}</code></div>
                <div class="sub">Created {{ relativeTime(k.createdAt).toLowerCase() }}{{ k.lastUsedAt ? ` · used ${relativeTime(k.lastUsedAt).toLowerCase()}` : ' · never used' }}</div>
              </div>
              <button type="button" class="ni-btn small secondary" @click="rotateKey.execute({ accessKeyId: k.accessKeyId })">Replace</button>
              <button type="button" class="ni-btn small ghost" @click="revokeKey.execute({ accessKeyId: k.accessKeyId })">Revoke</button>
            </div>
            <div class="row">
              <input v-model="keyLabel" class="ni-input short" maxlength="64" aria-label="Key label" />
              <button type="button" class="ni-btn small" :disabled="createKey.isExecuting.value" @click="createKey.execute({ label: keyLabel })">Create Key</button>
            </div>
            <div v-if="newKey" class="secret">
              Access key ID: <code>{{ newKey.accessKeyId }}</code><br />Secret access key: <code>{{ newKey.secretAccessKey }}</code>
              <div class="sub">Copy the secret now. It isn't shown again.</div>
            </div>
          </section>
        </template>

        <template v-else-if="section === 'users' && isAdmin">
          <div>
            <h2>Users</h2>
            <p class="sub">Every person has their own encrypted library and passphrase. Admins can't read anyone's notes.</p>
          </div>
          <section class="card">
            <div v-for="u in users" :key="u.id" class="row">
              <div class="grow">
                <div>{{ u.displayName }} <span class="sub">@{{ u.username }}</span> <span v-if="u.role === 'admin'" class="pill">Admin</span> <span v-if="u.status !== 'active'" class="pill warn">{{ u.status }}</span></div>
                <div class="sub">{{ formatBytes(u.usedBytes) }} of {{ formatBytes(u.quotaBytes) }} · {{ u.objectCount }} objects{{ u.lastSeenAt ? ` · seen ${relativeTime(u.lastSeenAt).toLowerCase()}` : '' }}</div>
              </div>
              <template v-if="u.id !== state.session?.user.id">
                <button type="button" class="ni-btn small ghost" @click="resetPassword.execute({ id: u.id })">Reset Password</button>
                <button type="button" class="ni-btn small ghost" @click="updateUser.execute({ id: u.id, status: u.status === 'active' ? 'disabled' : 'active' })">{{ u.status === 'active' ? 'Disable' : 'Enable' }}</button>
                <button type="button" class="ni-btn small ghost" @click="deleteUser(u.id, u.username)">Delete</button>
              </template>
            </div>
          </section>
          <section class="card">
            <h3>Add someone</h3>
            <form class="inline" novalidate @submit.prevent="addUser.submit()">
              <input v-model="addUser.values.value.username" class="ni-input short" placeholder="username" aria-label="Username" :aria-invalid="!!addUser.fieldErrors.value.username" />
              <select v-model="addUser.values.value.role" class="sel" aria-label="Role"><option value="user">User</option><option value="admin">Admin</option></select>
              <button type="submit" class="ni-btn small" :disabled="addUser.isExecuting.value">Create User</button>
              <button type="button" class="ni-btn small secondary" @click="createInvite.execute({ role: 'user' })">Create Invite Link</button>
            </form>
            <span v-for="m in addUser.fieldErrors.value.username" :key="m" class="ni-hint error">{{ m }}</span>
            <code v-if="created" class="secret">{{ created }}</code>
            <code v-if="inviteLink" class="secret">{{ inviteLink }}</code>
            <div v-for="i in invites.filter((x) => !x.usedAt && !x.revokedAt)" :key="i.id" class="row">
              <div class="grow sub">Invite ({{ i.role }}) · expires {{ new Date(i.expiresAt).toLocaleString() }}</div>
              <button type="button" class="ni-btn small ghost" @click="revokeInvite.execute({ id: i.id })">Revoke</button>
            </div>
          </section>
        </template>

        <template v-else-if="section === 'about'">
          <div><h2>About NoteIt</h2></div>
          <section class="card">
            <div class="row first">
              <img src="/noteit-icon.png" alt="" width="48" height="48" />
              <div>
                <div class="ni-wordmark">Note<span>It</span> web {{ state.server?.version }}</div>
                <div class="sub">Free software under the AGPL-3.0-or-later. <a :href="state.server?.sourceUrl" rel="noopener noreferrer">Source code</a></div>
              </div>
            </div>
          </section>
        </template>
      </main>
    </div>
  </div>
</template>

<style scoped>
.settings {
  min-height: 100vh;
  background: var(--page);
  container-type: inline-size;
}
header {
  height: var(--header-h);
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 0 20px;
  background: var(--bg);
  border-bottom: 1px solid var(--line);
}
h1 {
  margin: 0;
  font-size: 17px;
}
.wrap {
  display: flex;
  flex-wrap: wrap;
  gap: 24px;
  padding: 24px;
  max-width: 1100px;
  margin: 0 auto;
}
.nav {
  flex: 1 1 200px;
  max-width: 240px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.nav a {
  display: flex;
  align-items: center;
  height: 36px;
  padding: 0 12px;
  border-radius: 9px;
  color: var(--ink);
  text-decoration: none;
  font-size: 14px;
}
.nav a[aria-current='page'] {
  background: var(--sel);
  font-weight: 600;
}
.grp {
  font-size: 11px;
  font-weight: 600;
  color: var(--ink2);
  padding: 14px 12px 4px;
}
main {
  flex: 999 1 420px;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 18px;
}
h2 {
  margin: 0;
  font-size: 24px;
}
h3 {
  margin: 0;
  font-size: 15px;
}
.sub {
  font-size: 13px;
  color: var(--ink2);
  line-height: 1.45;
  margin: 4px 0 0;
}
.card {
  background: var(--bg);
  border-radius: var(--radius-xl);
  border: 1px solid var(--line);
  padding: 20px 22px;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.card.status {
  flex-direction: row;
  flex-wrap: wrap;
  align-items: center;
  gap: 18px;
}
.badge {
  width: 44px;
  height: 44px;
  border-radius: 12px;
  background: var(--sel);
  display: grid;
  place-items: center;
}
.stats {
  display: flex;
  gap: 18px;
  font-size: 12px;
  color: var(--ink2);
}
.stats div {
  display: flex;
  flex-direction: column;
}
.stats strong {
  font-size: 18px;
  color: var(--ink);
}
.row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 14px 0;
  border-top: 1px solid var(--line);
  flex-wrap: wrap;
  font-size: 14px;
}
.row.first {
  border-top: 0;
}
.grow {
  flex: 1;
  min-width: 180px;
}
.short {
  width: auto;
  max-width: 220px;
  height: 36px;
  font-size: 14px;
}
.sel {
  height: 36px;
  border: 1px solid var(--line-strong);
  border-radius: 9px;
  background: var(--bg);
  padding: 0 8px;
}
.pill {
  font-size: 11px;
  padding: 2px 8px;
  border-radius: 999px;
  background: var(--sel);
  color: var(--acct);
  font-weight: 600;
}
.pill.warn {
  background: var(--warn-bg);
  color: var(--warn-ink);
}
.form {
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-width: 360px;
  padding: 12px 0;
}
.inline {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  padding: 10px 0;
}
.secret {
  display: block;
  margin-top: 8px;
  padding: 12px 14px;
  border-radius: var(--radius-md);
  background: var(--code);
  font-size: 13px;
  word-break: break-all;
}
@container (max-width: 719px) {
  .wrap {
    padding: 16px;
    gap: 16px;
  }
  .nav {
    flex: 1 1 100%;
    max-width: none;
    flex-direction: row;
    overflow-x: auto;
    gap: 4px;
  }
  .nav a {
    flex: none;
    background: var(--bg);
  }
  .grp {
    display: none;
  }
  .card {
    padding: 16px;
  }
}
</style>
