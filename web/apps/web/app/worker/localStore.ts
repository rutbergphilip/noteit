import {
  BODY_FORMAT_DOC_V1,
  BODY_FORMAT_LOCKED_V1,
  type Bytes,
  type CarriedBody,
  decodeNotebookMeta,
  decodeNoteMeta,
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
  type RecordKind,
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
  matchesQuery,
  noteLinks,
  type NoteLinkRef,
  parseQuery,
  parseTasks,
  maskedText,
  pruneAttachments,
  searchFold,
  searchableText,
  withConflictSuffix,
} from '@noteit/doc';
import type { StoreName } from './idb';
import type { NoteKind, NoteRow, NotebookRow, Snapshot } from './types';

export interface KeyValue {
  get<T>(store: StoreName, key: string): Promise<T | undefined>;
  all<T>(store: StoreName): Promise<[string, T][]>;
  put(store: StoreName, key: string, value: unknown): Promise<void>;
  delete(store: StoreName, key: string): Promise<void>;
  clear(store: StoreName): Promise<void>;
}

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
  onChange: () => void = () => undefined;

  constructor(
    private readonly kv: KeyValue,
    private readonly cipher: SyncCipher,
    private readonly deviceID: string,
    private readonly now: () => Date = () => new Date(),
  ) {}

  // MARK: persistence

  private async sealJson(context: string, value: unknown): Promise<Bytes> {
    return this.cipher.seal(utf8(JSON.stringify(value)), context);
  }

  private async openJson<T>(context: string, sealed: Uint8Array): Promise<T> {
    return JSON.parse(fromUtf8(await this.cipher.open(sealed, context))) as T;
  }

  async load(): Promise<void> {
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

  private async persist(r: StoredRecord): Promise<void> {
    this.records_.set(r.id, r);
    if (r.kind === 'note') this.derive(r);
    await this.kv.put('records', r.id, await this.sealJson(`local/records/${r.id}`, r));
  }

  private async remove(id: Uuid): Promise<void> {
    this.records_.delete(id);
    this.derived.delete(id);
    await this.kv.delete('records', id);
  }

  private async saveDeletions(): Promise<void> {
    await this.kv.put('kv', 'deletions', await this.sealJson('local/kv/deletions', Object.fromEntries(this.deletions_)));
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
    const row: NoteRow = { id: r.id, title, preview, tags, isPinned: meta.isPinned, createdAt: meta.createdAt, updatedAt: meta.updatedAt, kind };
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
        notebooks.push({ id: m.id, name: m.name, colorHex: m.colorHex, symbol: m.symbol, sortIndex: m.sortIndex, ...(m.parent ? { parent: m.parent } : {}) });
      } catch {
        // unreadable notebook metas are skipped
      }
    }
    return { notes: [...this.derived.values()].map((d) => d.row), notebooks: notebooks.sort((a, b) => a.sortIndex - b.sortIndex || a.name.localeCompare(b.name)) };
  }

  /** The search language (`tag:`, `is:todo`, `-word`, `OR` …), evaluated as native `QueryEvaluator` does. */
  search(query: string, now: Date = this.now()): string[] {
    const q = parseQuery(query);
    const notebooks = this.snapshot().notebooks;
    const ctx = { now, notebooks };
    return [...this.derived.values()]
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
      })
      .map((d) => d.row.id);
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

  /** Every checklist item in live, editable notes (the Tasks view). */
  tasks(): { noteId: Uuid; noteTitle: string; block: number; text: string; checked: boolean; due?: LocalDateTime; remind?: LocalDateTime }[] {
    const out: { noteId: Uuid; noteTitle: string; block: number; text: string; checked: boolean; due?: LocalDateTime; remind?: LocalDateTime }[] = [];
    for (const d of this.derived.values()) {
      if (d.row.deletedAt || d.row.kind !== 'doc') continue;
      for (const t of d.tasks) out.push({ noteId: d.row.id, noteTitle: d.row.title, block: t.block, text: t.text, checked: t.checked, ...(t.due ? { due: t.due } : {}), ...(t.remind ? { remind: t.remind } : {}) });
    }
    return out;
  }

  /** Checks or unchecks one checklist item, as a body edit. */
  async setTaskChecked(id: Uuid, block: number, checked: boolean): Promise<void> {
    const opened = this.getNote(id);
    if (!opened?.container || opened.readOnly) throw new Error('This note is read-only here');
    const b = opened.container.doc.content[block];
    if (b?.type !== 'listItem' || b.attrs.kind !== 'task') throw new Error('That item has changed');
    b.attrs = { ...b.attrs, checked };
    await this.saveNote(id, opened.container);
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

  async createNote(opts: { notebookID?: Uuid; container?: BodyContainer } = {}): Promise<Uuid> {
    const id = newUuid();
    const container = opts.container ?? emptyContainer();
    const now = toIsoSeconds(this.now());
    const { title, preview } = deriveTitleAndPreview(container.doc);
    const meta: NoteMeta = { id, title, preview, tags: deriveTags(container.doc), isPinned: false, createdAt: now, updatedAt: now };
    if (opts.notebookID) meta.notebookID = opts.notebookID;
    await this.writeNote(id, meta, { container });
    return id;
  }

  /** Saves an edited body; title, preview and tags are derived from it. Conflict markers clear on a body edit. */
  async saveNote(id: Uuid, container: BodyContainer): Promise<void> {
    const r = this.records_.get(id);
    if (!r || r.body === undefined) throw new Error('This note is read-only here');
    pruneAttachments(container);
    if (fromUtf8(encodeBody(container)) === r.body) return;
    const meta = this.noteMeta(id);
    const { title, preview } = deriveTitleAndPreview(container.doc);
    meta.title = title;
    meta.preview = preview;
    meta.tags = deriveTags(container.doc);
    meta.updatedAt = toIsoSeconds(this.now());
    delete meta.conflictSource;
    delete meta.conflictOriginalID;
    await this.writeNote(id, meta, { container });
  }

  async updateNoteMeta(id: Uuid, change: { isPinned?: boolean; notebookID?: Uuid | null; trashed?: boolean }): Promise<void> {
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

  async deleteForever(id: Uuid): Promise<void> {
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
  async purgeExpired(): Promise<void> {
    const cutoff = this.now().getTime() - RECENTLY_DELETED_DAYS * 86_400_000;
    for (const d of [...this.derived.values()]) {
      if (d.row.deletedAt && Date.parse(d.row.deletedAt) < cutoff) await this.deleteForever(d.row.id);
    }
  }

  async createNotebook(opts: { name: string; colorHex: string; symbol: string; parent?: Uuid }): Promise<Uuid> {
    const id = newUuid();
    const siblings = this.snapshot().notebooks.filter((n) => (n.parent ?? null) === (opts.parent ?? null));
    const meta: NotebookMeta = { id, name: opts.name, colorHex: opts.colorHex, symbol: opts.symbol, sortIndex: siblings.length, modifiedAt: toIsoSeconds(this.now()), revision: newUuid() };
    // `parent` belongs to organise; it rides along as an extra key through RawMetaOverlay.
    const raw = opts.parent ? utf8(JSON.stringify({ parent: opts.parent })) : undefined;
    await this.persist({ id, kind: 'notebook', revision: meta.revision!, modifiedAt: this.now().getTime(), meta: fromUtf8(patchMeta(raw, meta, NOTEBOOK_META_OWNED_KEYS)) });
    this.onChange();
    return id;
  }

  async updateNotebook(id: Uuid, change: { name?: string; colorHex?: string; symbol?: string }): Promise<void> {
    const r = this.records_.get(id);
    if (!r || r.kind !== 'notebook') return;
    const meta: NotebookMeta = decodeNotebookMeta(utf8(r.meta));
    delete (meta as { parent?: string }).parent;
    Object.assign(meta, change);
    meta.modifiedAt = toIsoSeconds(this.now());
    meta.revision = newUuid();
    await this.persist({ ...r, revision: meta.revision, modifiedAt: this.now().getTime(), meta: fromUtf8(patchMeta(utf8(r.meta), meta, NOTEBOOK_META_OWNED_KEYS)) });
    this.onChange();
  }

  /** Deleting a notebook moves its notes to Recently Deleted (new revisions, notebookID kept). */
  async deleteNotebook(id: Uuid): Promise<void> {
    for (const d of [...this.derived.values()]) {
      if (d.row.notebookID === id && !d.row.deletedAt) await this.updateNoteMeta(d.row.id, { trashed: true });
    }
    await this.deleteForever(id);
  }

  // MARK: SyncLocalStore

  async records(): Promise<LocalRecord[]> {
    return [...this.records_.values()].map((r) => ({ id: r.id, kind: r.kind, revision: r.revision, modifiedAt: new Date(r.modifiedAt) }));
  }

  async deletions(): Promise<Map<Uuid, LocalDeletion>> {
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

  async apply(p: RecordPayload): Promise<void> {
    const r: StoredRecord = { id: p.id, kind: p.kind, revision: p.revision, modifiedAt: p.modifiedAt.getTime(), meta: fromUtf8(p.meta) };
    if (p.body) {
      r.body = fromUtf8(p.body);
      r.bodyFormat = p.bodyFormat ?? BODY_FORMAT_DOC_V1;
    } else if (p.carriedBody) {
      r.carried = p.carriedBody;
    }
    await this.persist(r);
    this.onChange();
  }

  async applyDeletion(id: Uuid, kind: RecordKind): Promise<void> {
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

  async importConflictCopy(p: RecordPayload, fromDevice: string): Promise<void> {
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
  }

  async clearDeletion(id: Uuid): Promise<void> {
    if (this.deletions_.delete(id)) await this.saveDeletions();
  }

  async revision(id: Uuid, kind: RecordKind): Promise<Uuid | undefined> {
    const r = this.records_.get(id);
    return r && r.kind === kind ? r.revision : undefined;
  }

  async passDidFinish(): Promise<void> {}
}

/** Sync state and pending body bytes, sealed like everything else in the cache. */
export class WebStateStore implements SyncStateStore {
  private cached: SyncState | undefined;
  constructor(
    private readonly kv: KeyValue,
    private readonly cipher: SyncCipher,
  ) {}

  async load(): Promise<SyncState> {
    if (this.cached) return structuredClone(this.cached);
    const sealed = await this.kv.get<Uint8Array>('kv', 'syncState');
    this.cached = sealed ? { ...emptySyncState(), ...(JSON.parse(fromUtf8(await this.cipher.open(sealed, 'local/kv/syncState'))) as SyncState) } : emptySyncState();
    return structuredClone(this.cached);
  }

  async save(s: SyncState): Promise<void> {
    this.cached = structuredClone(s);
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
