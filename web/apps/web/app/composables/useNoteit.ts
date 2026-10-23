import { computed, reactive, shallowRef } from 'vue';
import type { BodyContainer } from '@noteit/doc';
import { api, ApiError, type ServerInfo, type SessionInfo } from '~/utils/api';
import { createWorkerClient } from '~/utils/workerClient';
import type { NoteRow, NotebookRow, SyncStatus, UnlockResult } from '~/worker/types';

export type Phase = 'loading' | 'setup' | 'signin' | 'changePassword' | 'unlock' | 'createStore' | 'legacy' | 'ready' | 'serverDown';
export type View = { kind: 'all' } | { kind: 'pinned' } | { kind: 'recent' } | { kind: 'trash' } | { kind: 'notebook'; id: string } | { kind: 'tag'; tag: string };
export type Theme = 'system' | 'light' | 'dark';

const THEME_KEY = 'noteit.theme';

function storedTheme(): Theme {
  try {
    const t = localStorage.getItem(THEME_KEY);
    return t === 'light' || t === 'dark' ? t : 'system';
  } catch {
    return 'system';
  }
}

const state = reactive({
  phase: 'loading' as Phase,
  server: undefined as ServerInfo | undefined,
  session: undefined as SessionInfo | undefined,
  deviceName: '',
  hasCache: false,
  notes: [] as NoteRow[],
  notebooks: [] as NotebookRow[],
  status: { phase: 'locked', recordErrors: [], pending: 0 } as SyncStatus,
  view: { kind: 'all' } as View,
  selectedId: undefined as string | undefined,
  query: '',
  searchHits: undefined as Set<string> | undefined,
  sort: 'edited' as 'edited' | 'created' | 'title',
  theme: storedTheme(),
  /** Phone/tablet: which pane is shown. */
  pane: 'list' as 'list' | 'editor',
  drawerOpen: false,
  palette: false,
  capture: false,
  notebookDialog: undefined as undefined | { mode: 'create'; parent?: string } | { mode: 'edit'; id: string },
  settings: false,
  toast: undefined as string | undefined,
});

const worker = shallowRef<ReturnType<typeof createWorkerClient>>();

function client() {
  if (!worker.value) {
    worker.value = createWorkerClient((e) => {
      if (e.type === 'changed') void refresh();
      else state.status = e.status;
      if (e.type === 'status' && e.status.phase === 'error' && e.status.detail === 'signedOut') void boot();
    });
  }
  return worker.value;
}

async function refresh(): Promise<void> {
  if (state.phase !== 'ready') return;
  const snap = await client().snapshot();
  state.notes = snap.notes;
  state.notebooks = snap.notebooks;
  if (state.query) state.searchHits = new Set(await client().search(state.query));
}

function toast(message: string): void {
  state.toast = message;
  setTimeout(() => {
    if (state.toast === message) state.toast = undefined;
  }, 3500);
}

async function boot(): Promise<void> {
  try {
    state.server = await api<ServerInfo>('/server-info');
  } catch {
    state.phase = 'serverDown';
    return;
  }
  if (state.server.needsSetup) {
    state.phase = 'setup';
    return;
  }
  try {
    state.session = await api<SessionInfo>('/session');
  } catch (e) {
    state.session = undefined;
    state.phase = e instanceof ApiError && e.status === 401 ? 'signin' : 'serverDown';
    return;
  }
  if (state.session.user.mustChangePassword) {
    state.phase = 'changePassword';
    return;
  }
  const init = await client().init({ userId: state.session.user.id, baseUrl: location.origin });
  state.deviceName = init.deviceName;
  state.hasCache = init.hasCache;
  state.phase = 'unlock';
}

async function unlock(passphrase: string, create = false, enter = true): Promise<UnlockResult> {
  const result = await client().unlock({ passphrase, create });
  if (result.status === 'ok') {
    if (enter) {
      state.phase = 'ready';
      await refresh();
    }
  } else if (result.status === 'legacy') state.phase = 'legacy';
  else if (result.status === 'noStore') state.phase = 'createStore';
  return result;
}

async function lock(): Promise<void> {
  await client().lock();
  state.notes = [];
  state.notebooks = [];
  state.selectedId = undefined;
  state.phase = 'unlock';
}

async function signOut(forget = false): Promise<void> {
  if (forget) await client().forgetDevice();
  else await client().lock();
  await api('/logout', { method: 'POST' }).catch(() => undefined);
  state.session = undefined;
  state.notes = [];
  state.notebooks = [];
  state.selectedId = undefined;
  state.phase = 'signin';
}

function setTheme(t: Theme): void {
  state.theme = t;
  try {
    if (t === 'system') localStorage.removeItem(THEME_KEY);
    else localStorage.setItem(THEME_KEY, t);
  } catch {
    // private mode: the choice lasts for this tab only
  }
}

async function setQuery(q: string): Promise<void> {
  state.query = q;
  state.searchHits = q.trim() ? new Set(await client().search(q)) : undefined;
}

const RECENT_DAYS = 7;

const visibleNotes = computed(() => {
  const v = state.view;
  let notes = state.notes.filter((n) => (v.kind === 'trash' ? !!n.deletedAt : !n.deletedAt));
  if (v.kind === 'pinned') notes = notes.filter((n) => n.isPinned);
  if (v.kind === 'recent') notes = notes.filter((n) => Date.now() - Date.parse(n.updatedAt) < RECENT_DAYS * 86_400_000);
  if (v.kind === 'notebook') {
    const ids = new Set([v.id, ...descendants(v.id)]);
    notes = notes.filter((n) => n.notebookID && ids.has(n.notebookID));
  }
  if (v.kind === 'tag') notes = notes.filter((n) => n.tags.some((t) => t === v.tag || t.startsWith(`${v.tag}/`)));
  if (state.searchHits) notes = notes.filter((n) => state.searchHits!.has(n.id));
  const by = state.sort;
  return [...notes].sort((a, b) => {
    if (v.kind !== 'trash' && a.isPinned !== b.isPinned) return a.isPinned ? -1 : 1;
    if (by === 'title') return (a.title || 'Untitled').localeCompare(b.title || 'Untitled');
    const key = by === 'created' ? 'createdAt' : 'updatedAt';
    return Date.parse(b[key]) - Date.parse(a[key]);
  });
});

function descendants(id: string): string[] {
  const out: string[] = [];
  for (const nb of state.notebooks) if (nb.parent === id) out.push(nb.id, ...descendants(nb.id));
  return out;
}

const tags = computed(() => {
  const counts = new Map<string, number>();
  for (const n of state.notes) if (!n.deletedAt) for (const t of n.tags) counts.set(t, (counts.get(t) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([tag, count]) => ({ tag, count }));
});

async function createNote(container?: BodyContainer, notebookID?: string): Promise<string> {
  const target = notebookID ?? (state.view.kind === 'notebook' ? state.view.id : undefined);
  const id = await client().createNote({ ...(target ? { notebookID: target } : {}), ...(container ? { container } : {}) });
  if (state.view.kind === 'trash' || state.view.kind === 'tag') state.view = { kind: 'all' };
  if (state.query) await setQuery('');
  await refresh();
  state.selectedId = id;
  state.pane = 'editor';
  return id;
}

export function useNoteit() {
  return {
    state,
    client,
    boot,
    unlock,
    lock,
    signOut,
    refresh,
    toast,
    setTheme,
    setQuery,
    visibleNotes,
    tags,
    createNote,
    descendants,
  };
}
