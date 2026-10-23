import {
  BODY_FORMAT_DOC_V1,
  BODY_FORMAT_LOCKED_V1,
  type Bytes,
  type CarriedBody,
  decodeNotebookMeta,
  decodeNoteMeta,
  decodeSmartFolderMeta,
  emptySyncState,
  fromUtf8,
  type LocalDeletion,
  type LocalRecord,
  newUuid,
  NOTE_META_OWNED_KEYS,
  NOTEBOOK_META_OWNED_KEYS,
  type NoteMeta,
  type NotebookMeta,
  patchMeta,
  RecordRefused,
  SMART_FOLDER_DEFAULT_SYMBOL,
  SMART_FOLDER_MAX_COUNT,
  SMART_FOLDER_MAX_NAME,
  SMART_FOLDER_MAX_QUERY,
  SMART_FOLDER_META_OWNED_KEYS,
  type SmartFolderMeta,
  type RecordKind,
  RecordDeferred,
  type RecordPayload,
  type SyncCipher,
  type SyncLocalStore,
  type SyncState,
  type SyncStateStore,
  toIsoSeconds,
  utf8,
  type Uuid,
} from '@noteit/core';
import {
  type BodyContainer,
  conflictTitleSuffix,
  decodeBody,
  deriveTags,
  deriveTitleAndPreview,
  emptyContainer,
  encodeBody,
  docTasks,
  type DocTask,
  hasAttachments,
  type LocalDateTime,
  isEmptyQuery,
  matchesQuery,
  noteLinks,
  type NoteLinkRef,
  parseQuery,
  parseTasks,
  maskedText,
  pruneAttachments,
  rankSearch,
  findMentions,
  linkMentions,
  mentionsAreSearched,
  noteLink,
  reminderId,
  renameTagInQuery,
  rewriteTags,
  searchFold,
  type TagEdit,
  tagRenameProblem,
  tagsIn,
  searchableText,
  withConflictSuffix,
} from '@noteit/doc';
import type { StoreName } from './idb';
import type { NoteKind, NoteRow, NotebookRow, SmartFolderRow, Snapshot } from './types';

export interface KeyValue {
  get<T>(store: StoreName, key: string): Promise<T | undefined>;
  all<T>(store: StoreName): Promise<[string, T][]>;
  put(store: StoreName, key: string, value: unknown): Promise<void>;
  delete(store: StoreName, key: string): Promise<void>;
  clear(store: StoreName): Promise<void>;
  /** Atomically increments the library's write generation (kv `generation`); returns the value it replaced. */
  bump(): Promise<number>;
}

/** Runs `fn` while holding the library's write lock (Web Locks across tabs in the browser). */
export type Exclusive = <T>(fn: () => Promise<T>) => Promise<T>;
const unlocked: Exclusive = (fn) => fn();

/** What one record holds once decrypted. Bodies keep the exact bytes the store had (as UTF-8 JSON text). */
interface StoredRecord {
  id: Uuid;
  kind: RecordKind;
  revision: Uuid;
  modifiedAt: number;
  /** The last decrypted (or our own encoded) inner meta JSON: RawMetaOverlay's source. */
  meta: string;
  body?: string;
  bodyFormat?: string;
  carried?: CarriedBody;
  /** The device that wrote this version, when known: the source a conflict copy of it names. */
  writer?: string;
}

interface Derived {
  row: NoteRow;
  /** Folded searchable text (title, body, `#tags`). */
  search: string;
  tasks: DocTask[];
  openDueDates: LocalDateTime[];
  hasLiveReminder: boolean;
  hasAttachment: boolean;
  links: NoteLinkRef[];
}

export const RECENTLY_DELETED_DAYS = 30;

/**
 * The browser's library: every record sealed with the store key under `local/records/<id>` in IndexedDB, with a
 * decrypted copy in memory for listing and search. Implements the engine's SyncLocalStore.
 */
export class WebLocalStore implements SyncLocalStore {
  private records_ = new Map<Uuid, StoredRecord>();
  private derived = new Map<Uuid, Derived>();
  private deletions_ = new Map<Uuid, { kind: RecordKind; deletedAt: number }>();
  /** The write generation the in-memory copy matches; another tab's write moves the stored one on. */
  private generation = -1;
  /** Revisions as of the engine's last records() read (native NoteStoreSyncAdapter's seenRevisions). */
  private seenRevisions = new Map<Uuid, Uuid>();
  onChange: () => void = () => undefined;

  constructor(
    private readonly kv: KeyValue,
    private readonly cipher: SyncCipher,
    private readonly deviceID: string,
    private readonly now: () => Date = () => new Date(),
    private readonly exclusive: Exclusive = unlocked,
    private readonly deviceName: string = 'this browser',
  ) {}

  // MARK: persistence

  private async sealJson(context: string, value: unknown): Promise<Bytes> {
    return this.cipher.seal(utf8(JSON.stringify(value)), context);
  }

  private async openJson<T>(context: string, sealed: Uint8Array): Promise<T> {
    return JSON.parse(fromUtf8(await this.cipher.open(sealed, context))) as T;
  }

  async load(): Promise<void> {
    this.generation = (await this.kv.get<number>('kv', 'generation')) ?? 0;
    this.records_.clear();
    this.derived.clear();
    for (const [id, sealed] of await this.kv.all<Uint8Array>('records')) {
      try {
        const r = await this.openJson<StoredRecord>(`local/records/${id}`, sealed);
        this.records_.set(id, r);
        if (r.kind === 'note') this.derive(r);
      } catch {
        // A record sealed under another key (an old store) is dropped; the next pass pulls it again.
        await this.kv.delete('records', id);
      }
    }
    const sealed = await this.kv.get<Uint8Array>('kv', 'deletions');
    this.deletions_ = new Map(sealed ? Object.entries(await this.openJson<Record<string, { kind: RecordKind; deletedAt: number }>>('local/kv/deletions', sealed)) : []);
  }

  /**
   * Reloads from IndexedDB when another tab wrote since this copy was read. Tabs of the same browser share the
   * library; without this a tab would edit, list and sync a stale copy and overwrite the other tab's writes.
   */
  async ensureFresh(): Promise<boolean> {
    if (((await this.kv.get<number>('kv', 'generation')) ?? 0) === this.generation) return false;
    await this.load();
    return true;
  }

  /** Records one write of ours; a generation that moved meanwhile means another tab wrote too. */
  private async wrote(): Promise<void> {
    const before = await this.kv.bump();
    this.generation = before === this.generation ? before + 1 : -1;
  }

  private async persist(r: StoredRecord): Promise<void> {
    this.records_.set(r.id, r);
    if (r.kind === 'note') this.derive(r);
    await this.kv.put('records', r.id, await this.sealJson(`local/records/${r.id}`, r));
    await this.wrote();
  }

  private async remove(id: Uuid): Promise<void> {
    this.records_.delete(id);
    this.derived.delete(id);
    await this.kv.delete('records', id);
    await this.wrote();
  }

  private async saveDeletions(): Promise<void> {
    await this.kv.put('kv', 'deletions', await this.sealJson('local/kv/deletions', Object.fromEntries(this.deletions_)));
    await this.wrote();
  }

  private derive(r: StoredRecord): void {
    let meta: NoteMeta;
    try {
      meta = decodeNoteMeta(utf8(r.meta));
    } catch {
      return;
    }
    let kind: NoteKind = 'doc';
    let title = meta.title;
    let preview = meta.preview;
    let tags = meta.tags;
    let search = `${meta.title}\n${meta.preview}`;
    let tasks: DocTask[] = [];
    let hasLiveReminder = false;
    let hasAttachment = false;
    let links: NoteLinkRef[] = [];
    if (r.bodyFormat === BODY_FORMAT_LOCKED_V1 || r.carried?.bodyFormat === BODY_FORMAT_LOCKED_V1) {
      kind = 'locked';
      preview = '';
      tags = [];
      search = title;
    } else if (r.body === undefined) {
      kind = 'legacy';
    } else {
      const decoded = decodeBody(utf8(r.body), r.bodyFormat ?? BODY_FORMAT_DOC_V1);
      if (decoded.kind === 'doc') {
        // The receiver re-derives title, preview and tags from the body (spec §2.8).
        const tp = deriveTitleAndPreview(decoded.container.doc);
        title = tp.title;
        preview = tp.preview;
        tags = deriveTags(decoded.container.doc);
        search = searchableText(decoded.container.doc);
        tasks = docTasks(decoded.container.doc);
        hasLiveReminder = parseTasks(maskedText(decoded.container.doc)).reminders.some((r) => !r.done && !(r.isTask && r.checked));
        hasAttachment = hasAttachments(decoded.container.doc);
        links = noteLinks(decoded.container.doc);
      }
    }
    const row: NoteRow = { id: r.id, revision: r.revision, title, preview, tags, isPinned: meta.isPinned, createdAt: meta.createdAt, updatedAt: meta.updatedAt, kind };
    if (meta.notebookID) row.notebookID = meta.notebookID;
    if (meta.deletedAt) row.deletedAt = meta.deletedAt;
    if (meta.conflictSource) row.conflictSource = meta.conflictSource;
    if (meta.conflictOriginalID) row.conflictOriginalID = meta.conflictOriginalID;
    const openDueDates = tasks.flatMap((t) => (!t.checked && t.due ? [t.due] : []));
    this.derived.set(r.id, { row, search: searchFold(`${search}\n${tags.map((t) => `#${t}`).join(' ')}`), tasks, openDueDates, hasLiveReminder, hasAttachment, links });
  }

  // MARK: queries

  snapshot(): Snapshot {
    const notebooks: NotebookRow[] = [];
    for (const r of this.records_.values()) {
      if (r.kind !== 'notebook') continue;
      try {
        const m = decodeNotebookMeta(utf8(r.meta));
        // `defaultTemplateID` (organise: the template new notes here start from) is read from the raw JSON.
        const raw = JSON.parse(r.meta) as { defaultTemplateID?: unknown };
        const template = typeof raw.defaultTemplateID === 'string' ? raw.defaultTemplateID : undefined;
        notebooks.push({ id: m.id, name: m.name, colorHex: m.colorHex, symbol: m.symbol, sortIndex: m.sortIndex, ...(m.parent ? { parent: m.parent } : {}), ...(template ? { defaultTemplateID: template } : {}) });
      } catch {
        // unreadable notebook metas are skipped
      }
    }
    const smartFolders: SmartFolderRow[] = [];
    for (const r of this.records_.values()) {
      if (r.kind !== 'smartFolder') continue;
      try {
        const m = decodeSmartFolderMeta(utf8(r.meta));
        smartFolders.push({ id: m.id, name: m.name, query: m.query, symbol: m.symbol, sortIndex: m.sortIndex });
      } catch {
        // unreadable smart folders are skipped
      }
    }
    return {
      notes: [...this.derived.values()].map((d) => d.row),
      notebooks: notebooks.sort((a, b) => a.sortIndex - b.sortIndex || a.name.localeCompare(b.name)),
      smartFolders: smartFolders.sort((a, b) => a.sortIndex - b.sortIndex || a.name.localeCompare(b.name)),
    };
  }

  /**
   * The search language (`tag:`, `is:todo`, `-word`, `OR` …), evaluated as native `QueryEvaluator` does; with words
   * to look for, the ids come in Best Match order (native SearchRanker).
   */
  search(query: string, now: Date = this.now()): string[] {
    const q = parseQuery(query);
    const notebooks = this.snapshot().notebooks;
    const ctx = { now, notebooks };
    const hits = [...this.derived.values()]
      .filter((d) => {
        if (d.row.deletedAt) return false;
        const open = d.tasks.filter((t) => !t.checked).length;
        return matchesQuery(q, {
          foldedText: d.search,
          foldedTitle: searchFold(d.row.title),
          tags: d.row.tags,
          ...(d.row.notebookID ? { notebookID: d.row.notebookID } : {}),
          isPinned: d.row.isPinned,
          isConflict: !!d.row.conflictSource,
          createdAt: new Date(d.row.createdAt),
          updatedAt: new Date(d.row.updatedAt),
          openTaskCount: open,
          doneTaskCount: d.tasks.length - open,
          openDueDates: d.openDueDates,
          hasLiveReminder: d.hasLiveReminder,
          hasAttachment: d.hasAttachment,
        }, ctx);
      });
    if (!q.hasTextTerms) return hits.map((d) => d.row.id);
    const docs = hits.map((d) => ({ foldedText: d.search, foldedTitle: searchFold(d.row.title), tags: d.row.tags, isPinned: d.row.isPinned, updatedAt: new Date(d.row.updatedAt) }));
    return rankSearch(docs, q, searchFold(query), now).map((i) => hits[i]!.row.id);
  }

  /** Notes that link here (with the line for context), and the notes this one links to. */
  links(id: Uuid): { backlinks: { id: Uuid; title: string; context: string }[]; outgoing: { id?: Uuid; title: string; text: string; exists: boolean }[] } {
    const target = id.toUpperCase();
    const backlinks: { id: Uuid; title: string; context: string }[] = [];
    for (const d of this.derived.values()) {
      if (d.row.id === id || d.row.deletedAt) continue;
      const hit = d.links.find((l) => l.id === target);
      if (hit) backlinks.push({ id: d.row.id, title: d.row.title, context: hit.context });
    }
    const byUpper = new Map([...this.derived.values()].map((d) => [d.row.id.toUpperCase(), d.row]));
    const seen = new Set<string>();
    const outgoing: { id?: Uuid; title: string; text: string; exists: boolean }[] = [];
    for (const l of this.derived.get(id)?.links ?? []) {
      const key = l.id ?? `title:${l.title}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const row = l.id ? byUpper.get(l.id) : [...this.derived.values()].find((d) => !d.row.deletedAt && d.row.title.toLowerCase() === l.title?.toLowerCase())?.row;
      outgoing.push({ ...(row ? { id: row.id } : {}), title: row?.title ?? l.title ?? l.text, text: l.text, exists: !!row && !row.deletedAt });
    }
    return { backlinks: backlinks.sort((a, b) => a.title.localeCompare(b.title)), outgoing };
  }

  /** Live notes that mention this note's title in plain text and don't link to it, newest first (native). */
  unlinkedMentions(id: Uuid): { id: Uuid; title: string; contexts: string[]; count: number }[] {
    const target = this.derived.get(id)?.row;
    if (!target || target.deletedAt || !mentionsAreSearched(target.title)) return [];
    const linking = new Set(this.links(id).backlinks.map((b) => b.id));
    const folded = searchFold(target.title.trim());
    const templates = this.snapshot().notebooks.find((n) => n.name.trim().toLowerCase() === 'templates')?.id;
    const out: { id: Uuid; title: string; contexts: string[]; count: number; updatedAt: string }[] = [];
    for (const d of this.derived.values()) {
      const r = d.row;
      if (r.id === id || r.deletedAt || r.kind !== 'doc' || linking.has(r.id) || (templates && r.notebookID === templates) || !d.search.includes(folded)) continue;
      const doc = this.getNote(r.id)?.container?.doc;
      if (!doc) continue;
      const found = findMentions(doc, target.title);
      if (found.count) out.push({ id: r.id, title: r.title, ...found, updatedAt: r.updatedAt });
    }
    return out.sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt)).map(({ updatedAt: _u, ...m }) => m);
  }

  /** Turns the mentions of `id`'s title in each source into links to it, keeping the text. */
  linkMentions(id: Uuid, sources: Uuid[]): Promise<number> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      const target = this.derived.get(id)?.row;
      if (!target) return 0;
      let changed = 0;
      for (const source of sources) {
        const opened = this.getNote(source);
        if (!opened?.container || opened.readOnly) continue;
        const doc = linkMentions(opened.container.doc, target.title, noteLink(id));
        if (!doc) continue;
        await this.saveNoteLocked(source, { ...opened.container, doc });
        changed += 1;
      }
      return changed;
    });
  }

  /** Every checklist item in live, editable notes (the Tasks view). */
  /**
   * Checklist items from live notes outside the Templates notebook, filtered by `query` (the search language,
   * evaluated against each line as native TaskSearchDocument does).
   */
  tasks(query = '', now: Date = this.now()): { noteId: Uuid; noteTitle: string; block: number; text: string; checked: boolean; due?: LocalDateTime; remind?: LocalDateTime }[] {
    const out: { noteId: Uuid; noteTitle: string; block: number; text: string; checked: boolean; due?: LocalDateTime; remind?: LocalDateTime }[] = [];
    const q = parseQuery(query);
    const notebooks = this.snapshot().notebooks;
    const templates = notebooks.find((n) => n.name.trim().toLowerCase() === 'templates')?.id;
    const ctx = { now, notebooks };
    for (const d of this.derived.values()) {
      if (d.row.deletedAt || d.row.kind !== 'doc' || (templates && d.row.notebookID === templates)) continue;
      for (const t of d.tasks) {
        if (!isEmptyQuery(q)) {
          const doc = {
            foldedText: searchFold(t.text),
            foldedTitle: '',
            tags: [...new Set([...d.row.tags, ...tagsIn(t.text)])],
            ...(d.row.notebookID ? { notebookID: d.row.notebookID } : {}),
            isPinned: d.row.isPinned,
            isConflict: !!d.row.conflictSource,
            createdAt: new Date(d.row.createdAt),
            updatedAt: new Date(d.row.updatedAt),
            openTaskCount: t.checked ? 0 : 1,
            doneTaskCount: t.checked ? 1 : 0,
            openDueDates: !t.checked && t.due ? [t.due] : [],
            hasLiveReminder: !!t.remind && !t.remindDone && !t.checked,
            hasAttachment: d.hasAttachment,
          };
          if (!matchesQuery(q, doc, ctx)) continue;
        }
        out.push({ noteId: d.row.id, noteTitle: d.row.title, block: t.block, text: t.text, checked: t.checked, ...(t.due ? { due: t.due } : {}), ...(t.remind ? { remind: t.remind } : {}) });
      }
    }
    return out;
  }

  /** Reminders that can still ring (native liveReminders): not done, not on a checked task, in live editable notes. */
  liveReminders(): { id: string; noteId: Uuid; noteTitle: string; text: string; at: LocalDateTime }[] {
    const out: { id: string; noteId: Uuid; noteTitle: string; text: string; at: LocalDateTime }[] = [];
    for (const d of this.derived.values()) {
      if (!d.hasLiveReminder || d.row.deletedAt || d.row.kind !== 'doc') continue;
      const doc = this.getNote(d.row.id)?.container?.doc;
      if (!doc) continue;
      for (const r of parseTasks(maskedText(doc)).reminders) {
        if (r.done || (r.isTask && r.checked)) continue;
        out.push({ id: reminderId(d.row.id, r.at, r.text), noteId: d.row.id, noteTitle: d.row.title, text: r.text, at: r.at });
      }
    }
    return out;
  }

  /** Checks or unchecks one checklist item, as a body edit. */
  setTaskChecked(id: Uuid, block: number, checked: boolean): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      const opened = this.getNote(id);
    if (!opened?.container || opened.readOnly) throw new Error('This note is read-only here');
    const b = opened.container.doc.content[block];
    if (b?.type !== 'listItem' || b.attrs.kind !== 'task') throw new Error('That item has changed');
      b.attrs = { ...b.attrs, checked };
      await this.saveNoteLocked(id, opened.container);
    });
  }

  getNote(id: Uuid): { row: NoteRow; container?: BodyContainer; readOnly?: string } | undefined {
    const r = this.records_.get(id);
    const d = this.derived.get(id);
    if (!r || !d) return undefined;
    if (d.row.kind === 'locked') return { row: d.row, readOnly: 'locked' };
    if (d.row.kind === 'legacy' || r.body === undefined) return { row: d.row, readOnly: 'legacy' };
    const decoded = decodeBody(utf8(r.body), r.bodyFormat ?? BODY_FORMAT_DOC_V1);
    if (decoded.kind !== 'doc') return { row: d.row, readOnly: decoded.kind === 'invalid' ? decoded.reason : decoded.kind };
    return { row: d.row, container: decoded.container, ...(decoded.validation === 'valid' ? {} : { readOnly: decoded.validation.readOnly }) };
  }

  pendingCount(bases: Record<string, { revision: string }>): number {
    let n = this.deletions_.size;
    for (const r of this.records_.values()) if (bases[r.id]?.revision !== r.revision) n += 1;
    return n;
  }

  // MARK: local edits (every edit mints a new revision)

  private noteMeta(id: Uuid): NoteMeta {
    const r = this.records_.get(id);
    if (!r || r.kind !== 'note') throw new Error('No such note');
    return decodeNoteMeta(utf8(r.meta));
  }

  private async writeNote(id: Uuid, meta: NoteMeta, body: { container?: BodyContainer; keep?: boolean }): Promise<void> {
    const prev = this.records_.get(id);
    const now = this.now();
    meta.revision = newUuid();
    const r: StoredRecord = {
      id,
      kind: 'note',
      revision: meta.revision,
      modifiedAt: now.getTime(),
      meta: fromUtf8(patchMeta(prev ? utf8(prev.meta) : undefined, meta, NOTE_META_OWNED_KEYS)),
      writer: this.deviceName,
    };
    if (body.container) {
      r.body = fromUtf8(encodeBody(body.container));
      r.bodyFormat = BODY_FORMAT_DOC_V1;
    } else if (prev) {
      if (prev.body !== undefined) r.body = prev.body;
      if (prev.bodyFormat !== undefined) r.bodyFormat = prev.bodyFormat;
      if (prev.carried) r.carried = prev.carried;
    }
    await this.persist(r);
    this.onChange();
  }

  /** A new note; an import passes the source's dates and pin. */
  createNote(opts: { notebookID?: Uuid; container?: BodyContainer; createdAt?: string; updatedAt?: string; isPinned?: boolean } = {}): Promise<Uuid> {
    return this.exclusive(() => this.createNoteLocked(opts));
  }

  private async createNoteLocked(opts: { notebookID?: Uuid; container?: BodyContainer; createdAt?: string; updatedAt?: string; isPinned?: boolean }): Promise<Uuid> {
    const id = newUuid();
    const container = opts.container ?? emptyContainer();
    const now = toIsoSeconds(this.now());
    const { title, preview } = deriveTitleAndPreview(container.doc);
    const createdAt = opts.createdAt ?? now;
    const meta: NoteMeta = { id, title, preview, tags: deriveTags(container.doc), isPinned: !!opts.isPinned, createdAt, updatedAt: opts.updatedAt ?? createdAt };
    if (opts.notebookID) meta.notebookID = opts.notebookID;
    await this.writeNote(id, meta, { container });
    return id;
  }

  /**
   * Saves an edited body; title, preview and tags are derived from it. Conflict markers clear on a body edit.
   *
   * `baseRevision` is the revision the editor started from. When the note moved on since (another tab saved it, or
   * a pull landed while the edit was pending) the version in the library is kept as a conflict copy and the edit
   * becomes the note, as native does for a remote change that arrives during a local edit: nothing is overwritten.
   */
  saveNote(id: Uuid, container: BodyContainer, baseRevision?: Uuid): Promise<{ revision: Uuid; conflictCopy?: Uuid }> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      return this.saveNoteLocked(id, container, baseRevision);
    });
  }

  private async saveNoteLocked(id: Uuid, container: BodyContainer, baseRevision?: Uuid): Promise<{ revision: Uuid; conflictCopy?: Uuid }> {
    const r = this.records_.get(id);
    if (!r || r.body === undefined) throw new Error('This note is read-only here');
    pruneAttachments(container);
    if (fromUtf8(encodeBody(container)) === r.body) return { revision: r.revision };
    let conflictCopy: Uuid | undefined;
    if (baseRevision && baseRevision !== r.revision) {
      const theirs = await this.export(id);
      if (theirs.body) conflictCopy = await this.importConflictCopyLocked(theirs, r.writer ?? this.deviceName);
    }
    const meta = this.noteMeta(id);
    const { title, preview } = deriveTitleAndPreview(container.doc);
    meta.title = title;
    meta.preview = preview;
    meta.tags = deriveTags(container.doc);
    meta.updatedAt = toIsoSeconds(this.now());
    delete meta.conflictSource;
    delete meta.conflictOriginalID;
    await this.writeNote(id, meta, { container });
    return { revision: meta.revision!, ...(conflictCopy ? { conflictCopy } : {}) };
  }

  updateNoteMeta(id: Uuid, change: { isPinned?: boolean; notebookID?: Uuid | null; trashed?: boolean }): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      await this.updateNoteMetaLocked(id, change);
    });
  }

  private async updateNoteMetaLocked(id: Uuid, change: { isPinned?: boolean; notebookID?: Uuid | null; trashed?: boolean }): Promise<void> {
    const meta = this.noteMeta(id);
    if (change.isPinned !== undefined) meta.isPinned = change.isPinned;
    if (change.notebookID !== undefined) {
      if (change.notebookID) meta.notebookID = change.notebookID;
      else delete meta.notebookID;
    }
    if (change.trashed === true) meta.deletedAt = toIsoSeconds(this.now());
    if (change.trashed === false) {
      delete meta.deletedAt;
      // Recovering into a notebook that no longer exists lands in "Inbox", or no notebook.
      if (meta.notebookID && this.records_.get(meta.notebookID)?.kind !== 'notebook') {
        const inbox = this.snapshot().notebooks.find((n) => n.name.toLowerCase() === 'inbox');
        if (inbox) meta.notebookID = inbox.id;
        else delete meta.notebookID;
      }
    }
    await this.writeNote(id, meta, { keep: true });
  }

  deleteForever(id: Uuid): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      await this.deleteForeverLocked(id);
    });
  }

  private async deleteForeverLocked(id: Uuid): Promise<void> {
    const r = this.records_.get(id);
    if (!r) return;
    // Copies of a deleted original lose their conflict markers.
    for (const d of this.derived.values()) {
      if (d.row.conflictOriginalID === id) {
        const meta = this.noteMeta(d.row.id);
        delete meta.conflictSource;
        delete meta.conflictOriginalID;
        await this.writeNote(d.row.id, meta, { keep: true });
      }
    }
    await this.remove(id);
    this.deletions_.set(id, { kind: r.kind, deletedAt: this.now().getTime() });
    await this.saveDeletions();
    this.onChange();
  }

  /** Purges notes that sat in Recently Deleted for 30 days. */
  purgeExpired(): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      const cutoff = this.now().getTime() - RECENTLY_DELETED_DAYS * 86_400_000;
      for (const d of [...this.derived.values()]) {
        if (d.row.deletedAt && Date.parse(d.row.deletedAt) < cutoff) await this.deleteForeverLocked(d.row.id);
      }
    });
  }

  createNotebook(opts: { name: string; colorHex: string; symbol: string; parent?: Uuid }): Promise<Uuid> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      return this.createNotebookLocked(opts);
    });
  }

  private async createNotebookLocked(opts: { name: string; colorHex: string; symbol: string; parent?: Uuid }): Promise<Uuid> {
    const id = newUuid();
    const siblings = this.snapshot().notebooks.filter((n) => (n.parent ?? null) === (opts.parent ?? null));
    const meta: NotebookMeta = { id, name: opts.name, colorHex: opts.colorHex, symbol: opts.symbol, sortIndex: siblings.length, modifiedAt: toIsoSeconds(this.now()), revision: newUuid() };
    // `parent` belongs to organise; it rides along as an extra key through RawMetaOverlay. Native always writes it,
    // `null` at the top level: a record without the key reads as NoteIt 0.2's, and keeps the Mac's local parent.
    const raw = utf8(JSON.stringify({ parent: opts.parent ?? null }));
    await this.persist({ id, kind: 'notebook', revision: meta.revision!, modifiedAt: this.now().getTime(), meta: fromUtf8(patchMeta(raw, meta, NOTEBOOK_META_OWNED_KEYS)) });
    this.onChange();
    return id;
  }

  updateNotebook(id: Uuid, change: { name?: string; colorHex?: string; symbol?: string; parent?: Uuid | null }): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      await this.updateNotebookLocked(id, change);
    });
  }

  private async updateNotebookLocked(id: Uuid, change: { name?: string; colorHex?: string; symbol?: string; parent?: Uuid | null }): Promise<void> {
    const r = this.records_.get(id);
    if (!r || r.kind !== 'notebook') return;
    const meta = decodeNotebookMeta(utf8(r.meta));
    const current = meta.parent ?? null;
    delete meta.parent;
    const { parent, ...fields } = change;
    Object.assign(meta, fields);
    const raw = JSON.parse(r.meta) as Record<string, unknown>;
    raw.parent = current;
    if (parent !== undefined && parent !== current) {
      if (parent !== null && (parent === id || this.notebookAncestors(parent).includes(id))) throw new Error("A notebook can't go inside itself");
      raw.parent = parent;
      // Moved: last among its new siblings.
      meta.sortIndex = this.snapshot().notebooks.filter((n) => n.id !== id && (n.parent ?? null) === parent).length;
    }
    meta.modifiedAt = toIsoSeconds(this.now());
    meta.revision = newUuid();
    await this.persist({ ...r, revision: meta.revision, modifiedAt: this.now().getTime(), meta: fromUtf8(patchMeta(utf8(JSON.stringify(raw)), meta, NOTEBOOK_META_OWNED_KEYS)) });
    this.onChange();
  }

  // MARK: tags (native renameTag / deleteTag)

  /**
   * Renames (merging into a tag in use) or deletes a tag and the tags nested in it in every note outside Recently
   * Deleted that this browser can edit; a rename also rewrites smart folder searches.
   */
  editTag(edit: TagEdit): Promise<{ changed: number; skipped: number; inTrash: number }> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      if (edit.type === 'rename') {
        const inUse = [...new Set([...this.derived.values()].filter((d) => !d.row.deletedAt && d.row.kind !== 'locked').flatMap((d) => d.row.tags))];
        const problem = tagRenameProblem(edit.from, edit.to, inUse);
        if (problem) throw new Error(problem);
      }
      const name = edit.type === 'rename' ? edit.from : edit.tag;
      const tagged = (d: Derived) => d.row.tags.some((t) => t === name.toLowerCase() || t.startsWith(`${name.toLowerCase()}/`));
      let changed = 0;
      let skipped = 0;
      let inTrash = 0;
      for (const d of [...this.derived.values()]) {
        if (!tagged(d)) continue;
        if (d.row.deletedAt) {
          inTrash += 1;
          continue;
        }
        const opened = this.getNote(d.row.id);
        if (!opened?.container || opened.readOnly) {
          skipped += 1;
          continue;
        }
        const doc = rewriteTags(opened.container.doc, edit);
        if (!doc) continue;
        await this.saveNoteLocked(d.row.id, { ...opened.container, doc });
        changed += 1;
      }
      if (edit.type === 'rename') {
        for (const f of this.snapshot().smartFolders) {
          const query = renameTagInQuery(edit.from, edit.to, f.query);
          if (query !== f.query) await this.updateSmartFolderLocked(f.id, { query });
        }
      }
      return { changed, skipped, inTrash };
    });
  }

  // MARK: smart folders (organise; synced as `smart-folders/<ID>.json`, native SmartFolder)

  private static checkSmartFolder(name: string, query: string): void {
    if (!name.trim()) throw new Error('A smart folder needs a name');
    if (name.length > SMART_FOLDER_MAX_NAME) throw new Error(`Names can be up to ${SMART_FOLDER_MAX_NAME} characters`);
    if (!query.trim()) throw new Error('A smart folder needs a search');
    if (query.length > SMART_FOLDER_MAX_QUERY) throw new Error(`Searches can be up to ${SMART_FOLDER_MAX_QUERY} characters`);
  }

  createSmartFolder(opts: { name: string; query: string; symbol?: string }): Promise<Uuid> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      const name = opts.name.trim();
      const query = opts.query.trim();
      WebLocalStore.checkSmartFolder(name, query);
      const existing = this.snapshot().smartFolders;
      if (existing.length >= SMART_FOLDER_MAX_COUNT) throw new Error(`You can have up to ${SMART_FOLDER_MAX_COUNT} smart folders`);
      const id = newUuid();
      const meta: SmartFolderMeta = { id, name, query, symbol: opts.symbol ?? SMART_FOLDER_DEFAULT_SYMBOL, sortIndex: existing.length, revision: newUuid(), modifiedAt: toIsoSeconds(this.now()) };
      await this.persist({ id, kind: 'smartFolder', revision: meta.revision!, modifiedAt: this.now().getTime(), meta: fromUtf8(patchMeta(undefined, meta, SMART_FOLDER_META_OWNED_KEYS)), writer: this.deviceName });
      this.onChange();
      return id;
    });
  }

  updateSmartFolder(id: Uuid, change: { name?: string; query?: string; symbol?: string }): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      await this.updateSmartFolderLocked(id, change);
    });
  }

  private async updateSmartFolderLocked(id: Uuid, change: { name?: string; query?: string; symbol?: string }): Promise<void> {
    {
      const r = this.records_.get(id);
      if (!r || r.kind !== 'smartFolder') throw new Error('No such smart folder');
      const meta = decodeSmartFolderMeta(utf8(r.meta));
      if (change.name !== undefined) meta.name = change.name.trim();
      if (change.query !== undefined) meta.query = change.query.trim();
      if (change.symbol !== undefined) meta.symbol = change.symbol;
      WebLocalStore.checkSmartFolder(meta.name, meta.query);
      meta.revision = newUuid();
      meta.modifiedAt = toIsoSeconds(this.now());
      await this.persist({ ...r, revision: meta.revision, modifiedAt: this.now().getTime(), meta: fromUtf8(patchMeta(utf8(r.meta), meta, SMART_FOLDER_META_OWNED_KEYS)), writer: this.deviceName });
      this.onChange();
    }
  }

  deleteSmartFolder(id: Uuid): Promise<void> {
    return this.deleteForever(id);
  }

  private notebookAncestors(id: Uuid): Uuid[] {
    const byId = new Map(this.snapshot().notebooks.map((n) => [n.id, n]));
    const out: Uuid[] = [];
    for (let p = byId.get(id)?.parent; p && !out.includes(p); p = byId.get(p)?.parent) out.push(p);
    return out;
  }

  /** Deleting a notebook moves its notes to Recently Deleted (new revisions, notebookID kept). */
  deleteNotebook(id: Uuid): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      for (const d of [...this.derived.values()]) {
        if (d.row.notebookID === id && !d.row.deletedAt) await this.updateNoteMetaLocked(d.row.id, { trashed: true });
      }
      await this.deleteForeverLocked(id);
    });
  }

  // MARK: SyncLocalStore

  async records(): Promise<LocalRecord[]> {
    await this.ensureFresh();
    this.seenRevisions = new Map([...this.records_.values()].map((r) => [r.id, r.revision]));
    return [...this.records_.values()].map((r) => ({ id: r.id, kind: r.kind, revision: r.revision, modifiedAt: new Date(r.modifiedAt) }));
  }

  async deletions(): Promise<Map<Uuid, LocalDeletion>> {
    await this.ensureFresh();
    return new Map([...this.deletions_].map(([id, d]) => [id, { kind: d.kind, deletedAt: new Date(d.deletedAt) }]));
  }

  async export(id: Uuid): Promise<RecordPayload> {
    const r = this.records_.get(id);
    if (!r) throw new Error(`no local record ${id}`);
    const p: RecordPayload = { id, kind: r.kind, revision: r.revision, modifiedAt: new Date(r.modifiedAt), deviceID: this.deviceID, meta: utf8(r.meta) };
    if (r.kind === 'note') {
      if (r.body !== undefined) {
        p.body = utf8(r.body);
        p.bodyFormat = r.bodyFormat ?? BODY_FORMAT_DOC_V1;
      } else if (r.carried) {
        p.carriedBody = r.carried;
      }
    }
    return p;
  }

  /**
   * Takes a pulled version. Refused (deferred to the next pass, where both sides changed and the remote becomes a
   * conflict copy) when the record was edited since the engine read it, as native's adapter does.
   */
  apply(p: RecordPayload, fromDevice?: string): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      const current = this.records_.get(p.id)?.revision;
      if (current !== undefined && this.seenRevisions.has(p.id) && current !== this.seenRevisions.get(p.id)) {
        throw new RecordDeferred(`${p.id}: local edit in progress; retrying next pass`);
      }
      await this.applyLocked(p, fromDevice);
      this.seenRevisions.set(p.id, p.revision);
    });
  }

  private async applyLocked(p: RecordPayload, fromDevice?: string): Promise<void> {
    const r: StoredRecord = { id: p.id, kind: p.kind, revision: p.revision, modifiedAt: p.modifiedAt.getTime(), meta: fromUtf8(p.meta), ...(fromDevice ? { writer: fromDevice } : {}) };
    if (p.body) {
      r.body = fromUtf8(p.body);
      r.bodyFormat = p.bodyFormat ?? BODY_FORMAT_DOC_V1;
    } else if (p.carriedBody) {
      r.carried = p.carriedBody;
    }
    await this.persist(r);
    this.onChange();
  }

  applyDeletion(id: Uuid, kind: RecordKind): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      await this.applyDeletionLocked(id, kind);
    });
  }

  private async applyDeletionLocked(id: Uuid, kind: RecordKind): Promise<void> {
    await this.remove(id);
    if (kind === 'notebook') {
      // A received notebook deletion moves its live notes to no notebook, without new revisions.
      for (const r of [...this.records_.values()]) {
        if (r.kind !== 'note') continue;
        const meta = decodeNoteMeta(utf8(r.meta));
        if (meta.notebookID !== id || meta.deletedAt) continue;
        delete meta.notebookID;
        await this.persist({ ...r, meta: fromUtf8(patchMeta(utf8(r.meta), meta, NOTE_META_OWNED_KEYS)) });
      }
    }
    this.onChange();
  }

  importConflictCopy(p: RecordPayload, fromDevice: string): Promise<void> {
    return this.exclusive(async () => {
      await this.importConflictCopyLocked(p, fromDevice);
    });
  }

  private async importConflictCopyLocked(p: RecordPayload, fromDevice: string): Promise<Uuid> {
    if (!p.body) throw new RecordRefused('a conflict copy needs a readable body');
    const decoded = decodeBody(p.body, p.bodyFormat);
    if (decoded.kind !== 'doc') throw new RecordRefused('a conflict copy needs a noteit-doc body');
    const remote = decodeNoteMeta(p.meta);
    const container = { ...decoded.container, doc: withConflictSuffix(decoded.container.doc, conflictTitleSuffix(fromDevice, p.modifiedAt)) };
    const id = newUuid();
    const { title, preview } = deriveTitleAndPreview(container.doc);
    const meta: NoteMeta = {
      id,
      title,
      preview,
      tags: deriveTags(container.doc),
      isPinned: remote.isPinned,
      createdAt: remote.createdAt,
      updatedAt: remote.updatedAt,
      conflictSource: fromDevice,
      conflictOriginalID: p.id,
    };
    if (remote.notebookID) meta.notebookID = remote.notebookID;
    await this.writeNote(id, meta, { container });
    return id;
  }

  clearDeletion(id: Uuid): Promise<void> {
    return this.exclusive(async () => {
      await this.ensureFresh();
      if (this.deletions_.delete(id)) await this.saveDeletions();
    });
  }

  async revision(id: Uuid, kind: RecordKind): Promise<Uuid | undefined> {
    await this.ensureFresh();
    const r = this.records_.get(id);
    return r && r.kind === kind ? r.revision : undefined;
  }

  async passDidFinish(): Promise<void> {}
}

/** Sync state and pending body bytes, sealed like everything else in the cache. */
export class WebStateStore implements SyncStateStore {
  constructor(
    private readonly kv: KeyValue,
    private readonly cipher: SyncCipher,
  ) {}

  /** Always read from IndexedDB: another tab's pass may have moved the bases on since this one last looked. */
  async load(): Promise<SyncState> {
    const sealed = await this.kv.get<Uint8Array>('kv', 'syncState');
    return sealed ? { ...emptySyncState(), ...(JSON.parse(fromUtf8(await this.cipher.open(sealed, 'local/kv/syncState'))) as SyncState) } : emptySyncState();
  }

  async save(s: SyncState): Promise<void> {
    await this.kv.put('kv', 'syncState', await this.cipher.seal(utf8(JSON.stringify(s)), 'local/kv/syncState'));
  }

  async putPendingBody(id: Uuid, version: Uuid, sealed: Bytes): Promise<void> {
    await this.kv.put('pending', `${id}.${version}`, sealed);
  }
  async getPendingBody(id: Uuid, version: Uuid): Promise<Bytes | undefined> {
    return this.kv.get<Bytes>('pending', `${id}.${version}`);
  }
  async deletePendingBody(id: Uuid, version: Uuid): Promise<void> {
    await this.kv.delete('pending', `${id}.${version}`);
  }
}
