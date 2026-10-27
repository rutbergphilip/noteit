<script setup lang="ts">
import { computed, ref, useTemplateRef, watch } from 'vue';
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
  accountOidcUnlink,
  oidcStart,
  session,
} from '#safe-action/actions';
import { changePasswordInput, createUserInput } from '#shared/schemas';
import { useConfirm } from '~/lib/confirm';
import { useNoteit } from '~/composables/useNoteit';
import { failureOf, unwrap } from '~/utils/actions';
import { formatBytes, formatDateTime, relativeTime } from '~/utils/format';
import { askNotificationPermission, notificationsSupported } from '~/utils/reminders';
import type { DeviceView } from '~/worker/types';
import { useOpeningKey } from '~/utils/overlay';
import { linkRenameMode, setLinkRenameMode, type LinkRenameMode } from '~/composables/useRenameTracker';
import { CODE_THEMES, codeStyle, setCodeStyle, type CodeThemeId } from '~/utils/codeStyle';
import { CLEANUP, cleanupButtonState, cleanupResultText } from '~/utils/cleanup';

const { state, client, setTheme, lock, signOut, toast, boot } = useNoteit();
const confirm = useConfirm();
type Section = 'general' | 'shortcuts' | 'sync' | 'security' | 'account' | 'users' | 'about';
const section = ref<Section>('sync');
const isAdmin = computed(() => state.session?.user.role === 'admin');
const sections = computed(() => [
  { id: 'general' as const, label: 'General', icon: 'i-lucide-settings' },
  { id: 'shortcuts' as const, label: 'Shortcuts', icon: 'i-lucide-keyboard' },
  { id: 'sync' as const, label: 'Sync & storage', icon: 'i-lucide-refresh-cw' },
  { id: 'security' as const, label: 'Security & devices', icon: 'i-lucide-shield' },
  { id: 'account' as const, label: 'Account', icon: 'i-lucide-user-round' },
  ...(isAdmin.value ? [{ id: 'users' as const, label: 'Users', icon: 'i-lucide-users', admin: true }] : []),
  { id: 'about' as const, label: 'About NoteIt', icon: 'i-lucide-info' },
]);
const origin = location.origin;
const noteCount = computed(() => state.notes.filter((n) => !n.deletedAt).length);

/** Every failed call surfaces as a toast; an expired session goes back through boot to the sign-in screen. */
function report(error: Parameters<typeof failureOf>[0]): void {
  const f = failureOf(error);
  if (!f) return;
  if (f.code === 'unauthorized') void boot();
  toast(f.message, 'error');
}

// MARK: queries. GET actions read through Nuxt's useAsyncData; each key is tagged so a mutation can name
// what it changed (`invalidate: { tags }`) instead of every caller refetching by hand.

const queries = {
  session: useAction(session),
  keys: useAction(accountS3Keys),
  users: useAction(adminUsers),
  invites: useAction(adminInvites),
};
const { data: keys, status: keysStatus } = useAsyncData('settings:s3-keys', async () => unwrap(await queries.keys.executeAsync(undefined)), { default: () => [] });
useActionQueryTags('settings:s3-keys', ['s3-keys']);
const { data: users, status: usersStatus } = useAsyncData('settings:users', async () => (isAdmin.value ? unwrap(await queries.users.executeAsync(undefined)).users : []), { default: () => [] });
useActionQueryTags('settings:users', ['users']);
const { data: invites } = useAsyncData('settings:invites', async () => (isAdmin.value ? unwrap(await queries.invites.executeAsync(undefined)) : []), { default: () => [] });
useActionQueryTags('settings:invites', ['invites']);

const devices = ref<DeviceView[]>([]);
// "Clean Up Unused Storage…" (spec §3.4.9): only after the confirmation, never automatically.
const cleanupAvailable = ref(false);
const cleanupBusy = ref(false);
const cleanupResult = ref<string>();
const cleanup = computed(() => cleanupButtonState(state.status.phase !== 'locked' && !!state.status.lastSync, cleanupAvailable.value));
async function confirmCleanup(): Promise<void> {
  const ok = await confirm({ title: CLEANUP.title, description: CLEANUP.message, confirmLabel: CLEANUP.confirm, danger: true, cancelDefault: true });
  if (!ok) return;
  cleanupBusy.value = true;
  try {
    cleanupResult.value = cleanupResultText(await client().cleanUpUnusedStorage());
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    cleanupResult.value = message.startsWith('cleanupUnavailable') ? CLEANUP.unavailableCaption : `Couldn’t clean up: ${message}`;
  } finally {
    cleanupBusy.value = false;
  }
}
async function loadSync(): Promise<void> {
  cleanupResult.value = undefined;
  void client()
    .cleanupAvailable()
    .then((v) => (cleanupAvailable.value = v));
  devices.value = await client().devices();
  const s = await queries.session.executeAsync(undefined);
  if (s.data) state.session = s.data;
  else report(s);
}
// Settings is a modal over the notes: refresh what it shows each time it opens.
watch(
  () => state.settings,
  (open) => {
    if (!open) return;
    section.value = 'sync';
    // A secret is shown once, right after it's made; reopening Settings never shows it again.
    newKey.value = undefined;
    profile.values.value.displayName = state.session?.user.displayName ?? '';
    deviceName.value = state.deviceName;
    void loadSync();
    void refreshNuxtData(['settings:s3-keys', 'settings:users', 'settings:invites']);
  },
);
watch(section, (s) => s === 'sync' && loadSync());

// MARK: this browser

const deviceName = ref(state.deviceName);
const savingDevice = ref(false);
async function saveDeviceName(): Promise<void> {
  savingDevice.value = true;
  state.deviceName = await client().setDeviceName(deviceName.value);
  savingDevice.value = false;
  toast('Device name saved', 'success');
}
async function forget(): Promise<void> {
  const ok = await confirm({
    title: 'Forget this browser?',
    description: 'Signs out and deletes the encrypted copy of your notes from this browser. Notes on the server are kept.',
    confirmLabel: 'Sign Out & Forget',
    danger: true,
  });
  if (ok) await signOut(true);
}
// Reminders ring here while NoteIt is open in a tab; one device rings per reminder (claims).
const notifyState = ref<NotificationPermission | 'unsupported'>(notificationsSupported() ? Notification.permission : 'unsupported');
const notifySub = computed(() =>
  notifyState.value === 'granted'
    ? '@remind(…) times show a notification while NoteIt is open in a tab. If several devices are on, only one rings.'
    : notifyState.value === 'denied'
      ? 'Blocked in this browser\'s site settings. Reminders show inside NoteIt instead.'
      : notifyState.value === 'unsupported'
        ? "This browser can't show notifications. Reminders show inside NoteIt instead."
        : 'Let this browser show @remind(…) times as notifications while NoteIt is open in a tab.',
);
async function allowNotifications(): Promise<void> {
  notifyState.value = await askNotificationPermission();
}
// When a note is renamed (native Settings › Editor › Links), kept in this browser.
const renameMode = ref<LinkRenameMode>(linkRenameMode());
const renameModes = [
  { label: 'Ask', value: 'ask' },
  { label: 'Always update links', value: 'always' },
  { label: 'Never update links', value: 'never' },
];
// Code blocks (native Settings › Editor › Code), kept in this browser.
const code = ref(codeStyle());
function changeCode(change: { theme?: CodeThemeId; highlighting?: boolean }): void {
  setCodeStyle(change);
  code.value = codeStyle();
}
function changeRenameMode(v: LinkRenameMode): void {
  renameMode.value = v;
  setLinkRenameMode(v);
}

const themes = [
  { label: 'System', value: 'system' },
  { label: 'Light', value: 'light' },
  { label: 'Dark', value: 'dark' },
];

// MARK: account

const profile = useFormAction(accountUpdateProfile, {
  initialValues: { displayName: state.session?.user.displayName ?? '' },
  // The Users list shows display names: a rename refreshes it.
  invalidate: { tags: ['users'] },
  onSuccess: ({ data }) => {
    state.session = data;
    toast('Name saved', 'success');
  },
  onError: ({ error }) => report(error),
});
const password = useFormAction(accountChangePassword, {
  initialValues: { current: '', next: '' },
  clientSchema: changePasswordInput,
  onSuccess: () => {
    password.reset();
    toast('Password changed. Other browsers are signed out.', 'success');
  },
  onError: ({ error }) => error.serverError && report(error),
});
// Sign-in methods (spec §7.2): link one OIDC identity; unlinking needs a password on the account.
const sso = computed(() => state.server?.auth.oidc ?? undefined);
const passwordOn = computed(() => state.server?.auth.password !== false);
const linkSso = useAction(oidcStart, { onSuccess: ({ data }) => data && location.assign(data.url), onError: ({ error }) => report(error) });
const unlinkSso = useAction(accountOidcUnlink, {
  onSuccess: ({ data }) => {
    if (state.session && data) state.session.user = data;
    toast('Sign-in unlinked', 'success');
  },
  onError: ({ error }) => report(error),
});
async function confirmUnlink(): Promise<void> {
  const ok = await confirm({ title: `Unlink ${sso.value?.label}?`, description: 'You sign in with your username and password afterwards.', confirmLabel: 'Unlink', danger: true });
  if (ok) unlinkSso.execute(undefined);
}
const signOutEverywhere = useAction(accountSignOutEverywhere, { onSuccess: () => signOut(), onError: ({ error }) => report(error) });

const keyLabel = ref('Mac');
const newKey = ref<{ accessKeyId: string; secretAccessKey: string }>();
const keyMutation = { invalidate: { tags: ['s3-keys'] }, onError: ({ error }: { error: Parameters<typeof failureOf>[0] }) => report(error) };
const createKey = useAction(accountCreateS3Key, { ...keyMutation, onSuccess: ({ data }) => (newKey.value = data) });
const rotateKey = useAction(accountRotateS3Key, { ...keyMutation, onSuccess: ({ data }) => (newKey.value = data) });
const revokeKey = useAction(accountRevokeS3Key, {
  ...keyMutation,
  onSuccess: ({ input }) => {
    if (newKey.value?.accessKeyId === input.accessKeyId) newKey.value = undefined;
    toast('Key revoked', 'success');
  },
});
async function confirmRevoke(accessKeyId: string, label: string): Promise<void> {
  const ok = await confirm({ title: `Revoke ${label}?`, description: 'Apps using this key stop syncing until they get a new one.', confirmLabel: 'Revoke Key', danger: true });
  if (ok) revokeKey.execute({ accessKeyId });
}

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
    // Not reset(): it cancels the execution, which also skips this mutation's `invalidate` refresh.
    addUser.values.value.username = '';
  },
  onError: ({ error }) => error.serverError && report(error),
});
const updateUser = useAction(adminUpdateUser, userMutation);
const resetPassword = useAction(adminResetPassword, {
  ...userMutation,
  onSuccess: ({ data, input }) => (created.value = `${users.value.find((u) => u.id === input.id)?.username}: temporary password ${data.temporaryPassword}`),
});
const removeUser = useAction(adminDeleteUser, { ...userMutation, onSuccess: () => toast('User deleted', 'success') });
async function deleteUser(id: string, username: string): Promise<void> {
  const ok = await confirm({
    title: `Delete ${username}?`,
    description: `This deletes ${username} and all of their encrypted notes on this server.`,
    confirmLabel: 'Delete User',
    danger: true,
    typeToConfirm: username,
  });
  if (ok) removeUser.execute({ id, confirmUsername: username });
}
const userMenu = (u: { id: string; username: string; status: string }) => [
  [
    { label: 'Reset Password', icon: 'i-lucide-key-round', onSelect: () => resetPassword.execute({ id: u.id }) },
    { label: u.status === 'active' ? 'Disable' : 'Enable', icon: u.status === 'active' ? 'i-lucide-user-x' : 'i-lucide-user-check', onSelect: () => updateUser.execute({ id: u.id, status: u.status === 'active' ? 'disabled' : 'active' }) },
  ],
  [{ label: 'Delete…', icon: 'i-lucide-trash-2', color: 'error' as const, onSelect: () => void deleteUser(u.id, u.username) }],
];
const inviteMutation = { invalidate: { tags: ['invites'] }, onError: ({ error }: { error: Parameters<typeof failureOf>[0] }) => report(error) };
const createInvite = useAction(adminCreateInvite, { ...inviteMutation, onSuccess: ({ data }) => (inviteLink.value = `${origin}/#invite=${data.token}`) });
const revokeInvite = useAction(adminRevokeInvite, inviteMutation);

useActionFormErrors(useTemplateRef('passwordForm'), password.fieldErrors);
useActionFormErrors(useTemplateRef('profileForm'), profile.fieldErrors);
useActionFormErrors(useTemplateRef('addUserForm'), addUser.fieldErrors);
const passwordValues = password.values;
const profileValues = profile.values;
const addUserValues = addUser.values;
const roles = [
  { label: 'User', value: 'user' },
  { label: 'Admin', value: 'admin' },
];
// A fresh portal per opening, so it shows above the sidebar drawer (see useOpeningKey).
const portalKey = useOpeningKey(() => state.settings);
</script>

<template>
  <!-- design p09 / p15 -->
  <UModal
    :key="portalKey"
    v-model:open="state.settings"
    title="Settings"
    description="NoteIt settings"
    :ui="{ content: 'sm:max-w-5xl h-dvh sm:h-[min(88dvh,800px)] max-sm:max-w-none max-sm:rounded-none overflow-hidden' }"
  >
    <template #content>
      <div class="flex h-full min-h-0 flex-col bg-(--page) sm:flex-row">
        <nav class="flex flex-none gap-0.5 border-default bg-default p-3 max-sm:overflow-x-auto max-sm:border-b sm:w-60 sm:flex-col sm:border-e" aria-label="Settings sections">
          <div class="flex items-center justify-between px-2 pb-2 max-sm:hidden">
            <h2 class="text-[17px] font-bold">Settings</h2>
          </div>
          <template v-for="sec in sections" :key="sec.id">
            <div v-if="'admin' in sec" class="px-2.5 pt-3 pb-1 text-[11px] font-semibold text-muted max-sm:hidden">Server admin</div>
            <UButton
              color="neutral"
              variant="ghost"
              :icon="sec.icon"
              :label="sec.label"
              class="flex-none justify-start font-normal"
              :class="section === sec.id ? 'bg-(--sel) font-medium hover:bg-(--sel)' : 'text-default'"
              :aria-current="section === sec.id ? 'page' : undefined"
              @click="section = sec.id"
            />
          </template>
          <UButton color="neutral" variant="ghost" icon="i-lucide-x" aria-label="Close settings" class="ms-auto flex-none sm:hidden" @click="state.settings = false" />
        </nav>

        <main class="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto p-4 sm:p-6">
          <UButton color="neutral" variant="ghost" icon="i-lucide-x" aria-label="Close settings" class="absolute end-3 top-3 max-sm:hidden" @click="state.settings = false" />

          <template v-if="section === 'general'">
            <h2 class="text-xl font-bold">General</h2>
            <SettingsCard title="Appearance">
              <SettingsRow label="Theme" sub="Follows your system unless you pick one.">
                <USelect :model-value="state.theme" :items="themes" class="w-36" aria-label="Theme" @update:model-value="(t) => setTheme(t as 'system' | 'light' | 'dark')" />
              </SettingsRow>
            </SettingsCard>
            <SettingsCard title="Code blocks">
              <SettingsRow label="Syntax highlighting" sub="Colours code by language, set from the code block or guessed.">
                <USwitch :model-value="code.highlighting" aria-label="Syntax highlighting" @update:model-value="(v) => changeCode({ highlighting: !!v })" />
              </SettingsRow>
              <SettingsRow label="Theme">
                <USelect :model-value="code.theme" :items="[...CODE_THEMES]" class="w-36" aria-label="Code block theme" :disabled="!code.highlighting" @update:model-value="(v) => changeCode({ theme: v as CodeThemeId })" />
              </SettingsRow>
            </SettingsCard>
            <SettingsCard title="This browser">
              <SettingsRow label="Device name" sub="Shown in conflict copies on your other devices.">
                <form class="flex gap-2" @submit.prevent="saveDeviceName">
                  <UInput v-model="deviceName" maxlength="64" aria-label="Device name" class="w-48" />
                  <UButton type="submit" color="neutral" variant="outline" label="Save" :loading="savingDevice" />
                </form>
              </SettingsRow>
              <SettingsRow label="Reminder notifications" :sub="notifySub">
                <UButton v-if="notifyState === 'default'" color="neutral" variant="outline" label="Allow" @click="allowNotifications" />
              </SettingsRow>
              <SettingsRow label="When a note is renamed" sub="Update the text of links to it that still show the old title.">
                <USelect :model-value="renameMode" :items="renameModes" class="w-52" aria-label="When a note is renamed" @update:model-value="(v) => changeRenameMode(v as LinkRenameMode)" />
              </SettingsRow>
            </SettingsCard>
          </template>

          <template v-else-if="section === 'shortcuts'">
            <h2 class="text-xl font-bold">Shortcuts</h2>
            <ShortcutsSettings />
          </template>

          <template v-else-if="section === 'sync'">
            <div>
              <h2 class="text-xl font-bold">Sync &amp; storage</h2>
              <p class="mt-1 text-sm text-muted">Everything is encrypted in this browser before it's uploaded.</p>
            </div>
            <div class="flex flex-wrap items-center gap-4 rounded-xl bg-default p-5 ring ring-default">
              <span class="grid size-11 place-items-center rounded-xl bg-(--sel)"><UIcon name="i-lucide-server" class="size-[22px] text-primary" /></span>
              <div class="min-w-0 flex-1">
                <h3 class="font-semibold">Connected to this server</h3>
                <div class="text-sm text-muted">{{ origin }} · last synced {{ state.status.lastSync ? relativeTime(state.status.lastSync).toLowerCase() : 'not yet' }}</div>
              </div>
              <div class="flex gap-5 text-xs text-muted">
                <div class="flex flex-col"><strong class="text-lg text-default">{{ noteCount }}</strong>notes</div>
                <div v-if="state.session" class="flex flex-col">
                  <strong class="text-lg text-default">{{ formatBytes(state.session.quota.usedBytes) }}</strong>of {{ formatBytes(state.session.quota.limitBytes) }}
                </div>
              </div>
              <UButton icon="i-lucide-refresh-cw" label="Sync Now" :loading="state.status.phase === 'syncing'" @click="client().syncNow()" />
            </div>
            <UProgress v-if="state.session" :model-value="Math.min(100, (state.session.quota.usedBytes / state.session.quota.limitBytes) * 100)" size="sm" aria-label="Storage used" />
            <SettingsCard v-if="state.status.recordErrors.length" :title="`${state.status.recordErrors.length} items will be retried on the next sync`">
              <div v-for="(e, i) in state.status.recordErrors" :key="i" class="py-2 text-sm text-muted">{{ e.message }}</div>
            </SettingsCard>
            <SettingsCard title="Devices using this library">
              <SettingsRow
                v-for="d in devices"
                :key="d.deviceID"
                :label="d.name"
                :sub="`${d.platform === 'web' ? 'NoteIt web' : d.platform === 'mac' ? 'NoteIt for Mac' : 'NoteIt'} · last synced ${relativeTime(d.current && state.status.lastSync ? state.status.lastSync : d.lastSync).toLowerCase()}`"
              >
                <UBadge v-if="d.current" variant="soft" label="This browser" />
              </SettingsRow>
              <div v-if="!devices.length" class="py-3 text-sm text-muted">No devices have synced yet.</div>
            </SettingsCard>
            <SettingsCard title="Storage">
              <SettingsRow :sub="cleanup.caption">
                <template #label><span class="text-xs/normal text-muted">{{ CLEANUP.footnote }}</span></template>
                <UButton color="neutral" variant="outline" :label="CLEANUP.button" :disabled="!cleanup.enabled || cleanupBusy" :loading="cleanupBusy" @click="confirmCleanup" />
              </SettingsRow>
              <div v-if="cleanupResult" class="py-2 text-xs text-muted" role="status">{{ cleanupResult }}</div>
            </SettingsCard>
          </template>

          <template v-else-if="section === 'security'">
            <h2 class="text-xl font-bold">Security &amp; devices</h2>
            <SettingsCard title="This browser">
              <SettingsRow label="Lock NoteIt" sub="Forgets the key in memory. You'll need your passphrase to open your notes again.">
                <UButton color="neutral" variant="outline" icon="i-lucide-lock" label="Lock" @click="lock()" />
              </SettingsRow>
              <SettingsRow label="Sign out & forget this device" sub="Deletes the encrypted offline copy from this browser.">
                <UButton color="error" variant="soft" label="Forget" @click="forget" />
              </SettingsRow>
            </SettingsCard>
            <SettingsCard title="Password" sub="Your password opens your account. Your notes use your separate encryption passphrase, which never reaches the server.">
              <UForm ref="passwordForm" :state="passwordValues" :validate-on="[]" class="grid max-w-xl gap-4 py-3 sm:grid-cols-2" @submit="password.submit()">
                <UFormField label="Current password" name="current">
                  <UInput v-model="passwordValues.current" type="password" autocomplete="current-password" />
                </UFormField>
                <UFormField label="New password" name="next">
                  <UInput v-model="passwordValues.next" type="password" autocomplete="new-password" />
                </UFormField>
                <div><UButton type="submit" label="Change Password" :loading="password.isExecuting.value" /></div>
              </UForm>
              <SettingsRow label="Sign out everywhere" sub="Ends every session of this account, including this one.">
                <UButton color="neutral" variant="outline" icon="i-lucide-log-out" label="Sign Out Everywhere" :loading="signOutEverywhere.isExecuting.value" @click="signOutEverywhere.execute(undefined)" />
              </SettingsRow>
            </SettingsCard>
          </template>

          <template v-else-if="section === 'account'">
            <h2 class="text-xl font-bold">Account</h2>
            <SettingsCard>
              <UForm ref="profileForm" :state="profileValues" :validate-on="[]" class="flex flex-wrap items-end gap-3 py-2" @submit="profile.submit()">
                <UFormField label="Name" name="displayName" :help="`Signed in as ${state.session?.user.username}`" class="min-w-60 flex-1">
                  <UInput v-model="profileValues.displayName" maxlength="64" />
                </UFormField>
                <UButton type="submit" color="neutral" variant="outline" label="Save" :loading="profile.isExecuting.value" class="mb-6" />
              </UForm>
            </SettingsCard>
            <SettingsCard v-if="sso" title="Sign-in methods">
              <SettingsRow v-if="passwordOn" label="Password" :sub="state.session?.user.hasPassword ? 'Change it in Security & devices.' : 'This account has no password.'" />
              <SettingsRow :label="sso.label" :sub="state.session?.user.oidcLinked ? 'Linked. You can sign in with it.' : 'Not linked.'">
                <UButton
                  v-if="state.session?.user.oidcLinked"
                  color="neutral"
                  variant="outline"
                  label="Unlink"
                  :disabled="!state.session?.user.hasPassword || !passwordOn"
                  :title="state.session?.user.hasPassword && passwordOn ? undefined : 'Unlinking needs a password on this account.'"
                  :loading="unlinkSso.isExecuting.value"
                  @click="confirmUnlink"
                />
                <UButton v-else color="neutral" variant="outline" icon="i-lucide-link" :label="`Link ${sso.label}`" :loading="linkSso.isExecuting.value" @click="linkSso.execute({ intent: 'link' })" />
              </SettingsRow>
            </SettingsCard>
            <SettingsCard title="S3 access keys">
              <template #sub>
                For NoteIt on your Mac (Settings → Sync → S3-compatible) or backup tools like rclone. Endpoint <code>{{ origin }}/s3</code>, bucket <code>noteit</code>, region <code>us-east-1</code>, path-style. A key
                opens only your own encrypted store.
              </template>
              <div v-if="keysStatus === 'pending' && !keys.length" class="flex flex-col gap-2 py-3"><USkeleton class="h-10" /><USkeleton class="h-10" /></div>
              <SettingsRow
                v-for="k in keys"
                :key="k.accessKeyId"
                :sub="`Created ${relativeTime(k.createdAt).toLowerCase()}${k.lastUsedAt ? ` · used ${relativeTime(k.lastUsedAt).toLowerCase()}` : ' · never used'}`"
              >
                <template #label>{{ k.label }} <code class="ms-1 text-xs">{{ k.accessKeyId }}</code></template>
                <UButton color="neutral" variant="outline" size="sm" label="Replace" :loading="rotateKey.isExecuting.value" @click="rotateKey.execute({ accessKeyId: k.accessKeyId })" />
                <UButton color="error" variant="ghost" size="sm" label="Revoke" @click="confirmRevoke(k.accessKeyId, k.label)" />
              </SettingsRow>
              <form class="flex gap-2 py-3" @submit.prevent="createKey.execute({ label: keyLabel })">
                <UInput v-model="keyLabel" maxlength="64" aria-label="Key label" placeholder="Label" class="w-48" />
                <UButton type="submit" icon="i-lucide-key-round" label="Create Key" :loading="createKey.isExecuting.value" />
              </form>
              <div v-if="newKey" class="flex flex-col gap-2 pb-3">
                <SecretValue :value="newKey.accessKeyId" label="Access key ID" />
                <SecretValue :value="newKey.secretAccessKey" label="Secret access key" hint="Copy the secret now. It isn't shown again." />
              </div>
            </SettingsCard>
          </template>

          <template v-else-if="section === 'users' && isAdmin">
            <div>
              <h2 class="text-xl font-bold">Users</h2>
              <p class="mt-1 text-sm text-muted">Every person has their own encrypted library and passphrase. Admins can't read anyone's notes.</p>
            </div>
            <SettingsCard>
              <div v-if="usersStatus === 'pending' && !users.length" class="flex flex-col gap-2 py-3"><USkeleton class="h-12" /><USkeleton class="h-12" /></div>
              <SettingsRow
                v-for="u in users"
                :key="u.id"
                :sub="`${formatBytes(u.usedBytes)} of ${formatBytes(u.quotaBytes)} · ${u.objectCount} objects${u.lastSeenAt ? ` · seen ${relativeTime(u.lastSeenAt).toLowerCase()}` : ''}`"
              >
                <template #label>
                  {{ u.displayName }} <span class="text-sm text-muted">@{{ u.username }}</span>
                  <UBadge v-if="u.role === 'admin'" variant="soft" size="sm" class="ms-1" label="Admin" />
                  <UBadge v-if="u.status !== 'active'" color="warning" variant="soft" size="sm" class="ms-1" :label="u.status" />
                </template>
                <UDropdownMenu v-if="u.id !== state.session?.user.id" :items="userMenu(u)" :content="{ align: 'end' }">
                  <UButton color="neutral" variant="ghost" icon="i-lucide-ellipsis" :aria-label="`Actions for ${u.username}`" />
                </UDropdownMenu>
              </SettingsRow>
            </SettingsCard>
            <SettingsCard title="Add someone">
              <UForm ref="addUserForm" :state="addUserValues" :validate-on="[]" class="flex flex-wrap items-start gap-2 py-3" @submit="addUser.submit()">
                <UFormField name="username" class="w-56">
                  <UInput v-model="addUserValues.username" placeholder="username" aria-label="Username" autocapitalize="none" />
                </UFormField>
                <USelect v-model="addUserValues.role" :items="roles" aria-label="Role" class="w-28" />
                <UButton type="submit" icon="i-lucide-user-plus" label="Create User" :loading="addUser.isExecuting.value" />
                <UButton color="neutral" variant="outline" icon="i-lucide-link" label="Create Invite Link" :loading="createInvite.isExecuting.value" @click="createInvite.execute({ role: 'user' })" />
              </UForm>
              <div class="flex flex-col gap-2 pb-3 empty:hidden">
                <SecretValue v-if="created" :value="created" label="New account" hint="Share it privately; they choose their own password on first sign-in." />
                <SecretValue v-if="inviteLink" :value="inviteLink" label="Invite link" hint="Works once and expires in 3 days." />
              </div>
              <SettingsRow v-for="i in invites.filter((x) => !x.usedAt && !x.revokedAt)" :key="i.id" :label="`Invite (${i.role})`" :sub="`Expires ${formatDateTime(i.expiresAt)}`">
                <UButton color="error" variant="ghost" size="sm" label="Revoke" @click="revokeInvite.execute({ id: i.id })" />
              </SettingsRow>
            </SettingsCard>
          </template>

          <template v-else-if="section === 'about'">
            <h2 class="text-xl font-bold">About NoteIt</h2>
            <SettingsCard>
              <div class="flex items-center gap-4 py-3">
                <img src="/noteit-icon.png" alt="" width="48" height="48" />
                <div>
                  <div class="ni-wordmark">Note<span>It</span> web {{ state.server?.version }}</div>
                  <div class="text-sm text-muted">
                    Free software under the AGPL-3.0-or-later.
                    <ULink :to="state.server?.sourceUrl" external target="_blank" rel="noopener noreferrer" class="text-primary">Source code</ULink>
                  </div>
                </div>
              </div>
            </SettingsCard>
          </template>
        </main>
      </div>
    </template>
  </UModal>
</template>
