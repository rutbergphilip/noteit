import { computed, reactive, shallowRef, watch } from 'vue';
import { type BodyContainer, dailyNotebook, dailyTitle, dayKey, DAILY_NOTEBOOK_NAME, emptyContainer, expandTemplate, findDailyNote, parseQuery, type Snippet, TEMPLATES_NOTEBOOK_NAME, type TextRange } from '@noteit/doc';
import { serverInfo, session as sessionAction, signOut as signOutAction } from '#safe-action/actions';
import { failureOf, type ServerInfo, type SessionInfo } from '~/utils/actions';
import { templateTarget } from '~/utils/notebooks';
import { OIDC_ERRORS, type OidcErrorCode } from '#shared/oidc';
import { createWorkerClient } from '~/utils/workerClient';
import type { NoteRow, NotebookRow, SmartFolderRow, SyncStatus, UnlockResult } from '~/worker/types';

export type Phase = 'loading' | 'setup' | 'signin' | 'changePassword' | 'unlock' | 'createStore' | 'legacy' | 'ready' | 'serverDown';
export type View =
  | { kind: 'all' }
  | { kind: 'pinned' }
  | { kind: 'recent' }
  | { kind: 'trash' }
  | { kind: 'tasks' }
  | { kind: 'notebook'; id: string }
  | { kind: 'smartFolder'; id: string }
  | { kind: 'tag'; tag: string };
export type InspectorTab = 'links' | 'outline' | 'info';
export type Theme = 'system' | 'light' | 'dark';

export interface Notice {
  title: string;
  description?: string;
  tone?: 'info' | 'success' | 'error';
  action?: { label: string; run: () => void | Promise<void> };
}

/** Set by app.vue from Nuxt UI's useToast(), which needs a component setup to resolve. */
let notifier: ((notice: Notice) => void) | undefined;
export function setNotifier(fn: (notice: Notice) => void): void {
  notifier = fn;
}

const state = reactive({
  phase: 'loading' as Phase,
  server: undefined as ServerInfo | undefined,
  session: undefined as SessionInfo | undefined,
  deviceName: '',
  hasCache: false,
  notes: [] as NoteRow[],
  notebooks: [] as NotebookRow[],
  smartFolders: [] as SmartFolderRow[],
  /** Notes the open smart folder's search finds (evaluated in the worker). */
  smartHits: undefined as Set<string> | undefined,
  /** New Smart Folder… / Edit: the dialog's subject. */
  smartFolderDialog: undefined as undefined | { mode: 'create'; query?: string } | { mode: 'edit'; id: string },
  status: { phase: 'locked', recordErrors: [], pending: 0 } as SyncStatus,
  view: { kind: 'all' } as View,
  selectedId: undefined as string | undefined,
  query: '',
  searchHits: undefined as Set<string> | undefined,
  /** Best Match position of each hit while the search has words (native SearchRanker). */
  searchRank: undefined as Map<string, number> | undefined,
  /** Problems in the search query (an unknown filter is searched as a word, as on the Mac). */
  searchIssues: [] as string[],
  /** Title highlights and body snippets of the search hits (native SearchResult), by note id. */
  searchDecorations: {} as Record<string, { title: TextRange[]; snippet?: Snippet }>,
  /** The Links and Outline panel (native ⌥⌘I), with its Info tab (⌃⌘I). */
  inspector: { open: false, tab: 'links' as InspectorTab },
  /** New Note from Template… or Insert Template…. */
  templatePicker: undefined as undefined | 'new' | 'insert',
  /** An expanded template for the open editor to insert at the caret. */
  pendingInsert: undefined as BodyContainer | undefined,
  /** The find bar in the open note (⌥⌘F, ⇧⌘F with replace); `seq` refocuses it. */
  find: { open: false, replace: false, seq: 0 },
  /** Set Due Date… (⇧⌘D): bumped to ask the open editor for its picker. */
  dueDate: 0,
  /** Add Reminder… (⌃⌘R): likewise. */
  addReminder: 0,
  /** Daily Note for Date…: the picker is open. */
  dailyPicker: false,
  /** Rename Tag… for this tag. */
  tagRename: undefined as string | undefined,
  /** Link to Note… (⇧⌘K): bumped to ask the open editor to start a `[[` link. */
  linkToNote: 0,
  sort: 'edited' as 'edited' | 'created' | 'title',
  /** Mirrors Nuxt UI's color mode (app.vue keeps the two in step; it persists the choice). */
  theme: 'system' as Theme,
  /** Phone/tablet: which pane is shown. */
  pane: 'list' as 'list' | 'editor',
  drawerOpen: false,
  palette: false,
  capture: false,
  notebookDialog: undefined as undefined | { mode: 'create'; parent?: string } | { mode: 'edit'; id: string },
  settings: false,
  /** An invite token from the URL (#invite=…), read at boot and on every hash change. */
  inviteToken: '',
  /** The temporary password just used to sign in, kept in memory so the forced change doesn't ask for it again. */
  temporaryPassword: undefined as string | undefined,
  /** Why the last single sign-on didn't work (the callback names it in the URL fragment). */
  oidcError: undefined as string | undefined,
});

/** The OIDC callback's outcome (`#oidc-error=<code>`, `#oidc-linked`), read once and removed from the address. */
function readOidcFromHash(): void {
  const params = new URLSearchParams(location.hash.replace(/^#/, ''));
  const code = params.get('oidc-error');
  if (code === null && !params.has('oidc-linked')) return;
  window.history.replaceState(null, '', location.pathname + location.search);
  if (code !== null) state.oidcError = OIDC_ERRORS[code as OidcErrorCode] ?? OIDC_ERRORS.failed;
  else toast(`Linked. You can now sign in with ${state.server?.auth.oidc?.label ?? 'single sign-on'}.`, 'success');
}

function readInviteFromHash(): void {
  const token = new URLSearchParams(location.hash.replace(/^#/, '')).get('invite') ?? '';
  if (!token) return;
  state.inviteToken = token;
  // An invite opened in a tab that's already signed in: the link is for a new account.
  if (state.session && state.phase !== 'signin') toast('This invite link is for creating a new account. Sign out first to use it.');
}
if (typeof window !== 'undefined') window.addEventListener('hashchange', readInviteFromHash);

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
  state.smartFolders = snap.smartFolders;
  if (state.query) setHits(await client().search(state.query));
  await refreshSmartHits();
}

function toast(message: string, tone: Notice['tone'] = 'info', action?: Notice['action']): void {
  notifier?.({ title: message, tone, ...(action ? { action } : {}) });
}

/** Moves a note to Recently Deleted, with Undo in the toast (native ⌘Z after a deletion). */
async function trashNote(id: string): Promise<void> {
  await client().updateNoteMeta(id, { trashed: true });
  if (state.selectedId === id) {
    state.selectedId = undefined;
    state.pane = 'list';
  }
  toast('Moved to Recently Deleted', 'info', {
    label: 'Undo',
    run: async () => {
      await client().updateNoteMeta(id, { trashed: false });
      await refresh();
      openNote(id);
    },
  });
}

/** Where the SPA starts: server info, then the session (null when signed out), then the account's next step. */
async function boot(): Promise<void> {
  readInviteFromHash();
  const info = await useAction(serverInfo).executeAsync(undefined);
  if (!info.data) {
    state.phase = 'serverDown';
    return;
  }
  state.server = info.data;
  readOidcFromHash();
  if (info.data.needsSetup) {
    state.phase = 'setup';
    return;
  }
  const current = await useAction(sessionAction).executeAsync(undefined);
  if (failureOf(current)) {
    state.phase = 'serverDown';
    return;
  }
  await enter(current.data ?? undefined);
}

/** After boot, sign-in, setup or an invite: the session the action returned decides the next screen. */
async function enter(session: SessionInfo | undefined): Promise<void> {
  state.session = session;
  if (!session) {
    state.phase = 'signin';
    return;
  }
  if (session.user.mustChangePassword) {
    state.phase = 'changePassword';
    return;
  }
  const init = await client().init({ userId: session.user.id, baseUrl: location.origin });
  state.deviceName = init.deviceName;
  state.hasCache = init.hasCache;
  state.phase = init.hasStore === false && !init.hasCache ? 'createStore' : 'unlock';
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
  await useAction(signOutAction).executeAsync(undefined);
  state.session = undefined;
  state.notes = [];
  state.notebooks = [];
  state.selectedId = undefined;
  state.phase = 'signin';
}

function setTheme(t: Theme): void {
  state.theme = t;
}

async function setQuery(q: string): Promise<void> {
  state.query = q;
  state.searchIssues = q.trim() ? parseQuery(q).issues.map((i) => i.message) : [];
  setHits(q.trim() ? await client().search(q) : undefined);
}

function setHits(ids: string[] | undefined): void {
  state.searchHits = ids ? new Set(ids) : undefined;
  state.searchRank = ids && state.query && parseQuery(state.query).hasTextTerms ? new Map(ids.map((id, i) => [id, i])) : undefined;
  const query = state.query;
  if (!ids || !query.trim()) state.searchDecorations = {};
  else void client().searchDecorations(query, ids).then((d) => state.query === query && (state.searchDecorations = d));
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
  if (v.kind === 'smartFolder') notes = state.smartHits ? notes.filter((n) => state.smartHits!.has(n.id)) : [];
  if (state.searchHits) notes = notes.filter((n) => state.searchHits!.has(n.id));
  const by = state.sort;
  // Searching for words lists Best Match first, as on the Mac (the other orders stay as picked).
  const rank = by === 'edited' ? state.searchRank : undefined;
  if (rank) return [...notes].sort((a, b) => (rank.get(a.id) ?? 1e9) - (rank.get(b.id) ?? 1e9));
  return [...notes].sort((a, b) => {
    if (v.kind !== 'trash' && a.isPinned !== b.isPinned) return a.isPinned ? -1 : 1;
    if (by === 'title') return (a.title || 'Untitled').localeCompare(b.title || 'Untitled');
    const key = by === 'created' ? 'createdAt' : 'updatedAt';
    return Date.parse(b[key]) - Date.parse(a[key]);
  });
});

/** The open smart folder's notes: its saved search, run like a typed one (native SmartFolder). */
async function refreshSmartHits(): Promise<void> {
  const v = state.view;
  const folder = v.kind === 'smartFolder' ? state.smartFolders.find((f) => f.id === v.id) : undefined;
  state.smartHits = folder ? new Set(await client().search(folder.query)) : undefined;
}
watch(
  () => state.view,
  () => void refreshSmartHits(),
);

// Go Back / Go Forward (native ⌃⌘← ⌃⌘→): the notes opened in this tab, like a browser's history.
const history = reactive({ back: [] as string[], forward: [] as string[] });
let travelling = false;
watch(
  () => state.selectedId,
  (id, before) => {
    if (travelling || !before || id === before) return;
    history.back.push(before);
    if (history.back.length > 100) history.back.shift();
    history.forward = [];
  },
  { flush: 'sync' },
);
function travel(dir: 'back' | 'forward'): void {
  const from = dir === 'back' ? history.back : history.forward;
  const to = dir === 'back' ? history.forward : history.back;
  let id = from.pop();
  while (id && !state.notes.some((n) => n.id === id)) id = from.pop();
  if (!id) return;
  if (state.selectedId) to.push(state.selectedId);
  travelling = true;
  openNote(id);
  travelling = false;
}
const canGoBack = () => history.back.some((id) => state.notes.some((n) => n.id === id));
const canGoForward = () => history.forward.some((id) => state.notes.some((n) => n.id === id));

// Choosing another notebook, tag or list closes a note that isn't in it, rather than leaving it open beside a list
// that doesn't show it.
watch(
  () => state.view,
  () => {
    if (state.view.kind === 'smartFolder') return;
    if (state.selectedId && !visibleNotes.value.some((n) => n.id === state.selectedId)) {
      state.selectedId = undefined;
      state.pane = 'list';
    }
  },
);

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

/** `notebookID` null files the note in no notebook; undefined uses the open notebook, as ⌘N does. */
async function createNote(container?: BodyContainer, notebookID?: string | null): Promise<string> {
  const target = notebookID === null ? undefined : (notebookID ?? (state.view.kind === 'notebook' ? state.view.id : undefined));
  // A blank note in a notebook with a default template starts from it, as on the Mac.
  const template = !container && target ? state.notebooks.find((n) => n.id === target)?.defaultTemplateID : undefined;
  if (template && state.notes.some((n) => n.id.toUpperCase() === template.toUpperCase() && !n.deletedAt)) {
    const row = state.notes.find((n) => n.id.toUpperCase() === template.toUpperCase())!;
    container = await expandedTemplate(row.id, '');
  }
  const id = await client().createNote({ ...(target ? { notebookID: target } : {}), ...(container ? { container } : {}) });
  if (state.view.kind === 'trash' || state.view.kind === 'tag' || state.view.kind === 'tasks') state.view = { kind: 'all' };
  if (state.query) await setQuery('');
  await refresh();
  state.selectedId = id;
  state.pane = 'editor';
  return id;
}

function openNote(id: string): void {
  const row = state.notes.find((n) => n.id === id);
  if (row?.deletedAt && state.view.kind !== 'trash') state.view = { kind: 'trash' };
  else if (row && !row.deletedAt && state.view.kind === 'tasks') state.view = { kind: 'all' };
  state.selectedId = id;
  state.pane = 'editor';
}

/** The notebook named "Templates" (native's fallback when its per-Mac preference isn't set). */
const templatesNotebook = computed(() => state.notebooks.find((n) => n.name.trim().toLowerCase() === TEMPLATES_NOTEBOOK_NAME.toLowerCase()));
const templates = computed(() => {
  const nb = templatesNotebook.value;
  return nb ? state.notes.filter((n) => n.notebookID === nb.id && !n.deletedAt && n.kind === 'doc') : [];
});

/** Fills a template in; `undefined` when it can't be read here. */
async function expandedTemplate(templateId: string, title: string): Promise<BodyContainer | undefined> {
  const opened = await client().getNote(templateId);
  if (!opened?.container || opened.readOnly) return undefined;
  let clipboard = '';
  // Only a template that uses {{clipboard}} asks for it (the browser may prompt); no answer in 5 s leaves it empty,
  // as for the Local API on the Mac.
  if (/\{\{clipboard\}\}/i.test(JSON.stringify(opened.container.doc))) {
    try {
      clipboard = await Promise.race([navigator.clipboard.readText(), new Promise<string>((resolve) => setTimeout(() => resolve(''), 5000))]);
    } catch {
      clipboard = '';
    }
  }
  const { doc } = expandTemplate(opened.container.doc, { title, date: new Date(), clipboard });
  return { ...opened.container, doc, attachments: { ...opened.container.attachments } };
}

async function newFromTemplate(templateId: string, title = ''): Promise<void> {
  const container = await expandedTemplate(templateId, title);
  if (!container) return toast("This template can't be read here.", 'error');
  const target = templateTarget(state.view, templatesNotebook.value?.id);
  // Leaving the Templates notebook: the new note is listed in All Notes, as on the Mac.
  if (target === null && state.view.kind === 'notebook') state.view = { kind: 'all' };
  await createNote(container, target);
}

async function newTemplate(): Promise<void> {
  let nb = templatesNotebook.value?.id;
  if (!nb) {
    nb = await client().createNotebook({ name: TEMPLATES_NOTEBOOK_NAME, colorHex: '#8E8E93', symbol: 'doc.on.doc' });
    await refresh();
  }
  state.view = { kind: 'notebook', id: nb };
  await createNote(undefined, nb);
}

/** Today's note in "Daily Notes", created (titled yyyy-MM-dd, native's default) the first time. */
async function openToday(): Promise<void> {
  return openDaily(new Date());
}

/** The daily note for a day (Daily Note for Date…, and ‹ › between days), created the first time. */
async function openDaily(date: Date): Promise<void> {
  const day = dayKey(date);
  let nb = dailyNotebook(state.notebooks, state.notes);
  const existing = nb ? findDailyNote(state.notes, nb, day) : undefined;
  if (existing) return openNote(existing);
  if (!nb) {
    nb = await client().createNotebook({ name: DAILY_NOTEBOOK_NAME, colorHex: '#007AFF', symbol: 'calendar' });
    await refresh();
  }
  const container = emptyContainer();
  container.doc = { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: dailyTitle(day) }] }, { type: 'paragraph' }] };
  await createNote(container, nb);
}

export function useNoteit() {
  return {
    state,
    client,
    boot,
    enter,
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
    trashNote,
    goBack: () => travel('back'),
    goForward: () => travel('forward'),
    canGoBack,
    canGoForward,
    descendants,
    openNote,
    templates,
    templatesNotebook,
    newFromTemplate,
    newTemplate,
    expandedTemplate,
    openToday,
    openDaily,
  };
}
