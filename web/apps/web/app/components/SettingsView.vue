<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useNoteit } from '~/composables/useNoteit';
import { api, ApiError, formatBytes, relativeTime, type SessionInfo } from '~/utils/api';
import type { DeviceView } from '~/worker/types';

const { state, client, setTheme, lock, signOut, toast } = useNoteit();
type Section = 'general' | 'sync' | 'security' | 'account' | 'users' | 'about';
const section = ref<Section>('sync');
const isAdmin = computed(() => state.session?.user.role === 'admin');

const devices = ref<DeviceView[]>([]);
const deviceName = ref(state.deviceName);
const keys = ref<{ accessKeyId: string; label: string; createdAt: string; lastUsedAt?: string }[]>([]);
const newKey = ref<{ accessKeyId: string; secretAccessKey: string }>();
const keyLabel = ref('Mac');
const pw = ref({ current: '', next: '' });
const displayName = ref(state.session?.user.displayName ?? '');
const users = ref<{ id: string; username: string; displayName: string; role: string; status: string; usedBytes: number; quotaBytes: number; objectCount: number; lastSeenAt?: string }[]>([]);
const invites = ref<{ id: string; role: string; expiresAt: string; usedAt?: string; revokedAt?: string }[]>([]);
const newUser = ref({ username: '', role: 'user' });
const created = ref<string>();
const inviteLink = ref<string>();
const origin = location.origin;

const noteCount = computed(() => state.notes.filter((n) => !n.deletedAt).length);

async function loadSection(): Promise<void> {
  try {
    if (section.value === 'sync') {
      devices.value = await client().devices();
      state.session = await api<SessionInfo>('/session');
    } else if (section.value === 'account') keys.value = await api('/account/s3-keys');
    else if (section.value === 'users' && isAdmin.value) {
      users.value = (await api<{ users: typeof users.value }>('/admin/users')).users;
      invites.value = await api('/admin/invites');
    }
  } catch (e) {
    toast(e instanceof Error ? e.message : String(e));
  }
}
watch(section, loadSection);
onMounted(loadSection);

async function run(fn: () => Promise<unknown>, done?: string): Promise<void> {
  try {
    await fn();
    if (done) toast(done);
    await loadSection();
  } catch (e) {
    toast(e instanceof ApiError ? e.message : e instanceof Error ? e.message : String(e));
  }
}

const saveDeviceName = () => run(async () => (state.deviceName = await client().setDeviceName(deviceName.value)), 'Device name saved');
const saveDisplayName = () => run(async () => (state.session = await api<SessionInfo>('/account', { method: 'PATCH', body: { displayName: displayName.value } })), 'Name saved');
const changePassword = () =>
  run(async () => {
    await api('/account/password', { method: 'POST', body: pw.value });
    pw.value = { current: '', next: '' };
  }, 'Password changed. Other browsers are signed out.');
const createKey = () => run(async () => (newKey.value = await api('/account/s3-keys', { method: 'POST', body: { label: keyLabel.value } })));
const revokeKey = (id: string) => run(() => api(`/account/s3-keys/${id}`, { method: 'DELETE' }), 'Key revoked');
const rotateKey = (id: string) => run(async () => (newKey.value = await api(`/account/s3-keys/${id}/rotate`, { method: 'POST' })));
const addUser = () =>
  run(async () => {
    const res = await api<{ temporaryPassword: string }>('/admin/users', { method: 'POST', body: newUser.value });
    created.value = `${newUser.value.username}: temporary password ${res.temporaryPassword}`;
    newUser.value = { username: '', role: 'user' };
  });
const setStatus = (id: string, status: string) => run(() => api(`/admin/users/${id}`, { method: 'PATCH', body: { status } }));
const resetPassword = (id: string, username: string) =>
  run(async () => {
    const res = await api<{ temporaryPassword: string }>(`/admin/users/${id}/reset-password`, { method: 'POST' });
    created.value = `${username}: temporary password ${res.temporaryPassword}`;
  });
const deleteUser = (id: string, username: string) => {
  const typed = prompt(`This deletes ${username} and all of their encrypted notes on this server. Type the username to confirm.`);
  if (typed !== username) return;
  void run(() => api(`/admin/users/${id}`, { method: 'DELETE', body: { confirmUsername: username } }), 'User deleted');
};
const createInvite = () =>
  run(async () => {
    const res = await api<{ token: string }>('/admin/invites', { method: 'POST', body: { role: 'user' } });
    inviteLink.value = `${origin}/#invite=${res.token}`;
  });
const revokeInvite = (id: string) => run(() => api(`/admin/invites/${id}`, { method: 'DELETE' }));
async function forget(): Promise<void> {
  if (!confirm('Sign out and delete the encrypted copy of your notes from this browser? Notes on the server are kept.')) return;
  await signOut(true);
}
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
              <button type="button" class="ni-btn small secondary" @click="saveDeviceName">Save</button>
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
            <form class="form" @submit.prevent="changePassword">
              <label class="ni-field">Current password <input v-model="pw.current" type="password" autocomplete="current-password" required /></label>
              <label class="ni-field">New password <input v-model="pw.next" type="password" autocomplete="new-password" minlength="10" required /></label>
              <button type="submit" class="ni-btn small">Change Password</button>
            </form>
            <div class="row">
              <div class="grow"><div>Sign out everywhere</div><div class="sub">Ends every session of this account, including this one.</div></div>
              <button type="button" class="ni-btn small secondary" @click="run(() => api('/account/logout-everywhere', { method: 'POST' })).then(() => signOut())">Sign Out Everywhere</button>
            </div>
          </section>
        </template>

        <template v-else-if="section === 'account'">
          <div><h2>Account</h2></div>
          <section class="card">
            <div class="row first">
              <div class="grow"><div>Name</div><div class="sub">Signed in as {{ state.session?.user.username }}</div></div>
              <input v-model="displayName" class="ni-input short" maxlength="64" />
              <button type="button" class="ni-btn small secondary" @click="saveDisplayName">Save</button>
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
              <button type="button" class="ni-btn small secondary" @click="rotateKey(k.accessKeyId)">Replace</button>
              <button type="button" class="ni-btn small ghost" @click="revokeKey(k.accessKeyId)">Revoke</button>
            </div>
            <div class="row">
              <input v-model="keyLabel" class="ni-input short" maxlength="64" aria-label="Key label" />
              <button type="button" class="ni-btn small" @click="createKey">Create Key</button>
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
                <button type="button" class="ni-btn small ghost" @click="resetPassword(u.id, u.username)">Reset Password</button>
                <button type="button" class="ni-btn small ghost" @click="setStatus(u.id, u.status === 'active' ? 'disabled' : 'active')">{{ u.status === 'active' ? 'Disable' : 'Enable' }}</button>
                <button type="button" class="ni-btn small ghost" @click="deleteUser(u.id, u.username)">Delete</button>
              </template>
            </div>
          </section>
          <section class="card">
            <h3>Add someone</h3>
            <form class="inline" @submit.prevent="addUser">
              <input v-model="newUser.username" class="ni-input short" placeholder="username" pattern="[a-z0-9][a-z0-9._\-]{1,31}" required aria-label="Username" />
              <select v-model="newUser.role" class="sel" aria-label="Role"><option value="user">User</option><option value="admin">Admin</option></select>
              <button type="submit" class="ni-btn small">Create User</button>
              <button type="button" class="ni-btn small secondary" @click="createInvite">Create Invite Link</button>
            </form>
            <code v-if="created" class="secret">{{ created }}</code>
            <code v-if="inviteLink" class="secret">{{ inviteLink }}</code>
            <div v-for="i in invites.filter((x) => !x.usedAt && !x.revokedAt)" :key="i.id" class="row">
              <div class="grow sub">Invite ({{ i.role }}) · expires {{ new Date(i.expiresAt).toLocaleString() }}</div>
              <button type="button" class="ni-btn small ghost" @click="revokeInvite(i.id)">Revoke</button>
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
