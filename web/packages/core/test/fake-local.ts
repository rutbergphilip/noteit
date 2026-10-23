import {
  type Bytes,
  fromUtf8,
  type LocalDeletion,
  type LocalRecord,
  newUuid,
  type RecordKind,
  type RecordPayload,
  type SyncLocalStore,
  utf8,
  type Uuid,
  type CarriedBody,
} from '../src/index.js';

export interface FakeRecord {
  id: Uuid;
  kind: RecordKind;
  revision: Uuid;
  modifiedAt: Date;
  meta: Record<string, unknown>;
  body?: Bytes;
  bodyFormat?: string;
  carried?: CarriedBody;
}

/** A minimal local store: metas are JSON objects, bodies opaque bytes. */
export class FakeLocal implements SyncLocalStore {
  readonly items = new Map<Uuid, FakeRecord>();
  readonly deleted = new Map<Uuid, LocalDeletion>();

  constructor(
    readonly deviceID: string,
    private readonly bodyFormat?: string,
  ) {}

  upsert(r: FakeRecord): void {
    this.items.set(r.id, r);
    this.deleted.delete(r.id);
  }

  remove(id: Uuid, at: Date): void {
    const r = this.items.get(id);
    if (!r) return;
    this.items.delete(id);
    this.deleted.set(id, { kind: r.kind, deletedAt: at });
  }

  async records(): Promise<LocalRecord[]> {
    return [...this.items.values()].map((r) => ({ id: r.id, kind: r.kind, revision: r.revision, modifiedAt: r.modifiedAt }));
  }
  async deletions(): Promise<Map<Uuid, LocalDeletion>> {
    return new Map(this.deleted);
  }
  async export(id: Uuid): Promise<RecordPayload> {
    const r = this.items.get(id);
    if (!r) throw new Error(`no record ${id}`);
    const p: RecordPayload = { id, kind: r.kind, revision: r.revision, modifiedAt: r.modifiedAt, deviceID: this.deviceID, meta: utf8(JSON.stringify(r.meta)) };
    if (r.carried && !r.body) p.carriedBody = r.carried;
    if (r.body) {
      p.body = r.body;
      const format = r.bodyFormat ?? this.bodyFormat;
      if (format) p.bodyFormat = format;
    }
    return p;
  }
  async apply(p: RecordPayload): Promise<void> {
    const r: FakeRecord = { id: p.id, kind: p.kind, revision: p.revision, modifiedAt: p.modifiedAt, meta: JSON.parse(fromUtf8(p.meta)) as Record<string, unknown> };
    if (p.body) r.body = p.body;
    if (p.bodyFormat) r.bodyFormat = p.bodyFormat;
    if (p.carriedBody) r.carried = p.carriedBody;
    this.items.set(p.id, r);
  }
  async applyDeletion(id: Uuid): Promise<void> {
    this.items.delete(id);
  }
  async importConflictCopy(p: RecordPayload, fromDevice: string): Promise<void> {
    const meta = JSON.parse(fromUtf8(p.meta)) as Record<string, unknown>;
    const id = newUuid();
    const r: FakeRecord = {
      id,
      kind: p.kind,
      revision: newUuid(),
      modifiedAt: p.modifiedAt,
      meta: { ...meta, title: `${String(meta.title)} (conflict — ${fromDevice})`, conflictSource: fromDevice },
    };
    if (p.body) r.body = p.body;
    if (p.bodyFormat) r.bodyFormat = p.bodyFormat;
    this.items.set(id, r);
  }
  async clearDeletion(id: Uuid): Promise<void> {
    this.deleted.delete(id);
  }
  async revision(id: Uuid, kind: RecordKind): Promise<Uuid | undefined> {
    const r = this.items.get(id);
    return r && r.kind === kind ? r.revision : undefined;
  }
  async passDidFinish(): Promise<void> {}
}
