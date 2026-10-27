// Direct mode against a real S3-compatible server. Skipped unless NOTEIT_LIVE_S3_ENDPOINT is set; the bucket must
// exist. scripts/direct_s3_interop.sh runs it against moto with the Mac's LiveS3EmulatorTests in between:
//   NOTEIT_INTEROP_STEP=write  the web creates a store in NOTEIT_LIVE_S3_INTEROP_PREFIX and syncs a note;
//   (swift test --filter LiveS3EmulatorTests/testSharesABucketWithTheWebApp reads it and writes one back)
//   NOTEIT_INTEROP_STEP=read   the web reads the Mac's note.
// Without a step it checks the canary and the CORS check on a fresh prefix and deletes what it wrote.
import { connect, fromUtf8, type LocalDeletion, type LocalRecord, MemoryStateStore, newUuid, type RecordPayload, S3Backend, type SyncLocalStore, SyncEngine, utf8 } from '@noteit/core';
import { describe, expect, it } from 'vitest';
import { corsCheck } from '../../app/worker/corsCheck';

const env = process.env;
const live = env.NOTEIT_LIVE_S3_ENDPOINT;
const step = env.NOTEIT_INTEROP_STEP;
const PASS = env.NOTEIT_LIVE_S3_INTEROP_PASSPHRASE || 'interop passphrase';

function backend(prefix: string): S3Backend {
  return new S3Backend({
    endpoint: live!,
    region: env.NOTEIT_LIVE_S3_REGION || 'us-east-1',
    bucket: env.NOTEIT_LIVE_S3_BUCKET || 'noteit-live',
    prefix,
    pathStyle: env.NOTEIT_LIVE_S3_PATH_STYLE !== 'false',
    accessKeyId: env.NOTEIT_LIVE_S3_ACCESS_KEY || 'test',
    secretAccessKey: env.NOTEIT_LIVE_S3_SECRET || 'test',
  });
}

class Local implements SyncLocalStore {
  items = new Map<string, RecordPayload>();
  async records(): Promise<LocalRecord[]> {
    return [...this.items.values()].map((p) => ({ id: p.id, kind: p.kind, revision: p.revision, modifiedAt: p.modifiedAt }));
  }
  async deletions() {
    return new Map<string, LocalDeletion>();
  }
  async export(id: string) {
    return this.items.get(id)!;
  }
  async apply(p: RecordPayload) {
    this.items.set(p.id, p);
  }
  async applyDeletion(id: string) {
    this.items.delete(id);
  }
  async importConflictCopy() {}
  async clearDeletion() {}
  async revision(id: string) {
    return this.items.get(id)?.revision;
  }
  async passDidFinish() {}
  titles(): string[] {
    return [...this.items.values()].map((p) => (JSON.parse(fromUtf8(p.meta)) as { title: string }).title);
  }
}

const docBody = (text: string) => utf8(JSON.stringify({ format: 'noteit-doc', version: 1, doc: { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text }] }] }, attachments: {} }));

describe.skipIf(!live)('direct mode against a live S3 endpoint', () => {
  it.skipIf(!!step)('passes the canary and the CORS check', async () => {
    const b = backend(`noteit-direct-${Date.now()}`);
    expect(await corsCheck(b)).toEqual({ ok: true, writes: true, deletes: true });
    expect(await b.list('noteit/')).toEqual([]);
  });

  it.skipIf(step !== 'write')('writes a store and a note for the Mac', async () => {
    const b = backend(env.NOTEIT_LIVE_S3_INTEROP_PREFIX!);
    const { session, created } = await connect(b, { passphrase: PASS, createIfMissing: true });
    expect(created).toBe(true);
    const local = new Local();
    const id = newUuid();
    local.items.set(id, { id, kind: 'note', revision: newUuid(), modifiedAt: new Date(), deviceID: 'interop-web', meta: utf8(JSON.stringify({ title: 'From the web' })), body: docBody('From the web'), bodyFormat: 'noteit-doc/1' });
    const report = await new SyncEngine({ backend: b, session, local, state: new MemoryStateStore(), deviceID: 'interop-web', deviceName: 'Web', appVersion: 'web' }).sync();
    expect(report.errors).toEqual([]);
    expect(report.pushed).toBe(1);
  });

  it.skipIf(step !== 'read')("reads the Mac's note", async () => {
    const b = backend(env.NOTEIT_LIVE_S3_INTEROP_PREFIX!);
    const { session } = await connect(b, { passphrase: PASS, createIfMissing: false });
    const local = new Local();
    const report = await new SyncEngine({ backend: b, session, local, state: new MemoryStateStore(), deviceID: 'interop-web-2', deviceName: 'Web', appVersion: 'web' }).sync();
    expect(report.errors).toEqual([]);
    expect(local.titles().sort()).toEqual(['From the Mac', 'From the web']);
    for (const o of await b.list('noteit/')) await b.delete(o.key);
  });
});
