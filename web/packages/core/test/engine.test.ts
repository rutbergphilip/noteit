import { describe, expect, it } from 'vitest';
import {
  b64decode,
  BODY_FORMAT_DOC_V1,
  connect,
  b64encode,
  decide,
  decodeManifest,
  encodeJson,
  fromUtf8,
  IdentityCipher,
  InMemoryBackend,
  keys,
  MemoryStateStore,
  openSession,
  ROOT,
  type StoreSession,
  StorageError,
  SyncEngine,
  SyncError,
  utf8,
  type SyncAction,
} from '../src/index.js';
import { FakeLocal } from './fake-local.js';
import { HeldRequest, isTestCrash, ScriptedBackend } from './scripted-backend.js';
import { golden } from './golden.js';

interface PlannerCase {
  local?: { revision: string; modifiedAt: string };
  localDeletedAt?: string;
  remote: { metaETag?: string; tombstone?: { deletedAt: string; deletedMetaETag?: string } };
  base?: { revision: string; remoteMetaETag: string; replacedMetaETag?: string };
  expect: SyncAction;
}

describe('planner vectors', () => {
  const cases = golden<PlannerCase>('planner.json').cases;
  it(`matches all ${cases.length} cases`, () => {
    expect(cases.length).toBeGreaterThan(600);
    for (const c of cases) {
      const remote = {
        ...(c.remote.metaETag ? { metaETag: c.remote.metaETag } : {}),
        ...(c.remote.tombstone
          ? { tombstone: { deletedAt: new Date(c.remote.tombstone.deletedAt), ...(c.remote.tombstone.deletedMetaETag ? { deletedMetaETag: c.remote.tombstone.deletedMetaETag } : {}) } }
          : {}),
      };
      const got = decide(
        c.local ? { revision: c.local.revision, modifiedAt: new Date(c.local.modifiedAt) } : undefined,
        c.localDeletedAt ? new Date(c.localDeletedAt) : undefined,
        remote,
        c.base,
      );
      expect(got, JSON.stringify(c)).toBe(c.expect);
    }
  });
});

interface Step { device: string; op: string; args: Record<string, unknown> }
interface Scenario { name: string; store?: 'v2'; backend?: { atomic?: boolean; atomicDelete?: boolean }; steps: Step[]; expectRemoteKeys: string[]; expectLocal: Record<string, Record<string, unknown>[]> }

async function plainSession(backend: InMemoryBackend, now: Date): Promise<StoreSession> {
  const etag = await backend.put(keys.manifest, encodeJson({ createdAt: now.getTime() / 1000 - 978307200, formatVersion: 1 }), { ifNoneMatch: true });
  return openSession(decodeManifest((await backend.get(keys.manifest)).data), etag, { allowPlaintext: true });
}

describe('engine scenario vectors (v1 bodies)', () => {
  for (const sc of golden<Scenario>('engine-scenarios.json').cases.filter((c) => c.store === undefined)) {
    it(sc.name, async () => {
      let clock = new Date('2026-01-01T00:00:00.000Z');
      const backend = new InMemoryBackend({ now: () => clock });
      const session = await plainSession(backend, clock);
      expect(session.cipher).toBeInstanceOf(IdentityCipher);
      const devices = new Map<string, { local: FakeLocal; engine: SyncEngine }>();
      const device = (name: string) => {
        let d = devices.get(name);
        if (!d) {
          const local = new FakeLocal(`device-${name}`);
          const engine = new SyncEngine({ backend, session, local, state: new MemoryStateStore(), deviceID: `device-${name}`, deviceName: name, now: () => clock });
          d = { local, engine };
          devices.set(name, d);
        }
        return d;
      };
      const known = new Set<string>();
      for (const step of sc.steps) {
        const d = device(step.device);
        const a = step.args;
        if (typeof a.at === 'string') clock = new Date(a.at);
        if (typeof a.id === 'string') known.add(a.id);
        if (typeof a.revision === 'string') known.add(a.revision);
        switch (step.op) {
          case 'create':
          case 'edit': {
            const existing = d.local.items.get(a.id as string);
            const kind = (a.kind as 'note' | 'notebook' | undefined) ?? existing?.kind ?? 'note';
            d.local.upsert({
              id: a.id as string,
              kind,
              revision: a.revision as string,
              modifiedAt: clock,
              meta: { title: a.title },
              ...(kind === 'note' ? { body: utf8(`Body of ${String(a.title)}`) } : {}),
            });
            break;
          }
          case 'delete':
            d.local.remove(a.id as string, clock);
            break;
          case 'sync':
            await d.engine.sync();
            break;
          case 'failNextPuts':
            for (let i = 0; i < (a.count as number); i++) backend.failNext('put', new StorageError('network', 'injected'));
            break;
          case 'advanceClock':
            clock = new Date(clock.getTime() + (a.seconds as number) * 1000);
            break;
          default:
            throw new Error(`unknown op ${step.op}`);
        }
      }
      const uuidRe = /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/g;
      const placeholder = (s: string) => s.replace(uuidRe, (u) => (known.has(u) ? u : 'new'));
      expect([...backend.objects.keys()].map(placeholder).sort()).toEqual([...sc.expectRemoteKeys].sort());
      for (const [name, expected] of Object.entries(sc.expectLocal)) {
        const got = [...device(name).local.items.values()].map((r) => {
          const out: Record<string, unknown> = { id: placeholder(r.id), kind: r.kind, revision: placeholder(r.revision), title: r.meta.title };
          if (r.body) out.body = fromUtf8(r.body);
          if (r.meta.conflictSource) out.conflictSource = r.meta.conflictSource;
          return out;
        });
        const sort = (xs: Record<string, unknown>[]) => [...xs].sort((x, y) => String(x.id).localeCompare(String(y.id)));
        expect(sort(got)).toEqual(sort(expected));
      }
    });
  }
});

interface SnapshotCase { passphrase: string; objects: { key: string; etag: string; data: string }[]; expectRecords: Record<string, unknown>[] }

/**
 * The v2 traces (Swift GoldenVectorTests.v2Scenarios), replayed the way Swift's runV2 does: every step advances the
 * clock 60 s, a device whose name starts with "W" is wiped after its crash (never syncs again, not compared), and
 * crashes, lost responses and held requests come from ScriptedBackend.
 */
describe('engine scenario vectors (v2, noteit-doc store)', () => {
  const v2 = golden<Scenario>('engine-scenarios.json').cases.filter((c) => c.store === 'v2');
  it('has the v2 traces', () => {
    expect(v2.map((c) => c.name)).toEqual(
      expect.arrayContaining(['v2-publish', 'v2-crash-before-commit', 'v2-lost-response', 'v2-orphan-sweep', 'v2-stranded', 'v2-held-create', 'v2-repair']),
    );
  });
  for (const sc of v2) {
    it(sc.name, async () => {
      let clock = new Date('2026-01-01T00:00:00.000Z');
      const memory = new InMemoryBackend({ now: () => clock, atomic: sc.backend?.atomic ?? true, atomicDelete: sc.backend?.atomicDelete ?? true });
      const backend = new ScriptedBackend(memory);
      await connect(memory, { passphrase: 'scenario', createIfMissing: true, now: () => clock });
      const devices = new Map<string, { local: FakeLocal; state: MemoryStateStore; engine: SyncEngine }>();
      const held = new Map<string, HeldRequest>();
      const make = async (name: string, local: FakeLocal, state: MemoryStateStore) => {
        const { session } = await connect(memory, { passphrase: 'scenario', createIfMissing: false });
        return new SyncEngine({ backend, session, local, state, deviceID: `device-${name}`, deviceName: name, now: () => clock });
      };
      const device = async (name: string) => {
        let d = devices.get(name);
        if (!d) {
          const local = new FakeLocal(`device-${name}`, BODY_FORMAT_DOC_V1);
          const state = new MemoryStateStore();
          d = { local, state, engine: await make(name, local, state) };
          devices.set(name, d);
        }
        return d;
      };
      const sync = async (d: { engine: SyncEngine }) => {
        try {
          await d.engine.sync();
        } catch (e) {
          if (!isTestCrash(e)) throw e;
        }
      };
      const pattern = (a: Record<string, unknown>) => (a.target === 'body' ? `bodies/${String(a.id)}` : keys.noteMeta(a.id as string));
      const tick = () => (clock = new Date(clock.getTime() + 60_000));
      const known = new Set<string>();
      for (const step of sc.steps) {
        tick();
        const d = await device(step.device);
        const a = step.args;
        if (typeof a.at === 'string') clock = new Date(a.at);
        if (typeof a.id === 'string') known.add(a.id);
        if (typeof a.revision === 'string') known.add(a.revision);
        switch (step.op) {
          case 'create':
          case 'edit': {
            const existing = d.local.items.get(a.id as string);
            const kind = (a.kind as 'note' | 'notebook' | undefined) ?? existing?.kind ?? 'note';
            d.local.upsert({
              id: a.id as string,
              kind,
              revision: a.revision as string,
              modifiedAt: clock,
              meta: { title: a.title },
              ...(kind === 'note' ? { body: utf8(`Body of ${String(a.title)}`) } : {}),
            });
            break;
          }
          case 'delete':
            d.local.remove(a.id as string, clock);
            break;
          case 'sync':
            await sync(d);
            break;
          case 'syncRepeat':
            for (let i = 0; i < (a.count as number); i++) {
              tick();
              await sync(d);
            }
            break;
          case 'advanceClock':
            clock = new Date(clock.getTime() + (a.seconds as number) * 1000);
            break;
          case 'crashDuring':
            backend.on('put', pattern(a), { type: 'crashDuring' });
            break;
          case 'landThenFail':
            backend.on('put', pattern(a), { type: 'landThenFail' });
            break;
          case 'hold': {
            const request = new HeldRequest();
            held.set(step.device, request);
            backend.on('put', pattern(a), { type: 'hold', held: request });
            break;
          }
          case 'release':
            await held.get(step.device)?.release();
            break;
          case 'restart':
            d.engine = await make(step.device, d.local, d.state);
            break;
          case 'deleteBodies':
            for (const o of await memory.list(`${ROOT}bodies/`)) if (o.key.includes(String(a.id))) await memory.delete(o.key);
            break;
          case 'cleanup':
            // Refused on a store without atomic conditional writes (v2-cleanup-disabled).
            await d.engine.cleanUpUnusedStorage().catch((e: unknown) => {
              if (!(e instanceof SyncError && e.kind === 'cleanupUnavailable')) throw e;
            });
            break;
          default:
            throw new Error(`unknown op ${step.op}`);
        }
      }
      const uuidRe = /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/g;
      const version = /\.[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.([^.]+)\.body$/;
      const placeholder = (s: string) =>
        s.replace(version, (_, tag: string) => `.V.${tag === 'new' ? 'new' : 'TAG'}.body`).replace(uuidRe, (u) => (known.has(u) ? u : 'new'));
      expect([...memory.objects.keys()].map(placeholder).sort()).toEqual([...sc.expectRemoteKeys].sort());
      for (const [name, expected] of Object.entries(sc.expectLocal)) {
        const got = [...(await device(name)).local.items.values()].map((r) => {
          const out: Record<string, unknown> = { id: placeholder(r.id), kind: r.kind, revision: placeholder(r.revision), title: r.meta.title };
          if (r.body) out.body = fromUtf8(r.body);
          if (r.meta.conflictSource) out.conflictSource = r.meta.conflictSource;
          return out;
        });
        const sort = (xs: Record<string, unknown>[]) => [...xs].sort((x, y) => String(x.id).localeCompare(String(y.id)));
        expect(sort(got)).toEqual(sort(expected));
      }
    });
  }
});

describe('store-snapshot vector', () => {
  for (const c of golden<SnapshotCase>('store-snapshot.json').cases) {
    it('pulls every record of a native store', async () => {
      const backend = new InMemoryBackend();
      for (const o of c.objects) await backend.put(o.key, b64decode(o.data));
      const { data, etag } = await backend.get(keys.manifest);
      const session = await openSession(decodeManifest(data), etag, { passphrase: c.passphrase });
      const local = new FakeLocal('web-device');
      const engine = new SyncEngine({ backend, session, local, state: new MemoryStateStore(), deviceID: 'web-device', deviceName: 'Web' });
      const report = await engine.sync();
      expect(report.errors).toEqual([]);
      const got = [...local.items.values()]
        .map((r) => {
          const out: Record<string, unknown> = {
            deviceID: 'snapshot-device',
            id: r.id,
            kind: r.kind,
            meta: b64encode(utf8(JSON.stringify(r.meta))),
            modifiedAt: r.modifiedAt.toISOString(),
            revision: r.revision,
          };
          if (r.body) out.body = b64encode(r.body);
          return out;
        })
        .sort((a, b) => String(a.id).localeCompare(String(b.id)));
      const expected = [...c.expectRecords].sort((a, b) => String(a.id).localeCompare(String(b.id)));
      expect(got.map((r) => ({ ...r, meta: undefined }))).toEqual(expected.map((r) => ({ ...r, meta: undefined })));
      for (const [i, r] of expected.entries()) {
        expect(JSON.parse(fromUtf8(b64decode(got[i]!.meta as string)))).toEqual(JSON.parse(fromUtf8(b64decode(r.meta as string))));
      }
      // The tombstone of a record this device never had is left alone.
      expect([...backend.objects.keys()].some((k) => k.startsWith('noteit/v1/tombstones/'))).toBe(true);
    }, 20_000);
  }
});

describe('reminder claims (Swift SyncEngine+Claims)', () => {
  it('lets one device claim a reminder, and sweeps only its own old claims', async () => {
    const { InMemoryBackend, connect, MemoryStateStore, SyncEngine } = await import('../src/index.js');
    const { FakeLocal } = await import('./fake-local.js');
    const backend = new InMemoryBackend();
    const a = await connect(backend, { passphrase: 'claims claims', createIfMissing: true });
    const mk = (id: string, now: () => Date) => new SyncEngine({ backend, session: a.session, local: new FakeLocal(id), state: new MemoryStateStore(), deviceID: id, deviceName: id, now });
    const t = new Date('2026-10-24T09:00:00Z');
    const ea = mk('A', () => t);
    const eb = mk('B', () => t);
    const id = '61110F64-4893-43F8-96F3-3FDAA661A24D';
    expect(await ea.claimReminder(id, t)).toBe('claimed');
    expect(await eb.claimReminder(id, t)).toBe('alreadyClaimed');
    expect(await eb.sweepReminderClaims(0, new Date(t.getTime() + 1000))).toBe(0);
    expect(await ea.sweepReminderClaims(7 * 86400, new Date(t.getTime() + 1000))).toBe(0);
    expect(await ea.sweepReminderClaims(0, new Date(t.getTime() + 1000))).toBe(1);
    expect(await eb.claimReminder(id, t)).toBe('claimed');
  });
});
